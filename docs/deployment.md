# デプロイ手順 (Deployment)

本ドキュメントのコマンドはすべて **PowerShell 7以降** (`pwsh`) での実行を前提としています。
bash等の他シェルを使う場合は、変数代入 (`$VAR = ...`) や行継続 (`` ` ``) の書き方をお使いの
シェルの流儀に読み替えてください。

## この手順の進め方 (迷ったらここを読んでください)

はじめてこのマイクラ環境を試す方でも迷わないように、状況別の進め方を整理しています。

| あなたの状況 | 進め方 |
| --- | --- |
| 一人(少人数)でとにかく試したい。コマンドを1つずつ実行しながら理解したい | **メイン手順 (1章): PowerShellスクリプトで直接デプロイ** |
| チームで運用したい。`main`ブランチへのpushやworkflow実行だけでデプロイを自動化したい | **選択手順 (2章): GitHub Actions経由** (事前にOIDC設定が必要) |
| Bicep/Azure CLIの詳細を自分で細かく制御したい上級者 | **選択手順 (3章): Azure CLIを直接実行** |
| デプロイに失敗した/環境が不要になったので削除したい | **5章: 作成したリソースの削除 (クリーンアップ)** |

迷ったら、まずは **メイン手順(1章)** だけで最後まで進められます。GitHub Actionsの設定
(2章)は、チーム運用やCI/CD化が必要になったタイミングで読めば十分です。

## 0. 前提条件

- Azure サブスクリプションへのアクセス権限 (Contributor + User Access Administrator相当、
  もしくは対象リソースグループへのOwner権限)
- **PowerShell 7以降** (`pwsh`)。Windows標準の PowerShell 5.1 ではなく、
  [PowerShell 7のインストール](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
  が必要です。インストール確認は `$PSVersionTable.PSVersion` で行えます。
- Azure CLI (`az`) 2.60以降、Bicep CLI 0.28以降
  - インストール確認: `az version`
  - 未インストールの場合は [Azure CLI のインストール](https://learn.microsoft.com/cli/azure/install-azure-cli) を参照してください
- 選択手順 (2章: GitHub Actions経由) を使う場合のみ、Azure ADアプリケーション登録と
  フェデレーション資格情報(OIDC)の設定が事前に必要です

> **コストに関する注意**: ワールドデータはAzure FilesのNFS 4.1共有へ保存します。NFSは
> **Premium FileStorage** でのみ利用でき、共有の最小容量は **100GiB** です。この分は
> サーバーを停止していても継続して課金されます (Container App自体は `minReplicas=0` の間は
> 課金されません)。NFSが必要な理由は `docs/architecture.md` の
> 「ストレージにNFSを使う理由」を参照してください。

## 1. メイン手順: PowerShellスクリプトで直接デプロイ

手元のPowerShellから、Azureへのログイン→デプロイ→サーバー起動→接続確認までを行います。

### 1-1. Azureへログイン

```powershell
az login
# ブラウザが開けない環境の場合はデバイスコード認証を使う
az login --use-device-code
# テナントを指定してログインする場合
az login --tenant <TENANT_ID>
```

ログイン後、想定通りのサブスクリプションが選択されているか確認してください。

```powershell
az account show --output table
# 別のサブスクリプションに切り替える場合
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"
```

### 1-2. パラメーターの確認 (任意)

`infra/environments/dev.bicepparam` (prod環境の場合は `prod.bicepparam`) を開き、必要に応じて
`minecraftVersion` やCPU/メモリ等を編集してください。初回はデフォルト値のままで問題ありません。

> **prod環境の場合**: `prod.bicepparam` の `minecraftVersion` は意図しない自動更新を避けるため
> `readEnvironmentVariable('MINECRAFT_VERSION', '26.2')` で固定バージョンを参照します。
> 既定の `26.2` で良ければ何もする必要はありませんが、`deploy.ps1` にはバージョン指定用の
> 引数がないため、別バージョンに固定したい場合はデプロイ実行前に環境変数を設定してください。
>
> ```powershell
> $env:MINECRAFT_VERSION = '26.2'
> ```

### 1-3. RCONパスワードの準備

`scripts/deploy.ps1` はWhat-Ifを含め、必ずRCONパスワードの指定を要求します
(`-RconPassword` 未指定かつ環境変数 `MINECRAFT_RCON_PASSWORD` も未設定だとエラーになります)。
コマンド履歴やログに平文で残らないよう、`SecureString` として入力してください。

```powershell
$rcon = Read-Host -AsSecureString "RCON Password"
```

以降の手順では、この `$rcon` を毎回 `-RconPassword` に渡します。

### 1-4. What-If でデプロイ内容を確認 (推奨)

実際にリソースを変更する前に、何が作成・変更されるかを確認できます。
指定したリソースグループが存在しない場合は、自動的に作成されます。

```powershell
./scripts/deploy.ps1 -Environment dev -ResourceGroupName rg-minecraft-dev -RconPassword $rcon -WhatIf
```

### 1-5. デプロイの実行

```powershell
./scripts/deploy.ps1 -Environment dev -ResourceGroupName rg-minecraft-dev -RconPassword $rcon -WhitelistUsers "player1,player2" -OpUsers "player1"
```

- `-WhitelistUsers` : サーバーへの接続を許可するプレイヤー名 (カンマ区切り)
- `-OpUsers` : op(管理者)権限を与えるプレイヤー名 (カンマ区切り)

> **2回目以降のデプロイは、先にサーバーを停止してください。**
> デプロイは新しいリビジョンを作成しますが、旧リビジョンが稼働したままだと
> ワールドの `session.lock` が競合し、新リビジョンが起動できなくなります。
> `deploy.ps1` は稼働中を検知するとデプロイを中止します (確認済みで続行する場合は
> `-SkipRunningCheck`)。背景は `docs/architecture.md` の
> 「単一インスタンス制約と『minReplicasを変更しない』運用」を参照してください。
>
> ```powershell
> ./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force
> ```

prod環境へデプロイする場合は、以下の点が追加で異なります。

> **prod環境の場合**: `-Environment prod` とprod用のリソースグループ名を指定します。
>
> ```powershell
> ./scripts/deploy.ps1 -Environment prod -ResourceGroupName rg-minecraft-prod -RconPassword $rcon -WhitelistUsers "player1,player2" -OpUsers "player1"
> ```
>
> `dev.bicepparam` は `whitelistUsers` の既定値に `dev-user1,dev-user2` を持ちますが、
> `prod.bicepparam` の既定値は空文字列です。prodデプロイ時に `-WhitelistUsers` を付け忘れると
> `enableWhitelist = true` のままホワイトリストが空になり、**誰も接続できなくなる**ため注意してください。

### 1-6. サーバーの起動と接続確認

デプロイ直後は `minReplicas=0` のためサーバーは起動していません。以下で起動します。
このスクリプトはTCP接続を張ってスケールルールを発火させるため、新しいリビジョンは作られません。

```powershell
./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

起動状態(レプリカ数、接続先FQDN等)は以下で確認できます。

```powershell
./scripts/status-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

表示されたIngress FQDNとポート25565を使い、Minecraftクライアントから接続を確認してください。
使い終わったら以下でワールドを保存し、確実にレプリカを0にします。TCPスケールルールが
接続なしでも `RunningAtMaxScale` のまま固着し自動でスケールインしないことがあるため、
`-Force` を付けて停止してください (詳細は `docs/troubleshooting.md` の
「TCPスケールルールが固着してスケールインしない」を参照)。

```powershell
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force
```

> **prod環境の場合**: `-ResourceGroupName` にprod用のリソースグループ名、`-AppName` に
> `mcaca-prod-minecraft` (`namePrefix` が既定のままの場合) を指定してください。
> `status-server.ps1` / `stop-server.ps1` も同様です。

ここまでで構築・起動・停止の一連の流れは完了です。継続的な運用方法は
`docs/operations.md` を参照してください。チーム運用やCI/CD化が必要になったら、
次の2章 (GitHub Actions経由) の設定を検討してください。

### 1-7. prod環境をデプロイする場合の追加の注意点

PowerShellから直接prodをデプロイする場合、devとの違いは基本的にここまでの
`-Environment prod` とリソース名の指定だけですが、以下の2点は仕組み上devとは異なる
挙動になるため把握しておいてください。

- **GitHub Environmentの承認フローは適用されません**: 2章で設定する `prod` GitHub
  Environmentの必須レビュアー承認は、GitHub Actions経由のデプロイにのみ効果があります。
  PowerShellから直接実行する場合はこの承認プロセスを通らずに即座にデプロイされるため、
  本番デプロイに承認を必須にしたい運用では2章のGitHub Actions経由の手順を使ってください。

- **Storage Accountに削除ロックが自動付与されます**: `prod.bicepparam` は
  `enableStorageDeleteLock = true` のため、後で環境を削除する際は
  「5-1. 削除防止ロックの解除」の手順が追加で必要になります。

## 2. 選択手順: GitHub Actions経由 (CI/CDで自動化したい場合)

以下に当てはまる場合はこちらの手順を選んでください。当てはまらない場合はこの章を
読み飛ばして構いません。

- 複数人で運用し、`main`ブランチへのpushやworkflow実行だけでデプロイを完結させたい
- 各メンバーの手元にAzure CLI/PowerShellの実行環境を用意したくない
- `prod`環境へのデプロイに承認フローを設けたい (GitHub Environmentsの必須レビュアー機能)

### 2-1. Azure ADアプリケーション登録とOIDC設定 (初回のみ)

長期間有効なクライアントシークレットを使用しないため、GitHub ActionsとAzure間は
OIDC (OpenID Connect) によるフェデレーション認証を利用します。

```powershell
# Azureログイン (1章の手順を実施済みなら不要)
az login

# アプリ登録
az ad app create --display-name "gh-azure-container-app-minecraft"
$APP_ID = az ad app list --display-name "gh-azure-container-app-minecraft" --query "[0].appId" -o tsv

# サービスプリンシパル作成
az ad sp create --id "$APP_ID"

# リソースグループの作成（ロール割り当てのため先に作成しておく）
az group create `
  --name rg-minecraft-dev `
  --location japaneast

# 最小権限のロール割り当て (対象リソースグループのみへのContributor)
az role assignment create `
  --assignee "$APP_ID" `
  --role "Contributor" `
  --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>"

# フェデレーション資格情報の追加 (mainブランチからのデプロイを許可する例)
$jsonFile = Join-Path $env:TEMP "github-main-federated-credential.json"

# owner_id と repo_id は GitHub リポジトリの Settings → Actions → OIDC から確認可能
@'
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:kerobot@<owner_id>/azure-container-app-minecraft@<repo_id>:ref:refs/heads/main",
  "description": "GitHub Actions main branch",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
'@ | Set-Content -Path $jsonFile -Encoding UTF8

az ad app federated-credential create --id $APP_ID --parameters "@$jsonFile"

Remove-Item $tempFile

# environment: dev / prod からの実行を許可する場合
$jsonFile = Join-Path $env:TEMP "github-env-dev.json"

@'
{
  "name": "github-env-dev",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:kerobot@<owner_id>/azure-container-app-minecraft@<repo_id>:environment:dev",
  "description": "GitHub Actions development environment deployment",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
'@ | Set-Content -Path $jsonFile -Encoding UTF8

az ad app federated-credential create --id $APP_ID --parameters "@$jsonFile"

Remove-Item $jsonFile

# フェデレーション資格情報を確認する場合

az ad app federated-credential list --id $APP_ID --output table

# フェデレーション資格情報を削除する場合

az ad app federated-credential delete --id $APP_ID --federated-credential-id github-env-dev
```

`prod` 環境についても同様に `environment:prod` のフェデレーション資格情報を追加してください。

### 2-2. GitHub リポジトリ設定

#### 確認方法

```powershell
# AzureテナントID
az account show --query tenantId -o tsv

# サブスクリプションID
az account show --query id -o tsv

# OIDC用アプリケーションID（Client ID）
az ad app list --display-name "gh-azure-container-app-minecraft" --query "[0].appId" -o tsv
```

#### Secrets (リポジトリ or Environment単位)

| 名称 | 用途 |
| --- | --- |
| `AZURE_CLIENT_ID` | OIDC用アプリケーションID |
| `AZURE_TENANT_ID` | AzureテナントID |
| `AZURE_SUBSCRIPTION_ID` | サブスクリプションID |
| `DEV_MINECRAFT_RCON_PASSWORD` | dev環境のRCONパスワード |
| `PROD_MINECRAFT_RCON_PASSWORD` | prod環境のRCONパスワード |

#### Variables

| 名称 | 用途 |
| --- | --- |
| `AZURE_LOCATION` | デプロイ先リージョン (例: japaneast) |
| `AZURE_RESOURCE_GROUP_DEV` | dev環境のリソースグループ名 |
| `AZURE_RESOURCE_GROUP_PROD` | prod環境のリソースグループ名 |
| `DEV_CONTAINER_APP_NAME` | dev環境のContainer App名 (既定例: `mcaca-dev-minecraft`) |
| `PROD_CONTAINER_APP_NAME` | prod環境のContainer App名 (既定例: `mcaca-prod-minecraft`) |
| `DEV_MINECRAFT_WHITELIST_USERS` | devのホワイトリストユーザー (カンマ区切り) |
| `DEV_MINECRAFT_OP_USERS` | devのop権限ユーザー (任意。未設定時は空になります) |
| `PROD_MINECRAFT_WHITELIST_USERS` | prodのホワイトリストユーザー |
| `PROD_MINECRAFT_OP_USERS` | prodのop権限ユーザー (任意。未設定時は空になります) |

`*_MINECRAFT_OP_USERS` は `opUsers` パラメーター(既定値 `''`)に対応する任意項目のため、
`deploy-dev.yml` 等のworkflowでは必須設定チェックの対象にしていません。
一方 `*_MINECRAFT_WHITELIST_USERS` は既定値のない必須パラメーターに対応するため、
未設定の場合はデプロイ前のチェックで失敗します。

`namePrefix` を変更する場合は、生成されるContainer App名 (`<namePrefix>-minecraft`) に合わせて
`DEV_CONTAINER_APP_NAME` / `PROD_CONTAINER_APP_NAME` も更新してください。

Storage Account名には `namePrefix` とリソースグループIDから生成した短いsuffixを含めます。
既存環境で命名ロジックを変更すると新しいStorage Accountが作成される可能性があるため、
適用前に既存Azure Filesの移行要否を確認してください。

#### GitHub Environments

`prod` 環境には、Settings > Environments から必須レビュアーによる承認ルールを設定してください。
これにより `deploy-prod.yml` の実行前に承認が必要となります。

### 2-3. デプロイの実行

- `dev`: `infra/**` への変更を `main` ブランチへpushすると `deploy-dev.yml` が自動実行されます。
  手動実行も可能です (`workflow_dispatch`)。
- `prod`: `deploy-prod.yml` を手動実行してください。GitHub Environmentの承認後にデプロイされます。

## 3. 選択手順: Azure CLIを直接実行 (上級者向け)

PowerShellスクリプトを介さず、Bicepデプロイの内容を自分で細かく制御したい場合の手順です。
`scripts/deploy.ps1` が内部で行っているリソースグループ存在確認や `SecureString` の扱いは
自分で行う必要があります。通常は1章のメイン手順を使えば十分です。

```powershell
az deployment group create `
  --resource-group rg-minecraft-dev `
  --template-file infra/main.bicep `
  --parameters infra/environments/dev.bicepparam `
  --parameters rconPassword='<SECRET>' whitelistUsers='player1,player2'
```

## 4. デプロイ後の確認 (共通)

```powershell
./scripts/status-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
```

初回デプロイ直後は `minReplicas=0` のため、レプリカは起動していません。
サーバーへ接続するには `scripts/start-server.ps1` (またはGitHub Actionsの`start-server.yml`)、
もしくはMinecraftクライアントからのTCP接続による自動起動を利用してください。

## 5. 作成したリソースの削除 (クリーンアップ)

デプロイに失敗した場合や、環境が不要になった場合の削除手順です。まずは状況に応じて
以下のどちらに当てはまるか確認してください。

| 状況 | 推奨アクション |
| --- | --- |
| デプロイが途中で失敗した (一部リソースだけ作成された) | 削除は不要です。`deploymentMode: Incremental` のため、原因を修正して同じデプロイコマンドを再実行すれば、成功済みのリソースはそのまま維持され、失敗した箇所のみ再試行されます |
| 検証用に作った環境を完全に削除したい、または本当に不要になった | 「5-2. リソースグループごと削除する」または「5-3. 個別リソースのみ削除する」 |

> 注意: 以下の削除操作はワールドデータ(Azure Files上の `world` 等)を含めて完全に
> 失われます。データを残したい場合は、削除前に `scripts/backup-world.ps1` でバックアップを
> 取得し、`az containerapp exec` でバックアップファイル自体を別の場所 (Blob Storage等) へ
> 退避しておいてください。NFS共有は `az storage file` や AzCopy で直接ダウンロードできません。

### 5-1. 削除防止ロックの解除 (必要な場合のみ)

Storage Accountには既定で削除防止ロック (`CanNotDelete`) が付与されます
(`enableStorageDeleteLock` パラメーター、`prod` は既定で `true`)。ロックが付いたままだと
Storage Account自体の削除、およびロックが付いたリソースを含むリソースグループの削除が
失敗するため、削除前に解除してください。

```powershell
# リソースグループ内のロック一覧を確認
az lock list --resource-group rg-minecraft-dev --output table

# ロックを削除 (既定名は '<storageAccountName>-delete-lock')
az lock delete --resource-group rg-minecraft-dev --name "<storageAccountName>-delete-lock"
```

### 5-2. リソースグループごと削除する (最も簡単)

検証用に作成した環境をまるごと削除したい場合はこちらが簡単です。リソースグループ内の
全リソース(VNet, Storage Account, Log Analytics workspace等)が削除されます。

```powershell
az group delete --name rg-minecraft-dev --yes --no-wait
```

`--no-wait` を付けると削除の完了を待たずにコマンドが返ります。完了を待つ場合は
`--no-wait` を外してください。以下のコマンドで存在するかを確認できます。

```powershell
az group exists --name rg-minecraft-dev
```

### 5-3. 個別リソースのみ削除する (リソースグループを他用途にも使っている場合)

リソースグループを削除したくない場合は、このリポジトリが作成したリソースのみを
個別に削除してください。`<namePrefix>` は既定では `mcaca-dev` / `mcaca-prod` です。

> **補足**: Container Apps Environment (`az containerapp env delete`) を削除すると、
> Azureが自動生成した `ME_<環境名>_<リソースグループ名>_<リージョン>` という管理用
> リソースグループ (ロードバランサー・パブリックIPを含む) も連動して自動削除されます。
> このリソースグループを手動で個別に削除する必要はなく、また直接削除しようとしても
> Azure側で保護されているため通常は失敗します。詳細は `docs/architecture.md` の
> 「自動生成される管理用リソースグループ」を参照してください。

```powershell
# 1. Container App本体
az containerapp delete --name mcaca-dev-minecraft --resource-group rg-minecraft-dev --yes

# 2. Container Apps Environment (自動生成された ME_... リソースグループも連動して削除される)
az containerapp env delete --name mcaca-dev-cae --resource-group rg-minecraft-dev --yes

# 3. Storage Account (5-1でロック解除済みであること。storageAccountNameは
#    `az resource list --resource-group rg-minecraft-dev --resource-type Microsoft.Storage/storageAccounts -o table` で確認できます)
az storage account delete --name <storageAccountName> --resource-group rg-minecraft-dev --yes

# 4. 仮想ネットワーク
az network vnet delete --name mcaca-dev-vnet --resource-group rg-minecraft-dev

# 5. Log Analytics workspace
az monitor log-analytics workspace delete --resource-group rg-minecraft-dev --workspace-name mcaca-dev-law --yes --force true
```
