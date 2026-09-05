# トラブルシューティング (Troubleshooting)

> 過去に実際に発生した障害の経緯と学びは `docs/incident-records.md` にまとめています。

## コールドスタート検証

### 検証目的

scale-to-zero状態からのTCP自動起動が実用的かどうかを判断するため、以下の項目を
計測・文書化します。**本タスクの実行環境ではAzureサブスクリプションへの実デプロイが
できなかったため、以下は計測手順と一般的な目安であり、実測値は実運用環境での
検証後に追記する必要があります (TODO)。**

### 計測項目と手順

| 項目 | 計測方法 | 目安 (実測前の想定値) |
| --- | --- | --- |
| レプリカ0からレプリカ起動までの時間 | `az containerapp replica list` を1〜2秒間隔でポーリングし、`runningState=Running` になるまでの時間を記録 | 数秒〜30秒程度 (Container Apps基盤のコールドスタート時間に依存) |
| コンテナー起動からMinecraft接続可能までの時間 | Log Analyticsでコンテナーログの起動メッセージ("Done (...)! For help, type help") のタイムスタンプと、レプリカ起動時刻の差分を計測 | ワールドサイズ・CPU/メモリ割り当てに依存し、10秒〜数分 |
| 初回接続がタイムアウトするか | Minecraftクライアントから、レプリカ0の状態で接続を試行し、クライアント側のタイムアウト挙動を確認 | Minecraftクライアントの接続タイムアウトは短い場合が多く、初回接続は失敗する可能性が高い |
| 必要な再接続回数 | 上記の初回接続失敗後、一定間隔で再接続を試み、成功するまでの試行回数を記録 | 起動時間に応じて2〜5回程度を想定 |
| 全員退出後にレプリカ0になるまでの時間 | 全プレイヤー切断後、`az containerapp replica list` をポーリングし、レプリカが消滅するまでの時間を記録 | Container Apps既定のスケールインクールダウン時間に依存(既定は概ね数分程度) |

### 検証結果記録用テンプレート

実際に検証した際は、以下の形式で本ドキュメントへ追記してください。

```text
検証日: YYYY-MM-DD
環境: dev / prod
CPU/メモリ: <cpuCores> / <memorySize>
ワールドサイズ: <おおよそのサイズ>

- レプリカ0→起動: XX秒
- コンテナー起動→接続可能: XX秒
- 初回接続タイムアウト: あり/なし
- 必要な再接続回数: X回
- 全員退出→レプリカ0: XX秒
```

### TCP自動起動が実用的でない場合の代替手段

Minecraftクライアントの接続タイムアウトが短く、TCPスケールルールによる自動起動が
実用に耐えない場合は、**プレイヤーが接続する前に明示的にサーバーを起動する運用**を
正式な代替手段として提供しています。

- GitHub Actions: `Start Minecraft Server` workflow (`start-server.yml`)
- PowerShell: `scripts/start-server.ps1`

これらはレプリカ起動とTCP 25565への接続確認まで待機するため、実行完了後に
Minecraftクライアントから接続すれば確実に成功します。

## よくある問題

### サーバーに接続できない

1. `./scripts/status-server.ps1` でレプリカが起動しているか確認する
2. 起動していない場合は `start-server.yml` または `start-server.ps1` を実行する
3. ホワイトリストに接続したいプレイヤーのユーザー名/UUIDが登録されているか確認する
   (`whitelistUsers` パラメーター、Bicep再デプロイが必要)
4. ONLINE_MODEが有効な場合、Microsoftアカウントでの認証が必要になるため、
   オフラインモードのクライアントでは接続できない点に注意する

### デプロイが失敗する (Storage Account名の重複)

Storage Account名はグローバルに一意である必要があります。本実装では `namePrefix` と
リソースグループIDから生成したsuffixを含めて衝突しにくくしています。それでも重複した場合は、
`namePrefix` またはリソースグループを変更してください。`namePrefix` を変更した場合は、
GitHub Variables の `DEV_CONTAINER_APP_NAME` / `PROD_CONTAINER_APP_NAME` も合わせて更新します。

