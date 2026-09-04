# 運用手順 (Operations)

## サーバーの起動

### 方法1: TCP接続による自動起動 (scale-to-zeroからの自動復帰)

MinecraftクライアントからサーバーIPへ接続すると、TCPスケールルールによって
自動的にレプリカが0→1へスケールアウトされます。ただし、Minecraftサーバーの
起動には数十秒〜数分かかるため、初回接続はタイムアウトする可能性があります。
その場合は、Minecraftクライアントで数回再接続を試みてください。
詳細な検証結果は `docs/troubleshooting.md` の「コールドスタート検証」を参照してください。

### 方法2: GitHub Actionsによる明示的な起動 (推奨)

1. GitHub リポジトリの Actions タブから `Start Minecraft Server` workflowを選択
2. `Run workflow` から対象環境 (`dev`/`prod`) を選択して実行
3. レプリカの起動、TCP 25565への接続確認まで自動的に待機します

workflowは `DEV_CONTAINER_APP_NAME` / `PROD_CONTAINER_APP_NAME` のGitHub Variablesを参照します。
`namePrefix` を変更した場合は、生成されるContainer App名 (`<namePrefix>-minecraft`) に合わせてください。

### 方法3: PowerShellスクリプトによる明示的な起動

```powershell
./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

## サーバーの停止

全員が退出した後、Container Appsの `minReplicas=0` により一定時間の無通信を経て
自動的にスケールインされます。ただし、確実にワールドを保存してから停止したい場合は
以下の明示的な停止手順を利用してください。

### GitHub Actions

`Stop Minecraft Server` workflowを実行してください。実行中のレプリカがある場合、
`rcon-cli save-all flush` によるワールド保存後にminReplicasを0へ変更します。

### PowerShellスクリプト

```powershell
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

## 状態確認

```powershell
./scripts/status-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

レプリカ数、Ingress FQDN、稼働状態などが表示されます。上記の `mcaca-dev-minecraft` は
既定の `namePrefix` を使った場合の例です。

## ホワイトリスト/op権限の変更

`infra/environments/<env>.bicepparam` の `whitelistUsers` / `opUsers` を変更し、
再デプロイ (`deploy-dev.yml` / `deploy-prod.yml` または `scripts/deploy.ps1`) してください。
Container Appsの環境変数(`WHITELIST`, `OPS`)は起動時にitzg/minecraft-serverが
`whitelist.json` / `ops.json` へ反映します。

> 補足: itzgイメージは既存の `whitelist.json` がある場合、環境変数の内容とマージ/上書き
> する挙動を持ちます。既存ファイルの内容を直接編集したい場合は、
> `az containerapp exec` でコンテナーへ接続して編集することも可能です。

## ログ確認

Log Analytics workspaceで以下のクエリを実行してください(Container Apps環境ログ)。

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "mcaca-dev-minecraft"
| order by TimeGenerated desc
| take 200
```

`namePrefix` を変更している場合は、`ContainerAppName_s` を実際のContainer App名に置き換えてください。

## メンテナンスウィンドウの考え方

少人数利用を想定しているため、明示的なメンテナンスウィンドウは設けていません。
バージョン更新やパラメーター変更を行う際は、事前に `Stop Minecraft Server` を実行し
全プレイヤーが安全に退出していることを確認してから作業してください。
