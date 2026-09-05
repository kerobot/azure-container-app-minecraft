# 対応記録 (Incident Records)

構築・運用中に発生した問題と、その原因・解決策の記録です。同種の問題を繰り返さないための
振り返り資料として残しています。時刻はすべてUTCです。

## 目次

- [INC-001: Azure Files (SMB) 上でMinecraftサーバーが起動しない](#inc-001-azure-files-smb-上でminecraftサーバーが起動しない)
- [INC-002: リビジョン競合によるデッドロック](#inc-002-リビジョン競合によるデッドロック)
- [INC-003: `revision restart` による同一リビジョン内デッドロック](#inc-003-revision-restart-による同一リビジョン内デッドロック)
- [INC-004: TCPスケールルールが固着してスケールインしない](#inc-004-tcpスケールルールが固着してスケールインしない)
- [INC-005: `az containerapp exec` の `&&` 誤作動とレート制限](#inc-005-az-containerapp-exec-の--誤作動とレート制限)
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

## INC-003: `revision restart` による同一リビジョン内デッドロック

**発生日**: 2026-09-05 / **影響**: dev環境。プレイヤーは0人だが復旧作業中にサーバーが
応答不能になった

### 概要 (INC-003)

「サーバーが半日以上稼働したままスケールインしない」事象を調査する過程で、稼働中の
レプリカに対して `az containerapp revision restart` を実行したところ、INC-002と同種の
セッションロック競合が**同一リビジョン内**で発生した。

### 症状 (INC-003)

```text
mcaca-dev-minecraft--mzl0a47-77ddf7487c-cfkh5  Running          restartCount:0  ← 旧pod (ロック保持)
mcaca-dev-minecraft--mzl0a47-78ffcdfbf4-2wrtj  CrashLoopBackOff restartCount:4  ← 新pod
```

クラッシュ中のpodのログ:

```text
net.minecraft.util.DirectoryLock$LockException: /data/./world/session.lock: already locked (possibly by other Minecraft instance?)
```

`latestRevisionName` と `latestReadyRevisionName` は一致しており(新リビジョンは生成されて
いない)、INC-002検出用の `Write-RevisionMismatchWarning` では気づけない状態だった。
`stop-server.ps1` の待機ループでは、このクラッシュ再試行のタイミングによって
稼働レプリカ数が1↔2で揺れて表示された。

### 原因 (INC-003)

`revision restart` は「新pod起動→Readyになったら旧podを停止」というローリング方式で動く。
Minecraftはワールドを排他ロックするため、新podは旧podが生きている限り絶対にReadyになれず、
旧podも(新podがReadyにならないため)永久に停止しない。**`revision restart` はテンプレートを
変更しないため新リビジョンは生成されないが、同一リビジョン内でも新旧2つのpodが一時的に
共存し、同じデッドロックが発生しうる**。

`rcon-cli stop` で旧podのMinecraftプロセスを止めても、プラットフォームが同じレプリカを
自動的に再起動してロックを再取得してしまい、解消しなかった。

### 解決策 (INC-003)

`az containerapp revision deactivate` → `activate` で、リビジョンごと完全に停止してから
再起動することで、新旧podの共存状態を解消できた。

```powershell
# 1. リビジョンを非アクティブ化し、すべてのレプリカを完全に停止させる
az containerapp revision deactivate --name mcaca-dev-minecraft --resource-group rg-minecraft-dev --revision <revision-name>

# 2. 全レプリカがNotRunning/Terminatedになったことを確認する
az containerapp replica list --name mcaca-dev-minecraft --resource-group rg-minecraft-dev --revision <revision-name>

# 3. リビジョンを再アクティブ化し、クリーンな単一レプリカで起動し直す
az containerapp revision activate --name mcaca-dev-minecraft --resource-group rg-minecraft-dev --revision <revision-name>
```

再アクティブ化後は新旧podの競合なく単一の健全なレプリカのみが起動した。

### 対応した恒久対策 (INC-003)

| 対象 | 変更内容 |
| --- | --- |
| `docs/backup-restore.md` | 復元後の反映手順を `revision restart` から、RCON経由でMinecraftプロセスのみを再起動する方式へ変更 (同一レプリカ内でコンテナーが自動再起動するため新旧podの競合が起きない) |
| `docs/troubleshooting.md` | 「`revision restart` 実行後にレプリカがデッドロックする」を追加し、検知方法と `deactivate`→`activate` による復旧手順を明記 |

`revision restart` は、対象レプリカが完全に停止している(レプリカ0)状態でのみ実行することを徹底する。

---

## INC-004: TCPスケールルールが固着してスケールインしない

**発生日**: 2026-09-05 / **影響**: dev環境。プレイヤー0人の状態が半日以上続いても
レプリカが0にならなかった

### 概要 (INC-004)

INC-003の復旧(`deactivate`→`activate`)後、プレイヤーが0人 (`status-server.ps1` の
Server List Pingで確認済み) であるにもかかわらず、`stop-server.ps1` を
`scaleCooldownSeconds` (120秒) を大幅に超える時間 (180秒以上) 待ってもレプリカが
0にならなかった。

### 症状 (INC-004)

```powershell
az containerapp revision show --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <revision-name> --query "properties.runningState" -o tsv
# => RunningAtMaxScale (待っても変化しない)
```

コンテナー内部の実際のTCP接続を確認すると、外部クライアントが誰もいないにもかかわらず
25565番ポートに内部アドレスからの `ESTAB` 接続が残っていた。

```powershell
az containerapp exec --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --replica <replica-name> --command 'ss -tnp'
# => ESTAB 0 0  100.100.204.182:25565  100.100.0.35:43240  など
```

`scale.cooldownPeriod` (120) / `pollingInterval` (30) はBicep通りに正しく設定されており、
設定不備ではなかった。

### 原因 (INC-004)

TCPスケールルール(KEDA)がプラットフォーム側で「接続あり」と判定し続ける状態に
固着していた。`scaleCooldownSeconds` や `tcpConcurrentConnections` の値を調整しても
解消しない、プラットフォーム側のコネクション追跡に起因する問題と判断した
(直前の `deactivate`/`activate` による強制操作が引き金になった可能性がある)。

### 解決策 (INC-004)

TCPスケールルールに依存せず、`az containerapp revision deactivate` でリビジョンを
非アクティブ化して強制的にレプリカを0にする方法が確実に機能することを確認した。

### 対応した恒久対策 (INC-004)

| 対象 | 変更内容 |
| --- | --- |
| `scripts/lib/containerapp.ps1` | リビジョンがアクティブかどうかを調べる `Test-RevisionActive` を追加 |
| `scripts/stop-server.ps1` | `-Force` スイッチを追加。ワールド保存後、TCPスケールルールを待たずに `revision deactivate` でレプリカを確実に0にする |
| `scripts/start-server.ps1` | リビジョンが非アクティブな場合、TCP接続を張る前に自動で `revision activate` するよう修正 (`-Force` で停止した後も手作業なしで再開できる) |
| `docs/operations.md` / `docs/troubleshooting.md` | 症状の診断コマンドと `-Force` の使い方を追記 |

---

## INC-005: `az containerapp exec` の `&&` 誤作動とレート制限

**発生日**: 2026-09-05 / **影響**: dev環境。`backup-world.ps1` / `restore-world.ps1`
が失敗し、バックアップ・復元ができなかった

### 概要 (INC-005)

`restore-world.ps1` 実行中に以下のエラーが発生した。

```text
-rf: 1: Syntax error: Unterminated quoted string
```

`$LASTEXITCODE` は0になっておりスクリプトはエラーに気づかず先に進んだが、実際には
`tar` 展開が一度も実行されておらず、最終的に整合性確認(`level.dat`の存在確認)で
失敗した。

別の日には別の事象として、`az containerapp exec` 自体が以下の例外で失敗することもあった。

```text
websocket._exceptions.WebSocketBadStatusException: Handshake status 429 Too Many Requests
```

`retry-after: 600` (10分) と表示されるが、1時間後に再試行しても同じ429が発生した。
この際、`restore-world.ps1` は実際の原因(レート制限)ではなく「バックアップファイルが
見つかりません」と誤ったエラーを表示し、原因切り分けを難しくしていた。

### 原因 (INC-005)

**問題1: `&&` の誤解釈**。`az` はWindows上では `az.cmd` であり、PowerShellから
`--command "sh -c 'rm -rf ... && tar -xzf ... && echo done'"` のような `&&` を含む文字列を
渡すと、cmd.exe層で `&&` がコマンド区切り文字として誤解釈される。結果、閉じ引用符のない
壊れたコマンド(`sh -c 'rm -rf ...`)だけがコンテナーに届き、`rm` が欠落して
`-rf` がシェル名(`$0`)として扱われ構文エラーになる。分断された後半部分
(`tar -xzf ... && echo done'`)はローカルで無害に評価されるため `$LASTEXITCODE` が偶然0になり、
スクリプトが失敗に気づけない。

**問題2: `az containerapp exec` のレート制限**。このセッション中に `az containerapp exec`
(`ss -tnp`、`rcon-cli stop`、`save-all flush` など)を短時間に多用した結果、プラットフォーム側の
 exec/SSHエンドポイントが429でレート制限された。`retry-after`ヘッダーの値より実際の回復に
は長くかかる場合がある。

### 解決策 (INC-005)

**問題1への対応**: `sh -c '複合コマンド'` のような `&&`/パイプ/入れ子引用符を含む
文字列を一切使わず、**単純なコマンドを1つずつ個別のexec呼び出しに分割する** よう修正した
(`rm`や`tar`は複数引数を直接受け付けられるためシェルの`&&`は不要)。世代管理の
`ls | tail | xargs` パイプ処理も、一覧取得のみexecで行い、上位N件の判定と削除対象の
挙出はPowerShell側で行うように変更した。

**問題2への対応**: `Invoke-ContainerAppExecCommand` ヘルパーを新設し、exec失敗時に出力に
`429`/`Too Many Requests` が含まれていればレート制限である旨を明示するようにした。これにより
「ファイルが見つからない」などの誤ったエラーで悩まされることがなくなった。

### 確認した安全性

失敗後も `status-server.ps1` でサーバー本体・ワールドデータに影響がないことを確認した。
`restore-world.ps1` は「存在確認」ステップで失敗する仕様なので、破壊的な `rm -rf` は
一度も実行されていなかった。修正後はレート制限が解除された後の再試行で復元が成功した。

### 対応した恒久対策 (INC-005)

| 対象 | 変更内容 |
| --- | --- |
| `scripts/lib/containerapp.ps1` | `Invoke-ContainerAppExecCommand` を追加。exec失敗時に429/レート制限を検知して明示する |
| `scripts/restore-world.ps1` | `sh -c '複合コマンド'` を廃止し、`ls`→`rm -rf`→`tar -xzf`→`ls` の単純コマンド4つに分割。`-BackupFileName` は `Split-Path -Leaf` でファイル名/フルパスどちらも受け付けるよう修正 |
| `scripts/backup-world.ps1` | 同様に `mkdir -p && tar -czf`、`ls\|tail\|xargs` を廃止し、世代管理ロジックをPowerShell側に移動 |
| `scripts/stop-server.ps1` | `rcon-cli save-all flush` 呼び出しも `Invoke-ContainerAppExecCommand` 経由に統一 |
| `docs/backup-restore.md` | `-BackupFileName` はファイル名・フルパスどちらも可である旨を注記 |

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

### 8. プラットフォームの「復旧操作」自体が新たな競合を生みうる

INC-002の教訓を踏まえて `minReplicas` 変更は避けていても、`revision restart` のような
一見無害な単一コマンドが同じ排他ロック競合を引き起こすことがある(INC-003)。
ステートフルな単一インスタンスアプリでは、「稼働中のレプリカに対して何かを再起動・更新する」
操作全般を疑い、実行前に「新旧が一時的に共存しうるか」を確認する。

### 9. スケール制御が信用できないときは、スケールルールを迂回する経路を用意する

TCPスケールルールは外部要因(プラットフォーム側のコネクション追跡)で固着することがあり
(INC-004)、`scaleCooldownSeconds` 等のパラメーター調整では解決できない。
自動スケーリングに完全依存せず、`revision deactivate`/`activate` のような
スケールルールを経由しない確実な停止・起動手段を運用スクリプト側に用意しておくと、
原因調査中でも復旧を止められる。

### 10. PowerShellからWindows版のCLIラッパー(`.cmd`)にシェルメタ文字を渡さない

`az`のような`.cmd`ラッパー経由のコマンドに `&&`・`|`・入れ子引用符を含む文字列を渡すと、
 cmd.exe層で誤解釈され、一部が欠落したまま実行されても `$LASTEXITCODE` は成功として
返ってくることがある(INC-005)。対策は「シェルの組み立てを必要としない単純なコマンドの
連続実行」に分解すること。結果の検証は終了コードだけではなく、必ず実際の出力内容(ファイルの
存在や内容)で行う。
