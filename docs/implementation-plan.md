# 実装計画 (Implementation Plan)

本ドキュメントは、Issue単位のチェックリストとして実装フェーズを整理したものです。
各フェーズはBicepのコンパイル・静的検証を伴って完了とします。

- [x] **フェーズ1: 現状分析**
  - [x] ベースリポジトリの調査(アクセス制限によりTODO化した点を明記)
  - [x] `docs/current-state-analysis.md` 作成

- [x] **フェーズ2: Bicepモジュール化**
  - [x] `infra/main.bicep` エントリーポイント作成
  - [x] `infra/modules/network.bicep` (VNet/サブネット)
  - [x] `infra/modules/log-analytics.bicep`
  - [x] `infra/modules/storage.bicep` (Storage Account/File Share)
  - [x] `infra/modules/container-app-environment.bicep`
  - [x] `infra/modules/minecraft-container-app.bicep`
  - [x] `infra/modules/monitoring.bicep`
  - [x] `bicep build` / `bicep lint` による静的検証

- [x] **フェーズ3: Minecraft設定**
  - [x] itzg/minecraft-server の環境変数設計 (EULA, VERSION, ONLINE_MODE, WHITELIST, OPS, MAX/INIT_MEMORY)
  - [x] ホワイトリスト・opsのパラメータ化

- [x] **フェーズ4: 永続ストレージ**
  - [x] Azure Files共有 (NFS 4.1 / Premium FileStorage) の作成、Container Apps Environmentへの登録
  - [x] `/data` へのボリュームマウント
  - [x] 削除防止ロックの付与 (再デプロイでデータが削除されないこと)

- [x] **フェーズ5: TCP ingressとscale-to-zero**
  - [x] TCPイングレス(25565番)の外部公開設定
  - [x] `minReplicas=0` / `maxReplicas=1` / TCPスケールルール定義
  - [x] `activeRevisionsMode: Single` の設定

- [x] **フェーズ6: GitHub Actions**
  - [x] `validate-infra.yml` (build/lint/what-if)
  - [x] `deploy-dev.yml`
  - [x] `deploy-prod.yml` (GitHub Environment承認必須)
  - [x] `start-server.yml`
  - [x] `stop-server.yml`
  - [x] `update-minecraft.yml`
  - [x] OIDCによるAzureログイン設定

- [x] **フェーズ7: バックアップと復元**
  - [x] `scripts/backup-world.ps1` (世代管理付き)
  - [x] `scripts/restore-world.ps1` (復元後整合性確認付き)
  - [x] バージョン更新前バックアップの自動化 (`update-minecraft.yml` に組み込み)
  - [x] `docs/backup-restore.md`

- [x] **フェーズ8: VMからの移行手順**
  - [x] `docs/migration-from-vm.md`

- [x] **フェーズ9: テストとドキュメント**
  - [x] 各Bicepモジュールのビルド・lint検証
  - [x] 各bicepparamのbuild-params検証
  - [x] PowerShellスクリプトの構文検証
  - [x] GitHub Actionsワークフローのyaml構文検証
  - [x] ドキュメント一式の作成 (README, architecture, deployment, operations,
        backup-restore, version-upgrade, troubleshooting, migration-from-vm)

## 未解決のTODO (推測により破壊的変更をしなかった項目)

以下は要件から一意に決定できなかったため、安全側の初期値を設定した上でTODOとして記録した項目です。
実運用開始前に、運用者の判断で確定してください。

1. **本番のMinecraftバージョン固定値**: `infra/environments/prod.bicepparam` は
   既定値 `26.2` を仮設定していますが、実際に稼働確認したバージョンへ更新してください。
2. **RCONの有効/無効**: 既定で有効(外部非公開)としています。運用上不要であれば無効化を検討してください。
3. **リソース命名規則 (`namePrefix`)**: ベースリポジトリの既存命名規則を確認できなかったため、
   `mcaca-<env>` という新規プレフィックスを採用しています。既存リソースと合わせる場合は
   `infra/main.bicep` の `namePrefix` 既定値、および `.github/workflows/*.yml` 内の
   `app_name` 組み立てロジックを合わせて変更してください。
4. **コールドスタートの実測値**: 実際のAzure環境での計測が本タスクの環境では実施できな
   かったため、`docs/troubleshooting.md` には計測手順のみを記載しています。実環境検証後に
   実測値を追記してください。
