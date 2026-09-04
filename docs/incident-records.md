# 対応記録 (Incident Records)

構築・運用中に発生した問題と、その原因・解決策の記録です。同種の問題を繰り返さないための
振り返り資料として残しています。時刻はすべてUTCです。

## 目次

- [INC-001: Azure Files (SMB) 上でMinecraftサーバーが起動しない](#inc-001-azure-files-smb-上でminecraftサーバーが起動しない)
- [INC-002: リビジョン競合によるデッドロック](#inc-002-リビジョン競合によるデッドロック)
- [横断的な学び](#横断的な学び)

---

## INC-001: Azure Files (SMB) 上でMinecraftサーバーが起動しない

**発生日**: 2026-09-04 / **影響**: dev環境。サーバーが一度も起動できなかった

### 概要 (INC-001)

デプロイは成功し、`scripts/start-server.ps1` も「Minecraftサーバーに接続できます」と表示していたが、
実際にはコンテナーが `CrashLoopBackOff` を繰り返しており、サーバーは**一度も起動していなかった**。

```text
"ready": false,
"restartCount": 13,
"runningState": "Waiting",
"runningStateDetails": "Container is waiting with reason: CrashLoopBackOff"
```

### 症状 (INC-001)

コンテナーログに以下のスタックトレースが出力されていた。

```text
[ServerMain/ERROR]: Failed to start the minecraft server
java.io.IOException: Permission denied
    at java.base/sun.nio.ch.UnixFileDispatcherImpl.write0(Native Method)
    ...
    at net.minecraft.util.DirectoryLock.create(DirectoryLock.java:35)
    at net.minecraft.world.level.storage.LevelStorageSource$LevelStorageAccess.createLock(LevelStorageSource.java:412)
    at net.minecraft.server.Main.main(Main.java:142)
```

### 原因 (INC-001)

Minecraftはワールドディレクトリの `session.lock` を `O_SYNC` 付きで開いて書き込み、
その後バイトレンジロックを取得する。**Azure FilesをSMB(cifs)でマウントすると、この書き込みが
`EACCES` (Permission denied) で失敗する**。

`/data` のパーミッションは `drwxrwxrwx` であり、パーミッションビット上は書き込み可能だった。
つまり単純な権限不足ではなく、cifs のロック/同期書き込みセマンティクスに起因する問題だった。

### 検証したが解決しなかった対策

コスト影響が大きいNFS移行の前に、SMBのまま `mountOptions` で回避できないかを実機検証した。

```text
mountOptions: uid=1000,gid=1000,file_mode=0777,dir_mode=0777,mfsymlinks,nobrl
```

- マウントオプション自体は**適用された** (ログ上 `/data` の所有者が `0 0` → `1000 1000` に変化)
- しかし `Permission denied` は解消せず、同じ箇所でクラッシュした
- `nobrl` (バイトレンジロック抑止) を付けても効果がなかった

補足として、Container Apps は許可されていないマウントオプションを拒否する。

```text
(ContainerAppVolumeMountOptionsNotSupported) MountOptions 'actimeo' for volume 'minecraft-data'
are not supported by azure file share.
```

`cache` / `actimeo` は指定できず、`uid` / `gid` / `file_mode` / `dir_mode` / `mfsymlinks` / `nobrl` は指定できた。

### 解決策: NFS 4.1 への移行

POSIXセマンティクスを満たすNFSへ切り替えることで解決した。

| ファイル | 変更内容 |
| --- | --- |
| `infra/modules/storage.bicep` | `kind: 'FileStorage'` / `sku: 'Premium_LRS'`、共有を `enabledProtocols: 'NFS'` + `rootSquash: 'NoRootSquash'`、`supportsHttpsTrafficOnly: false`、`allowSharedKeyAccess: false`、`protocolSettings.nfs.encryptionInTransit.required: false` |
| `infra/modules/container-app-environment.bicep` | `azureFile` → `nfsAzureFile` (`server` と `/<account>/<share>` 形式の `shareName`)。アカウントキー参照 (`listKeys()`) が不要になり削除 |
| `infra/modules/minecraft-container-app.bicep` | volume の `storageType` を `NfsAzureFile` へ |

移行後、ワールド生成を含めて正常に起動した。

```text
[Server thread/INFO]: Preparing level "world"
[Server thread/INFO]: Done (5.668s)! For help, type "help"
```

### 副作用・制約

- **Premium FileStorage が必須**。NFS共有の最小容量は **100GiB** で、サーバー停止中も課金される
- **Storage Account の `kind` は `StorageV2` から `FileStorage` へ変更できない**。既存環境は作り直しが必要
- **`Microsoft.App/managedEnvironments/storages` の `storageType` は後から変更できない**
  (`ManagedEnvironmentStorageTypeMisMatch`)。かつ Container App から参照されている間は削除もできない
  (`ManagedEnvironmentStorageDeleteInUse`)
- NFS共有は **REST API 経由でアクセスできない**。AzCopy / Azure Storage Explorer / `az storage file` は使えず、
  ファイルの出し入れは `az containerapp exec` でコンテナー経由になる
- NFSマウントには **VNet統合が必須**。Container Apps は NFS の転送時暗号化に非対応のため
  `supportsHttpsTrafficOnly` を `false` にする必要がある
  (有効なままだと `mount.nfs: access denied by server while mounting`)

### 副次的に判明した問題: TCP接続確認の偽陽性

`scripts/start-server.ps1` は TCP 25565 へ接続できたことをもって「起動成功」と判定していたが、
**Container Apps の TCP Ingress (Envoy) はバックエンドが異常でも TCPハンドシェイクを成立させる**。
そのため、サーバーが一度も起動していないのに「接続できます」と報告していた。

対策として、Minecraft の **Server List Ping** (handshake → status request) を実装し、
サーバー本体からのステータス応答(JSON)を確認するようにした
(`scripts/lib/minecraft-ping.ps1`)。

---

## INC-002: リビジョン競合によるデッドロック

**発生日**: 2026-09-04 / **影響**: dev環境。プレイは可能だが状態表示が実態と乖離

### 概要 (INC-002)

NFS化により起動するようになった後、**Minecraftにログインして遊べているにもかかわらず**、
`scripts/status-server.ps1` が「レプリカ数=0、停止中」と表示する事象が発生した。

### 症状 (INC-002)

```text
latestRevisionName      : mcaca-dev-minecraft--0000001   ← Failed (CrashLoopBackOff)
latestReadyRevisionName : mcaca-dev-minecraft--4r5idzj   ← Running / Ready / 再起動0
activeRevisionsMode     : Single
```

`activeRevisionsMode: Single` にもかかわらず、**2つのリビジョンが同時にActive**だった。

| リビジョン | 作成時刻 | 状態 |
| --- | --- | --- |
| `4r5idzj` | 19:27:34 | `RunningAtMaxScale` / Ready。実際に稼働しワールドをロック中 |
| `0000001` | 19:28:41 | `Failed`。起動できずクラッシュループ |

失敗している側のログ:

```text
net.minecraft.util.DirectoryLock$LockException: /data/./world/session.lock:
  already locked (possibly by other Minecraft instance?)
```

### 原因 (INC-002)

1. `deploy.ps1` がリビジョン `4r5idzj` を作成。TCPスケールルールによりレプリカが起動し、
   ワールドの `session.lock` を**排他ロック**した
2. その約1分後、`start-server.ps1` が `az containerapp update --min-replicas 1` を実行。
   **これはテンプレート変更にあたるため、新しいリビジョン `0000001` が生成された**
3. Container Apps は `activeRevisionsMode: Single` であっても、
   **新リビジョンがReadyになってから旧リビジョンを落とす**ローリング方式で切り替える。
   そのため旧 `4r5idzj` は稼働を続けた
4. 新 `0000001` は起動時にワールドを開こうとしたが、ロックは旧が保持中のため
   `already locked` で失敗 → CrashLoopBackOff
5. 新は永久にReadyにならない → 旧も永久に落ちない → **デッドロック**
6. `az containerapp replica list` は `--revision` を省略すると**最新リビジョン**を参照するため、
   Failed な `0000001` を見て「レプリカ0」と報告していた

つまり **Minecraft の単一インスタンス制約と、Container Apps のローリング更新は構造的に相性が悪い**。
`maxReplicas: 1` は「1リビジョン内で1レプリカ」を保証するだけで、リビジョン間の重複は防げない。

### 併発していた設定不備

調査過程で以下の2点も判明した。

- **`STOP_SERVER_ANNOUNCE_DELAY: '60'`**: 停止前に60秒アナウンスする設定だが、
  `terminationGracePeriodSeconds` が未設定 (既定30秒) だったため、
  **60秒待ち切る前にSIGKILLされる**という矛盾があった。新旧リビジョンの重なり時間も延ばしていた
- **プローブが `Liveness` のみ定義**: Container Apps は一部だけ定義すると残りに既定値を適用する。
  既定の Startup プローブは **period 1秒 / failureThreshold 240** のため、
  システムログに `Probe of StartUp failed with status code: 1` が84件記録されていた

### 解決策: minReplicas を変更しない運用へ

「起動・停止でテンプレートを変更しない」方針に切り替え、リビジョンの生成自体をなくした。

| 対象 | 変更内容 |
| --- | --- |
| `.bicepparam` | `minReplicas` を **0固定**で運用 |
| `scripts/start-server.ps1` | `--min-replicas` を廃止。**TCP 25565 への接続を張って保持**しスケールルールを発火させ、Server List Ping が通るまで待つ |
| `scripts/stop-server.ps1` | `--min-replicas` を廃止。`rcon-cli save-all flush` 後、`cooldownPeriod` 経過による自動スケールインを待つ |
| `minecraft-container-app.bicep` | `STOP_SERVER_ANNOUNCE_DELAY` を削除、`terminationGracePeriodSeconds: 90` を追加 |
| `minecraft-container-app.bicep` | **Startup / Readiness / Liveness を3つとも明示定義** (TCP 25565)。Startup は 10秒 × 60回 = 約10分の起動猶予 |
| `minecraft-container-app.bicep` | `scale.cooldownPeriod` をパラメーター化 (dev: 120秒 / prod: 300秒) |
| `scripts/lib/containerapp.ps1` (新規) | `latestReadyRevisionName` を「稼働中リビジョン」として解決し、`replica list` に**必ず `--revision` を指定**する。`latest != latestReady` を検出したら警告 |
| `scripts/deploy.ps1` | デプロイ前にサーバーが稼働中なら**中止**する (`-SkipRunningCheck` で回避可) |
| `deploy-dev.yml` / `deploy-prod.yml` | デプロイ前に `stop-server.ps1` を実行 |
| `update-minecraft.yml` | バックアップ → 停止 → デプロイ → 起動検証の順に変更。害となる `revision restart` を削除 |

### 検証結果

再構築後、意図どおりリビジョンは1つだけになった。

```text
Name                          Active  Replicas  State
mcaca-dev-minecraft--mzl0a47  True    1         RunningAtMaxScale

latest      : mcaca-dev-minecraft--mzl0a47
latestReady : mcaca-dev-minecraft--mzl0a47   ← 一致
restarts    : 0
```

Startup プローブの失敗は **3回のみ** (10秒間隔でMinecraftの起動を待った分) に減り、
`failureThreshold: 60` に対して十分な余裕がある状態になった。

---

## 横断的な学び

### 1. 「接続できた」は「正常」を意味しない

Container Apps の TCP Ingress はバックエンドが異常でもハンドシェイクを成立させる。
ヘルスチェックは**アプリケーションプロトコルのレベルで**行う必要がある。

### 2. 表示が実態と食い違うときは「何を見ているか」を疑う

「レプリカ0なのに遊べる」は判定バグではなく、`az containerapp replica list` が
`--revision` 省略時に最新リビジョンを見ていたことが原因だった。
複数リビジョンが存在しうる前提で、参照対象を明示することが重要。

### 3. ステートフルなシングルトンとローリング更新は相性が悪い

排他ロックを持つアプリケーションでは、「新を立ててから旧を落とす」方式が成立しない。
`maxReplicas: 1` はリビジョン間の重複を防がない。
**テンプレートを変更する操作＝新リビジョン生成**であることを常に意識する。

### 4. プローブは「一部だけ定義」しない

Container Apps は未定義のプローブに既定値を適用する。既定の Startup プローブは
1秒間隔と非常に積極的で、起動の遅いアプリケーションには適さない。
1つでもカスタマイズするなら、Startup / Readiness / Liveness をすべて明示する。

### 5. 停止まわりの設定は整合させる

アプリ側の「停止前の待ち時間」(`STOP_SERVER_ANNOUNCE_DELAY`) と、
プラットフォーム側の「SIGKILLまでの猶予」(`terminationGracePeriodSeconds`) は
必ずセットで確認する。前者が後者を超えていると、保存処理が中断される。

### 6. 代替案は安い順に実機で潰す

NFS移行 (Premium FileStorage / 最小100GiB) はコスト影響が大きかったため、
先に SMB + `mountOptions` を実機で検証した。結果的にNFS移行が必要と確定したが、
「試したが駄目だった」という事実が残ることで、後から蒸し返さずに済む。

### 7. 変更不可のプロパティを把握しておく

今回つまずいた「後から変更できないもの」:

- Storage Account の `kind` (`StorageV2` → `FileStorage`)
- `Microsoft.App/managedEnvironments/storages` の `storageType` (`AzureFile` → `NfsAzureFile`)
- ファイル共有の `enabledProtocols` (作成時のみ指定可能)

いずれもリソースの作り直しが必要になるため、初期設計時に決め切ることが望ましい。