### Azure Filesへの接続エラー

- Storage Accountの `networkAcls` がVNet統合されたサブネットからのアクセスのみを
  許可する設定になっているため、サブネットのサービスエンドポイント (`Microsoft.Storage`)
  が有効になっているか確認してください (`network.bicep` で自動設定済み)。
- `mount.nfs: access denied by server while mounting` となる場合は、Storage Accountの
  `supportsHttpsTrafficOnly` (Secure transfer required) が `true` になっていないか確認して
  ください。Container AppsはNFSの転送時暗号化に対応していないため `false` である必要があります。

### コンテナーがCrashLoopBackOffを繰り返す (java.io.IOException: Permission denied)

```text
[ServerMain/ERROR]: Failed to start the minecraft server
java.io.IOException: Permission denied
    at net.minecraft.util.DirectoryLock.create(DirectoryLock.java:35)
```

`/data` がSMB(cifs)でマウントされている場合に発生します。Minecraftがワールドの
`session.lock` を作成できないことが原因で、`mountOptions` の調整では解決しません。
`docs/architecture.md` の「ストレージにNFSを使う理由」を参照し、Azure Filesの共有を
NFS 4.1 (Premium FileStorage) で構成してください。

なお、Container AppsのTCP Ingressはバックエンドが異常でもTCPハンドシェイクを成立させるため、
「ポート25565に接続できる」だけではサーバーの正常性を判断できません。
`scripts/start-server.ps1` / `scripts/status-server.ps1` はServer List Ping
(`scripts/lib/minecraft-ping.ps1`) でサーバー本体の応答まで確認します。

### status-server.ps1 が「レプリカは起動しているがステータス応答を返さない」と表示する

レプリカは動いているものの、Minecraftサーバープロセスが起動途中か異常終了している状態です。
初回起動やバージョン更新直後は数十秒かかることがあるため、まず少し待ってから再実行してください。
それでも解消しない場合はコンテナーのログを確認します。

```powershell
az containerapp logs show --name mcaca-dev-minecraft --resource-group rg-minecraft-dev --container minecraft --tail 100
```

### 「レプリカ0（停止中）」と表示されるのに実際は接続して遊べる

新旧リビジョンが競合してデッドロックしている可能性があります。次のコマンドで確認してください。

```powershell
az containerapp show --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --query "{latest:properties.latestRevisionName,latestReady:properties.latestReadyRevisionName}" -o json
```

`latest` と `latestReady` が異なる場合、最新リビジョンが起動できず、旧リビジョンが稼働を
続けています。コンテナーのログには次のエラーが出ます。

```text
net.minecraft.util.DirectoryLock$LockException: /data/./world/session.lock: already locked (possibly by other Minecraft instance?)
```

原因は、旧リビジョンのレプリカがワールドを排他ロックしたまま新リビジョンが起動しようとしたことです。
`az containerapp update --min-replicas` の実行やデプロイが引き金になります。詳細は
`docs/architecture.md` の「単一インスタンス制約と『minReplicasを変更しない』運用」を参照してください。

復旧手順:

```powershell
# 1. 稼働中リビジョンでワールドを保存し、停止する
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force

# 2. 起動できなかったリビジョンを非アクティブ化する
az containerapp revision deactivate --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <latestRevisionName>

# 3. 改めて起動する
./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

なお `scripts/lib/containerapp.ps1` を経由する運用スクリプトは、この状態を検出すると警告を表示します。

### `revision restart` 実行後にレプリカがデッドロックする

稼働中のレプリカに対して `az containerapp revision restart` を実行すると、
**同一リビジョン内で**新旧2つのレプリカが同時に存在する状態になることがあります。
新レプリカはワールドの `session.lock` を取得できず無限にクラッシュし、旧レプリカは
(新レプリカがReadyにならないため)生き残り続けるデッドロックに陥ります。

```powershell
az containerapp replica list --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <revision-name> --query "[].{name:name,state:properties.runningState,restarts:properties.containers[0].restartCount}" -o table
```

同一リビジョンに `Running` と `CrashLoopBackOff` のレプリカが両方表示される場合、この状態です。
`latestRevisionName` と `latestReadyRevisionName` は一致するため、前項の「新旧リビジョン競合」の
検出ロジックでは気づけない点に注意してください。`rcon-cli stop` で旧レプリカを止めても
プラットフォームが同じレプリカを自動再起動するだけで解消しません。リビジョンごと
非アクティブ化・再アクティブ化することで、すべてのレプリカを完全に停止させてから
クリーンな状態で起動し直してください。

```powershell
# 1. リビジョンを非アクティブ化し、すべてのレプリカを完全に停止させる
az containerapp revision deactivate --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <revision-name>

