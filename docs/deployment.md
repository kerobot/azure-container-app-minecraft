# デプロイ手順 (Deployment)

## 前提条件

- Azure サブスクリプションへのアクセス権限 (Contributor + User Access Administrator相当、
  もしくは対象リソースグループへのOwner権限)
- Azure CLI (`az`) 2.60以降、Bicep CLI 0.28以降
- PowerShell 7以降 (`scripts/*.ps1` を利用する場合)
- GitHub Actionsから利用する場合は、Azure ADアプリケーション登録 + フェデレーション
  資格情報(OIDC)の設定

## 1. Azure ADアプリケーション登録とOIDC設定 (初回のみ)

長期間有効なクライアントシークレットを使用しないため、GitHub ActionsとAzure間は
OIDC (OpenID Connect) によるフェデレーション認証を利用します。

```bash
# アプリ登録
az ad app create --display-name "gh-azure-container-app-minecraft"
APP_ID=$(az ad app list --display-name "gh-azure-container-app-minecraft" --query "[0].appId" -o tsv)

# サービスプリンシパル作成
az ad sp create --id "$APP_ID"

# 最小権限のロール割り当て (対象リソースグループへのContributor)
az role assignment create \
  --assignee "$APP_ID" \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>"

# フェデレーション資格情報の追加 (mainブランチからのデプロイを許可する例)
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:kerobot/azure-container-app-minecraft:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# environment: dev / prod からの実行を許可する場合
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-env-dev",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:kerobot/azure-container-app-minecraft:environment:dev",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

`prod` 環境についても同様に `environment:prod` のフェデレーション資格情報を追加してください。

## 2. GitHub リポジトリ設定

### Secrets (リポジトリ or Environment単位)

| 名称 | 用途 |
|---|---|
| `AZURE_CLIENT_ID` | OIDC用アプリケーションID |
| `AZURE_TENANT_ID` | AzureテナントID |
| `AZURE_SUBSCRIPTION_ID` | サブスクリプションID |
| `DEV_MINECRAFT_RCON_PASSWORD` | dev環境のRCONパスワード |
| `PROD_MINECRAFT_RCON_PASSWORD` | prod環境のRCONパスワード |

### Variables

| 名称 | 用途 |
|---|---|
| `AZURE_LOCATION` | デプロイ先リージョン (例: japaneast) |
| `AZURE_RESOURCE_GROUP_DEV` | dev環境のリソースグループ名 |
| `AZURE_RESOURCE_GROUP_PROD` | prod環境のリソースグループ名 |
| `DEV_MINECRAFT_WHITELIST_USERS` | devのホワイトリストユーザー (カンマ区切り) |
| `DEV_MINECRAFT_OP_USERS` | devのop権限ユーザー |
| `PROD_MINECRAFT_WHITELIST_USERS` | prodのホワイトリストユーザー |
| `PROD_MINECRAFT_OP_USERS` | prodのop権限ユーザー |

### GitHub Environments

`prod` 環境には、Settings > Environments から必須レビュアーによる承認ルールを設定してください。
これにより `deploy-prod.yml` の実行前に承認が必要となります。

## 3. デプロイ方法

### GitHub Actions経由 (推奨)

- `dev`: `infra/**` への変更を `main` ブランチへpushすると `deploy-dev.yml` が自動実行されます。
  手動実行も可能です (`workflow_dispatch`)。
- `prod`: `deploy-prod.yml` を手動実行してください。GitHub Environmentの承認後にデプロイされます。

### PowerShellスクリプト経由

```powershell
# What-If (変更内容のプレビューのみ)
./scripts/deploy.ps1 -Environment dev -ResourceGroupName rg-minecraft-dev -WhatIf

# 実際のデプロイ
$rcon = Read-Host -AsSecureString "RCON Password"
./scripts/deploy.ps1 -Environment dev -ResourceGroupName rg-minecraft-dev -RconPassword $rcon -WhitelistUsers "player1,player2"
```

### Azure CLI直接実行

```bash
az deployment group create \
  --resource-group rg-minecraft-dev \
  --template-file infra/main.bicep \
  --parameters infra/environments/dev.bicepparam \
  --parameters rconPassword='<SECRET>' whitelistUsers='player1,player2'
```

## 4. デプロイ後の確認

```bash
./scripts/status-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

初回デプロイ直後は `minReplicas=0` のため、レプリカは起動していません。
サーバーへ接続するには `start-server.yml` またはTCP接続による自動起動を利用してください。
