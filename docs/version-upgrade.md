# バージョンアップグレード手順 (Version Upgrade)

## 基本方針

- 開発環境 (`dev`) は `minecraftVersion=LATEST` を既定とし、最新版へ追従します。
- 本番環境 (`prod`) は意図しない自動更新を避けるため、必ず具体的なバージョン
  (例: `1.20.4`) を `infra/environments/prod.bicepparam` に固定してください。
- Minecraftのバージョンアップはワールドデータの互換性に影響するため、
  **必ず事前バックアップを取得**してから実施します。

## 手順 (GitHub Actions経由、推奨)

1. Actionsタブから `Update Minecraft Version` workflowを選択
2. `environment` (dev/prod) と `minecraftVersion` (更新後バージョン) を入力して実行
3. workflowは以下を自動的に実施します。
   1. 実行中レプリカがあれば `save-all flush` 実行
   2. `pre-update-<タイムスタンプ>` ラベルでバックアップ作成
   3. Bicepデプロイで `minecraftVersion` パラメーターを上書き
   4. リビジョンの再起動

バックアップまたは必須設定の検証に失敗した場合、workflowはバージョン更新を中止します。

`prod` 環境の場合、GitHub Environmentの承認ルールに従い、実行前に承認者の承認が必要です。

## 手順 (手動)

```powershell
# 1. バックアップ
./scripts/backup-world.ps1 -ResourceGroupName rg-minecraft-prod -AppName mcaca-prod-minecraft -Label "pre-update-1.20.5"

# 2. サーバー停止 (推奨: バージョン更新中の接続を避ける)
./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-prod -AppName mcaca-prod-minecraft

# 3. Bicepデプロイでバージョンを更新
az deployment group create `
  --resource-group rg-minecraft-prod `
  --template-file infra/main.bicep `
  --parameters infra/environments/prod.bicepparam `
  --parameters minecraftVersion=1.20.5 rconPassword='<SECRET>'

# 4. サーバー起動して動作確認
./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-prod -AppName mcaca-prod-minecraft
```

上記の `mcaca-prod-minecraft` は既定の `namePrefix` を使った場合の例です。
`namePrefix` を変更している場合は、実際のContainer App名に置き換えてください。

## ロールバック手順

新バージョンで問題が発生した場合、以下の手順でロールバックします。

1. サーバーを停止する
2. `minecraftVersion` を旧バージョンに戻してBicep再デプロイする
3. `pre-update-<タイムスタンプ>` バックアップから `restore-world.ps1` でワールドを復元する
   (新バージョンでワールドフォーマットが変換されている可能性があるため、
   旧バージョンに戻す場合は復元が必須です)
4. サーバーを起動し、動作確認する

## Minecraft本体以外の考慮事項

- itzgイメージの `TYPE` (VANILLA/PAPER/FORGE等) を変更する場合は、
  MODやプラグインの互換性を個別に確認してください。
- ワールドのMinecraftバージョンをダウングレードすることは公式にサポートされていないため、
  ダウングレードが必要な場合は必ずバックアップからの復元で対応してください。
