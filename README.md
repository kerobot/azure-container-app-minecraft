# azure-container-app-minecraft

少人数で利用するMinecraft Java EditionサーバーをAzure Container Apps上に構築するための
Infrastructure as Code (Bicep) と運用一式です。

## 特徴

- **課金抑制**: 通常時は`minReplicas=0`でスケールインし、利用時のみサーバーを起動
- **永続化**: ワールド・設定・ホワイトリスト・operator情報はAzure Filesへ保存し、
  再デプロイやスケールインでもデータは失われません
- **セキュリティ**: ホワイトリスト必須・ONLINE_MODE有効・RCON外部非公開・
  Storage公開アクセス制限・OIDCによるGitHub Actions連携
- **運用自動化**: GitHub Actions / PowerShellスクリプトによる起動・停止・
  バージョン更新・バックアップ/復元

## ディレクトリ構成

```
infra/
  main.bicep                    # エントリーポイント
  modules/
    network.bicep                # VNet/サブネット
    log-analytics.bicep          # Log Analytics workspace
    storage.bicep                # Storage Account / Azure Files
    container-app-environment.bicep # Container Apps Environment (VNet統合)
    minecraft-container-app.bicep   # itzg/minecraft-server Container App
    monitoring.bicep             # 診断設定
  environments/
    dev.bicepparam
    prod.bicepparam

.github/workflows/
  validate-infra.yml             # PRでのbuild/lint/what-if
  deploy-dev.yml
  deploy-prod.yml                # GitHub Environment承認必須
  start-server.yml
  stop-server.yml
  update-minecraft.yml

scripts/                         # PowerShell 7 運用スクリプト
  deploy.ps1
  start-server.ps1
  stop-server.ps1
  status-server.ps1
  backup-world.ps1
  restore-world.ps1

docs/                            # 日本語ドキュメント
  current-state-analysis.md
  implementation-plan.md
  architecture.md
  deployment.md
  operations.md
  backup-restore.md
  version-upgrade.md
  troubleshooting.md
  migration-from-vm.md
```

## クイックスタート

1. [docs/deployment.md](docs/deployment.md) に従い、OIDC用のAzure ADアプリケーション登録と
   GitHub Secrets/Variablesを設定する
2. `infra/environments/dev.bicepparam` を必要に応じて編集する
   (ホワイトリスト、CPU/メモリ、Minecraftバージョン等)
3. `deploy-dev.yml` workflow (または `scripts/deploy.ps1`) でデプロイする
4. `start-server.yml` workflow (または `scripts/start-server.ps1`) でサーバーを起動する
5. ホワイトリストに登録したプレイヤーでMinecraftクライアントから接続する

詳細は各ドキュメントを参照してください。

- [アーキテクチャ](docs/architecture.md)
- [デプロイ手順](docs/deployment.md)
- [運用手順](docs/operations.md)
- [バックアップと復元](docs/backup-restore.md)
- [バージョンアップグレード手順](docs/version-upgrade.md)
- [トラブルシューティング](docs/troubleshooting.md)
- [VMからの移行手順](docs/migration-from-vm.md)
- [現状分析](docs/current-state-analysis.md)
- [実装計画](docs/implementation-plan.md)