# 運用手順 (Operations)

> **前提**: `minReplicas` は常に0固定で運用します。起動・停止で `minReplicas` を変更すると
> 新しいリビジョンが生成され、新旧リビジョンがワールドの `session.lock` を奪い合って
> デッドロックします。詳細は `docs/architecture.md` の
> 「単一インスタンス制約と『minReplicasを変更しない』運用」を参照してください。

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
3. workflowは `scripts/start-server.ps1` を呼び出し、レプリカの起動と
   Minecraftサーバーのステータス応答 (Server List Ping) まで確認します

workflowは `DEV_CONTAINER_APP_NAME` / `PROD_CONTAINER_APP_NAME` のGitHub Variablesを参照します。
`namePrefix` を変更した場合は、生成されるContainer App名 (`<namePrefix>-minecraft`) に合わせてください。

### 方法3: PowerShellスクリプトによる明示的な起動

```powershell
./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

このスクリプトはポート25565へTCP接続を張って保持し、スケールルールを発火させます。
`minReplicas` は変更しないため、新しいリビジョンは生成されません。

レプリカが起動した後、Server List Pingでサーバー本体の応答を確認します。
Container AppsのTCP Ingressはバックエンドが異常でもTCPハンドシェイクを成立させるため、
「ポートに接続できる」だけでは正常性を判断できないからです。
応答が得られない場合や、コンテナーがCrashLoopBackOffを繰り返している場合はエラー終了します。

## サーバーの停止

全員が退出してTCP接続が途絶えると、`scaleCooldownSeconds`
(dev: 120秒 / prod: 300秒) の経過後に自動的にスケールインされます。
確実にワールドを保存してから停止したい場合は以下の手順を利用してください。

> Minecraftクライアントのサーバー一覧画面を開いたままだとTCP接続が継続し、
> スケールインしません。停止したいときはクライアントを閉じてください。

### GitHub Actions

`Stop Minecraft Server` workflowを実行してください。workflowは `scripts/stop-server.ps1` を
呼び出し、実行中のレプリカがある場合は `rcon-cli save-all flush` でワールドを保存したうえで
スケールインの完了を待ちます。

### PowerShellスクリプト

```powershell
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

待機を行わずに保存だけして終了したい場合は `-SkipWait` を指定してください。

## 状態確認

```powershell
./scripts/status-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

レプリカ数、Ingress FQDN、稼働状態などが表示されます。レプリカが起動している場合は
Server List Pingでサーバー本体の応答 (バージョン・接続人数) も確認します。
上記の `mcaca-dev-minecraft` は既定の `namePrefix` を使った場合の例です。

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
