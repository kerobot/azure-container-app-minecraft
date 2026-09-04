# アーキテクチャ (Architecture)

## 概要

少人数で利用するMinecraft Java Editionサーバーを、Azure Container Apps (Consumption)上に
構築します。通常時はレプリカ数0でスケールインし、利用時のみサーバーを起動することで
コストを抑制します。ワールドデータ等はAzure Filesに永続化し、サーバーの起動・停止・
再デプロイに関わらずデータが保持されます。

## 構成図 (論理構成)

```text
                        ┌─────────────────────────────────────────┐
                        │         Resource Group (dev/prod)        │
                        │                                           │
  Minecraft Client      │  ┌───────────────┐     ┌───────────────┐ │
   (Java Edition) ──────┼─▶│ Container Apps │────▶│ Log Analytics │ │
   TCP 25565            │  │ Environment    │     │ Workspace     │ │
                        │  │ (VNet統合)      │     └───────────────┘ │
                        │  │                │                       │
                        │  │ ┌───────────┐  │     ┌───────────────┐ │
                        │  │ │Minecraft  │  │────▶│ Storage Account│ │
                        │  │ │ Container │  │     │ (Azure Files)  │ │
                        │  │ │ App       │  │     │ /data          │ │
                        │  │ │(min=0,max=1)│  │     └───────────────┘ │
                        │  │ └───────────┘  │                       │
                        │  └───────┬───────┘                       │
                        │          │ Infra Subnet                  │
                        │  ┌───────▼───────┐                       │
                        │  │ Virtual Network│                       │
                        │  └────────────────┘                       │
                        └─────────────────────────────────────────┘
```

## 主要コンポーネント

| コンポーネント | 役割 | Bicepモジュール |
| --- | --- | --- |
| Virtual Network | Container Apps EnvironmentのVNet統合先。Storage Accountへのサービスエンドポイントも提供 | `network.bicep` |
| Log Analytics Workspace | Container Apps Environment/Container Appのログ・メトリクス集約先 | `log-analytics.bicep` |
| Storage Account + Azure Files | ワールド・設定・ホワイトリスト・operator情報の永続化領域 (`/data`) | `storage.bicep` |
| Container Apps Environment (Consumption) | VNet統合済みのConsumption専用環境。Azure Filesストレージ定義を登録 | `container-app-environment.bicep` |
| Container App (Minecraft) | itzg/minecraft-server を実行。TCP 25565を外部公開し、scale-to-zero対応 | `minecraft-container-app.bicep` |
| 診断設定 | Environment/Container AppのログをLog Analyticsへ送信 | `monitoring.bicep` |

## スケーリング設計

- `activeRevisionsMode: Single` — 常に1つのリビジョンのみが稼働。世代管理をシンプルに保つ。
- `scale.minReplicas: 0` / `scale.maxReplicas: 1` — 通常時は課金なし。同時に複数インスタンスが
  起動してワールドデータが競合しないよう、最大1に固定。
- TCPスケールルール (`tcp.metadata.concurrentConnections`) — TCP 25565への接続を検知して
  レプリカを0→1へスケールアウトする。
- 明示的な起動/停止手段として、GitHub Actions (`start-server.yml` / `stop-server.yml`) や
  PowerShellスクリプト (`scripts/start-server.ps1` / `scripts/stop-server.ps1`) から
  `az containerapp update --min-replicas` を直接操作する経路も用意している
  (TCP自動起動が実用的でない場合の代替手段、詳細は `docs/troubleshooting.md` を参照)。

## ネットワーク設計

- Container Apps EnvironmentはVNet統合(`external`ネットワーク、パブリックIP経由でのTCP公開)。
- Storage AccountはパブリックネットワークアクセスをVNetのサービスエンドポイント経由のみに制限
  (`networkAcls.defaultAction: Deny` + 許可サブネット)。
- RCON(既定25575番ポート)はContainer AppsのIngress設定に含めないため、外部からは
  到達不能。運用操作は `az containerapp exec` でコンテナー内部から実行する。

### 自動生成される管理用リソースグループ (`ME_...`)

Container Apps Environmentを外部公開のVNet統合(`vnetConfiguration.internal: false`)で作成すると、
Azureはロードバランサー (`capp-svc-lb`) とパブリックIP (`capp-svc-lb-ip`) を、デプロイ先とは別の
`ME_<環境名>_<リソースグループ名>_<リージョン>` という命名のリソースグループへ自動的に作成する。
これはAKSのノードリソースグループ (`MC_...`) と同様のAzureプラットフォーム側の仕様であり、
このリポジトリのBicep (`network.bicep` / `container-app-environment.bicep`) が明示的に作成している
ものではない。ユーザー側でこの`ME_...`リソースグループ内のリソースを直接変更・削除しては
ならず、Container Apps Environment (`managedEnvironments`) を削除すれば連動して自動的に
削除される (削除手順は `docs/deployment.md` の「5. 作成したリソースの削除」を参照)。

## セキュリティ設計

詳細は各要件に対応するモジュール/設定を参照してください。

| 要件 | 実装箇所 |
| --- | --- |
| ホワイトリスト必須 | `minecraft-container-app.bicep` の `ENABLE_WHITELIST`/`ENFORCE_WHITELIST` |
| ONLINE_MODE有効 | `minecraft-container-app.bicep` の `ONLINE_MODE` |
| RCON外部非公開 | Ingressに25575番を含めない設計 |
| Storage公開アクセス制限 | `storage.bicep` の `networkAcls`/`allowBlobPublicAccess` |
| OIDC認証 | 各workflowの `azure/login@v2` (client-id/tenant-id/subscription-id) |
| 秘密情報を出力しない | 各moduleの`outputs`にキー・パスワードを含めない設計 |
| 最小権限RBAC | `docs/deployment.md` のOIDC用サービスプリンシパル権限設定を参照 |
