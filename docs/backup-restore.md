# バックアップと復元 (Backup & Restore)

## バックアップ方針

ワールドデータの整合性を保つため、以下の順序でバックアップを取得します。

1. `rcon-cli save-all flush` を実行し、メモリ上の変更をディスクへ強制フラッシュする
2. 数秒〜十数秒待機し、ディスクI/Oの完了を待つ
3. `/data` 配下の `world` / `world_nether` / `world_the_end` / `whitelist.json` /
   `ops.json` / `server.properties` を tar.gz として `/data/backups/` へアーカイブする

サーバー稼働中でも `save-all flush` によって概ね安全にバックアップを取得できますが、
より厳密な整合性を求める場合は、サーバー停止中(`stop-server.ps1` 実行後)に
バックアップすることを推奨します。Azure Files snapshotの利用も選択肢ですが、
本実装ではitzg標準機能との親和性を優先し、コンテナー内tar.gzアーカイブ方式を採用しています。
(Azure Files snapshotを利用する場合は、ストレージアカウントのスナップショット機能を
別途有効化し、`az storage share snapshot` 等で共有全体のスナップショットを取得する
運用に切り替えることも可能です。)

## 手動バックアップ

```powershell
# 実行内容の確認のみ (DryRun)
./scripts/backup-world.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Label manual -DryRun

# 実際にバックアップを取得 (直近10世代を保持)
./scripts/backup-world.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Label manual -RetentionCount 10
```

バックアップは `/data/backups/<Label>-<UTCタイムスタンプ>.tar.gz` として保存されます。

## 世代管理

`-RetentionCount` パラメーターで保持世代数を指定できます(既定10世代)。
指定数を超える古いバックアップは自動的に削除されます。`-RetentionCount 0` を指定すると
世代整理を行いません。

## バージョン更新前のバックアップ

`update-minecraft.yml` workflowは、Minecraftバージョンを更新する前に自動的に
`pre-update-<タイムスタンプ>` ラベルでバックアップを取得してから、Bicepデプロイで
`minecraftVersion` パラメーターを更新します。バックアップに失敗した場合、バージョン更新は
中止されます。手動で行う場合は以下の通りです。

```powershell
./scripts/backup-world.ps1 -ResourceGroupName rg-minecraft-prod -AppName mcaca-prod-minecraft -Label "pre-update-1.20.5"
```

## 復元手順

1. 復元前に必ずサーバーを停止してください (データ不整合防止)。

   ```powershell
   ./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
   ```

2. 復元処理には `az containerapp exec` が必要なため、一時的にレプリカを起動します。
   この時点でMinecraftプロセスも起動するため、復元作業中はプレイヤーが接続しないように
   ホワイトリスト/運用連絡で必ず制御してください。

   ```powershell
   ./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
   ```

   > より厳密な復元が必要な場合は、Minecraftプロセスを起動しない専用ジョブまたは一時コンテナーで
   > 同じAzure Filesをマウントして復元する運用を検討してください。

3. バックアップファイル名を指定して復元します。

   ```powershell
   ./scripts/restore-world.ps1 `
     -ResourceGroupName rg-minecraft-dev `
     -AppName mcaca-dev-minecraft `
     -BackupFileName "manual-20240101T120000Z.tar.gz" `
     -DryRun   # まず内容を確認

   ./scripts/restore-world.ps1 `
     -ResourceGroupName rg-minecraft-dev `
     -AppName mcaca-dev-minecraft `
       -BackupFileName "manual-20240101T120000Z.tar.gz" `
       -Force    # 起動中レプリカ上での復元リスクを明示的に承認
   ```

4. スクリプトは復元後、`/data/world/level.dat` の存在を確認して整合性チェックを行います。
   チェックに失敗した場合はエラー終了し、復元が不完全であることを通知します。

5. 復元完了後、Container Appのリビジョンを再起動してMinecraftプロセスへ反映してください。

   ```powershell
   az containerapp revision restart --name mcaca-dev-minecraft --resource-group rg-minecraft-dev --revision <revision-name>
   ```

## 復元後の整合性確認

- `restore-world.ps1` は `/data/world/level.dat` の存在確認を自動で行います。
- 加えて、Minecraftサーバー起動後のログ (`docs/operations.md` のログ確認クエリ参照) で
  ワールドロード時のエラーが出力されていないことを確認してください。
- 可能であれば、復元後に一度サーバーへ接続し、地形やインベントリが想定通りであることを
  目視確認してください。
