# VMからの移行手順 (Migration from VM)

既存のVM (Azure VM や自宅サーバー等) で稼働しているMinecraft Java Editionサーバーから、
本リポジトリのAzure Container Apps構成へ移行する手順です。

## 移行前チェックリスト

- [ ] 移行元サーバーのMinecraftバージョンを確認する
- [ ] 移行先 (`infra/environments/<env>.bicepparam` の `minecraftVersion`) を
      同一バージョンに固定する (バージョン不一致による自動アップグレードを避けるため)
- [ ] 移行元の `whitelist.json` / `ops.json` の内容を確認する
- [ ] 移行元でMOD/プラグインを使用している場合、itzgイメージの `TYPE` を
      対応する種別 (PAPER/FORGE/FABRIC等) に変更する必要がないか確認する
      (本実装の既定は `VANILLA`)
- [ ] 移行元サーバーを安全に停止し、ワールドデータの書き込みが完了していることを確認する

## 移行手順

### 1. Azure Container Apps環境をデプロイする (レプリカ0のまま)

`docs/deployment.md` に従い、移行先環境をデプロイします。この時点ではまだ
Minecraftを起動しません(`minReplicas=0` のまま)。

### 2. 移行元のワールドデータをアーカイブする

移行元サーバーで以下を実行します。移行元サーバーのOS/シェル (Linuxのbash等) に応じた
コマンドになるため、下記は一例です。サーバーを停止してから実行することを推奨します
(整合性確保のため)。

```sh
tar -czf migration.tar.gz world world_nether world_the_end whitelist.json ops.json server.properties
```

### 3. サーバーを一時的に起動してデータをアップロードする

```powershell
./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-prod -AppName mcaca-prod-minecraft
```

ファイル共有はNFS 4.1で構成されており、AzCopy / Azure Storage Explorer / `az storage file`
といったREST API経由のアクセスは利用できません (アカウントキーによるアクセスも無効です)。
データの持ち込みは、起動中のコンテナー経由で行います。

- **`az containerapp exec` + curl**: Blob StorageのSASリンク等から
  `migration.tar.gz` をコンテナー内へダウンロードし、`/data` 配下に展開する。

```powershell
# 例: 実行中のレプリカ内でアーカイブを取得する
$replica = az containerapp replica list --name mcaca-prod-minecraft --resource-group rg-minecraft-prod `
  --query "[?properties.runningState=='Running'].name | [0]" -o tsv
az containerapp exec --name mcaca-prod-minecraft --resource-group rg-minecraft-prod --replica $replica `
  --command "sh -c 'curl -fsSL \"<BLOB_SAS_URL>\" -o /data/migration.tar.gz'"
```

> 補足: Storage Accountの `networkAcls` はVNet統合されたサブネットからのみアクセスを
> 許可する設定です。NFS共有は同一VNet内のクライアントからのみマウントできるため、
> ローカル端末から直接マウントすることはできません。

### 4. コンテナー内でアーカイブを展開する

```powershell
./scripts/restore-world.ps1 `
  -ResourceGroupName rg-minecraft-prod `
  -AppName mcaca-prod-minecraft `
  -BackupFileName migration.tar.gz `
  -Force
```

`restore-world.ps1` は `/data/backups/` 配下のファイルを対象とするため、
アップロードしたファイルを `/data/backups/migration.tar.gz` に配置してから実行してください。
復元中はプレイヤーが接続しないように制御してください。

### 5. 動作確認

1. `restore-world.ps1` の整合性確認 (`level.dat` の存在チェック) が成功することを確認する
2. Container Appのリビジョンを再起動する
3. ホワイトリストに登録済みのプレイヤーで接続し、ワールドが正しく読み込まれることを確認する
4. インベントリ・座標・建築物などが移行元と一致していることを目視確認する

### 6. 移行元サーバーの停止

移行先での動作確認が完了したら、移行元のVM/サーバーを停止・削除してください。
問題が発生した場合に備え、移行元のアーカイブ (`migration.tar.gz`) は
一定期間保管しておくことを推奨します。

## 互換性に関する注意事項

- Minecraftのワールドフォーマットはバージョン間で前方互換性がありますが、
  ダウングレードはサポートされていません。移行先のバージョンは移行元と同じか、
  それ以降のバージョンを指定してください。
- 座標系・チャンクフォーマットはMinecraftバージョンに依存するため、
  移行前後で必ずバックアップを保持し、問題があれば移行元データへ即座に
  ロールバックできるようにしてください。
- MOD/プラグインを利用していた場合、Container Apps環境でも同等のMOD/プラグインを
  導入する必要があります。itzgイメージの `TYPE`/`MODS`/`PLUGINS` 環境変数を
  用途に応じて追加設定してください(本実装では未設定のため、必要に応じて
  `minecraft-container-app.bicep` の環境変数定義を拡張してください)。
