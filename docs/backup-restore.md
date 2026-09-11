# バックアップと復元 (Backup & Restore)

## バックアップ方針

ワールドデータの整合性を保つため、以下の順序でバックアップを取得します。

1. `/data` 配下の `world` / `world_nether` / `world_the_end` / `whitelist.json` /
   `ops.json` / `server.properties` を tar.gz として `/data/backups/` へアーカイブする

`backup-world.ps1` は `save-all flush` を行いません。GitHub Actionsなどの非対話環境で
`az containerapp exec` を短時間に多用するとレート制限(429)や `rcon-cli` の実行失敗を
招くためです (`docs/incident-records.md` のINC-005を参照)。ワールドの明示的なフラッシュが
必要な場合は、バックアップの前後で `stop-server.ps1` を使ってサーバーを停止してください
(停止処理の中で `save-all flush` を実行します)。

> 注意: ファイル共有はNFS 4.1で構成しているため、`az storage file` や AzCopy などの
> REST API経由の操作は利用できません (アカウントキーアクセスも無効です)。
> バックアップの取得・取り出しはすべて `az containerapp exec` でコンテナー経由で行います。
> この制約の背景は `docs/architecture.md` の「ストレージにNFSを使う理由」を参照してください。

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
./scripts/backup-world.ps1 -ResourceGroupName rg-minecraft-prod -AppName mcaca-prod-minecraft -Label "pre-update-26.2"
```

## 復元手順

1. 復元前に必ずサーバーを停止してください (データ不整合防止)。TCPスケールルールが固着して
   自動スケールインしないことがあるため、`-Force` を付けて確実にレプリカ0にします。

   ```powershell
   ./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force
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
     -BackupFileName "/data/backups/verify-fix-20260905T141543Z.tar.gz" `
     -DryRun   # まず内容を確認

   ./scripts/restore-world.ps1 `
     -ResourceGroupName rg-minecraft-dev `
     -AppName mcaca-dev-minecraft `
       -BackupFileName "/data/backups/verify-fix-20260905T141543Z.tar.gz" `
       -Force    # 起動中レプリカ上での復元リスクを明示的に承認
   ```

   > `-BackupFileName` にはファイル名のみ (`manual-...tar.gz`) と、バックアップ完了時に
   > 表示されるフルパス (`/data/backups/manual-...tar.gz`) のどちらを指定しても構いません。

4. スクリプトは復元後、`/data/world/level.dat` の存在を確認して整合性チェックを行います。
   チェックに失敗した場合はエラー終了し、復元が不完全であることを通知します。

5. 復元完了後、Minecraftプロセスを再起動してディスク上の復元済みワールドを読み込ませてください。

   > **`az containerapp revision restart` は使わないでください。** step2で起動したレプリカが
   > 稼働中のままこのコマンドを実行すると、新しいレプリカがワールドの`session.lock`を取得できず
   > `already locked` で無限にクラッシュし続け、旧レプリカも生き残り続けるデッドロックに陥ります
   > (`docs/troubleshooting.md` の「`revision restart` 実行後にレプリカがデッドロックする」を参照)。

   代わりに、RCON経由でMinecraftプロセスのみを再起動します。コンテナーは同じレプリカ内で
   自動的に再起動し、新しいレプリカの生成やリビジョンの競合を伴いません。

   ```powershell
   # 稼働中のレプリカ名を確認
   az containerapp replica list --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
     --query "[?properties.runningState=='Running'].name" -o tsv

   # RCON経由でMinecraftプロセスを再起動 (同一レプリカ内でコンテナーが自動再起動する)
   az containerapp exec --name mcaca-dev-minecraft --resource-group rg-minecraft-dev `
     --replica <replica-name> --command 'rcon-cli stop'
   ```

   再起動には数十秒〜数分かかります。`./scripts/status-server.ps1` でMinecraftサーバーが
   応答するようになったことを確認してください。

## 復元後の整合性確認

- `restore-world.ps1` は `/data/world/level.dat` の存在確認を自動で行います。
- 加えて、Minecraftサーバー起動後のログ (`docs/operations.md` のログ確認クエリ参照) で
  ワールドロード時のエラーが出力されていないことを確認してください。
- 可能であれば、復元後に一度サーバーへ接続し、地形やインベントリが想定通りであることを
  目視確認してください。