# 2. 全レプリカがNotRunning/Terminatedになったことを確認する
az containerapp replica list --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <revision-name> --query "[].properties.runningState" -o tsv

# 3. リビジョンを再アクティブ化し、クリーンな単一レプリカで起動し直す
az containerapp revision activate --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <revision-name>
```

そもそも `revision restart` は、対象レプリカが完全に停止している(レプリカ0)状態でのみ
実行するようにしてください。稼働中のまま実行しないことが最も確実な予防策です。

### サーバーが停止しない / スケールインしない

TCPスケールルールが接続なしでも `RunningAtMaxScale` のまま固着し、`scaleCooldownSeconds`
(dev: 120秒 / prod: 300秒) を待っても自動的にスケールインしないことが確認されています。
そのため停止時は待機に頼らず、基本的に `-Force` を付けて実行してください
(詳細は次項「TCPスケールルールが固着してスケールインしない」を参照)。

```powershell
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force
```

`-Force` を付けずに待機した場合は、以下を確認してください。

- Minecraftクライアントのサーバー一覧画面を開いたままだとTCP接続が張られ続けます。閉じてください
- `status-server.ps1` の出力でオンラインプレイヤーが0であること

### TCPスケールルールが固着してスケールインしない (`RunningAtMaxScale`)

プレイヤーが0人 (`status-server.ps1` のServer List Pingで確認済み) にもかかわらず、
`stop-server.ps1` を`scaleCooldownSeconds`を超える時間待ってもレプリカが0にならない事象が、
複数日にわたって継続して観測されています。次のコマンドでリビジョンの `runningState` を
確認してください。

```powershell
az containerapp revision show --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --revision <revision-name> --query "properties.runningState" -o tsv
```

`RunningAtMaxScale` のまま変化しない場合、TCPスケールルール(KEDA)が「接続あり」と
判定し続けている状態です。コンテナー内部の実際のTCP接続を確認すると、外部クライアントが
いなくても内部アドレスからの `ESTAB` 接続が残っていることがあります。

```powershell
az containerapp exec --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
  --replica <replica-name> --command 'ss -tnp'
```

原因はプラットフォーム側のコネクション追跡の問題であり、`scaleCooldownSeconds` や
`tcpConcurrentConnections` の値を調整しても解消しません。自動復旧を待たず、
`scripts/stop-server.ps1` の `-Force` オプションでリビジョンを非アクティブ化して
強制的にレプリカを0にしてください。このため運用スクリプト・GitHub Actions workflow・
ドキュメントの停止手順はすべて `-Force` を標準として使うようにしています。

```powershell
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force
```

`-Force` はワールド保存後に `az containerapp revision deactivate` を実行し、TCP接続の状態に
関わらずレプリカを確実に0にします。次回 `scripts/start-server.ps1` を実行すると、非アクティブな
リビジョンを自動的に再アクティブ化してから起動するため、追加の手作業は不要です。

### RCON経由のコマンドが失敗する

- `az containerapp exec` はレプリカが起動している場合のみ実行可能です。
  レプリカ0の状態では失敗するため、事前に `start-server.ps1` 等でレプリカを
  起動してください。
- RCONパスワードが正しく設定されているか (`rconPassword` パラメーター) を確認してください。

### バージョン更新後にワールドが読み込めない

- Minecraftはワールドフォーマットのダウングレードをサポートしていません。
  `docs/version-upgrade.md` の手順に従い、更新前バックアップから復元してください。
