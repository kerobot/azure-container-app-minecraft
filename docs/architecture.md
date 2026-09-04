# アーキテクチャ (Architecture)

## 概要

少人数で利用するMinecraft Java Editionサーバーを、Azure Container Apps (Consumption)上に
構築します。通常時はレプリカ数0でスケールインし、利用時のみサーバーを起動することで
コストを抑制します。ワールドデータ等はAzure Filesに永続化し、サーバーの起動・停止・
再デプロイに関わらずデータが保持されます。

## 構成図 (論理構成)

```text
                        ┌─────────────────────────────────────────────┐
                        │         Resource Group (dev/prod)           │
                        │                                             │
  Minecraft Client      │  ┌─────────────────┐     ┌────────────────┐ │
   (Java Edition) ──────┼▶│ Container Apps  │───▶│ Log Analytics  │ │
   TCP 25565            │  │ Environment     │     │ Workspace      │ │
                        │  │ (VNet統合)      │     └────────────────┘ │
                        │  │                 │                        │
                        │  │ ┌─────────────┐ │     ┌────────────────┐ │
                        │  │ │Minecraft    │ │───▶│ Storage Account│ │
                        │  │ │ Container   │ │     │ (Azure Files)  │ │
                        │  │ │ App         │ │     │ /data          │ │
                        │  │ │(min=0,max=1)│ │     └────────────────┘ │
                        │  │ └─────────────┘ │                        │
                        │  └────────┬────────┘                        │
                        │           │ Infra Subnet                    │
                        │  ┌────────▼────────┐                        │
                        │  │ Virtual Network │                        │
                        │  └─────────────────┘                        │
                        └─────────────────────────────────────────────┘
```

## 主要コンポーネント

| コンポーネント | 役割 | Bicepモジュール |
| --- | --- | --- |
| Virtual Network | Container Apps EnvironmentのVNet統合先。Storage Accountへのサービスエンドポイントも提供 | `network.bicep` |
| Log Analytics Workspace | Container Apps Environment/Container Appのログ・メトリクス集約先 | `log-analytics.bicep` |
| Storage Account + Azure Files (NFS 4.1) | ワールド・設定・ホワイトリスト・operator情報の永続化領域 (`/data`) | `storage.bicep` |
| Container Apps Environment (Consumption) | VNet統合済みのConsumption専用環境。NFSストレージ定義を登録 | `container-app-environment.bicep` |
| Container App (Minecraft) | itzg/minecraft-server を実行。TCP 25565を外部公開し、scale-to-zero対応 | `minecraft-container-app.bicep` |
| 診断設定 | Environment/Container AppのログをLog Analyticsへ送信 | `monitoring.bicep` |

### ストレージにNFSを使う理由

Minecraftサーバーはワールドディレクトリの `session.lock` を `O_SYNC` 付きで開いて書き込み、
バイトレンジロックを取得します。Azure Filesを**SMB(cifs)でマウントするとこの書き込みが
`java.io.IOException: Permission denied` となり、サーバーが起動できません**。
`mountOptions` で `uid` / `gid` / `nobrl` を調整しても解決しません。

そのため、POSIXセマンティクスを満たす **NFS 4.1** でマウントしています。これに伴い以下の制約があります。

- Storage Accountは **Premium FileStorage (`Premium_LRS`)** が必須 (共有の最小容量は100GiB)
- Container Apps EnvironmentはVNet統合必須。Storage Accountはそのサブネットからのみアクセスを許可
- Container AppsはNFSの転送時暗号化に非対応のため、`supportsHttpsTrafficOnly` を `false` にする必要がある
- NFSはアカウントキーを使わないため `allowSharedKeyAccess` は `false`
- 共有はREST API (AzCopy / Azure Storage Explorer / `az storage file`) から操作できない。
  ファイルの出し入れは `az containerapp exec` でコンテナー経由で行う

> 既存のSMBストレージ定義 (`Microsoft.App/managedEnvironments/storages`) は `storageType` を
> 後から変更できません。SMBで構築済みの環境をNFSへ移行する場合は、Container Appの
> ボリューム参照を外して旧定義を削除するか、`storageDefinitionName` を別名へ変更してください。
> またStorage Accountは `kind` を `StorageV2` から `FileStorage` へ変更できないため、作り直しが必要です。

## スケーリング設計

- `activeRevisionsMode: Single` — 常に1つのリビジョンのみが稼働。世代管理をシンプルに保つ。
- `scale.minReplicas: 0` / `scale.maxReplicas: 1` — 通常時は課金なし。同時に複数インスタンスが
  起動してワールドデータが競合しないよう、最大1に固定。
- TCPスケールルール (`tcp.metadata.concurrentConnections`) — TCP 25565への接続を検知して
  レプリカを0→1へスケールアウトする。
- `scale.cooldownPeriod` (`scaleCooldownSeconds`) — すべての接続が途絶えてからスケールインするまでの待機時間。
- `terminationGracePeriodSeconds` — 停止シグナルからSIGKILLまでの猶予。ワールド保存を完了させるために確保する。

### 単一インスタンス制約と「minReplicasを変更しない」運用

Minecraftはワールドディレクトリを `session.lock` で**排他ロック**します。同じワールドを
2つのサーバープロセスが同時に開くことはできず、後から起動した方は
`DirectoryLock$LockException: already locked` で失敗します。

一方Container Appsは、`activeRevisionsMode: Single` であっても**新リビジョンがReadyになってから
旧リビジョンを落とす**ローリング方式で切り替えます。つまり新旧が一時的に重なります。

`az containerapp update --min-replicas` はテンプレート変更にあたるため、**実行のたびに
新しいリビジョンが生成されます**。旧リビジョンにレプリカが残っている状態でこれを実行すると、

1. 新リビジョンが起動 → `session.lock` は旧が保持中 → 起動失敗 (CrashLoopBackOff)
2. 新リビジョンは永久にReadyにならない → 旧リビジョンも落ちない
3. `latestRevisionName` != `latestReadyRevisionName` のまま**デッドロック**

という状態に陥ります。これを避けるため、本実装では次の方針を採ります。

- `minReplicas` は**常に0のまま**運用する (`dev` / `prod` いずれの `.bicepparam` も0固定)
- 起動は `scripts/start-server.ps1` がTCP接続を張ってスケールルールを誘発する
  (テンプレートを変更しないため、新しいリビジョンは生成されない)
- 停止は `scripts/stop-server.ps1` がワールドを保存し、`cooldownPeriod` 経過後の
  自動スケールインを待つ
- デプロイ (`scripts/deploy.ps1` / `deploy-*.yml`) は**実行前にサーバーが停止していることを確認**する

運用スクリプトは `latestReadyRevisionName` を明示して `az containerapp replica list` を呼び出します
(`scripts/lib/containerapp.ps1`)。省略すると最新リビジョンを見てしまい、上記のデッドロック時に
稼働中のレプリカを見失うためです。

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
