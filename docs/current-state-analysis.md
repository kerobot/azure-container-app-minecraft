# 現状分析 (Current State Analysis)

## 目的

本ドキュメントは、ベースリポジトリ (`katakura/azure-container-app-minecraft`) の構成を分析し、
本リポジトリ (`kerobot/azure-container-app-minecraft`) で新規に構築するIaCの前提を整理するものです。

## 調査結果のサマリー

本リポジトリのクローン取得時点では、リポジトリには `README.md` (タイトルのみ) しか存在せず、
IaCコード・ワークフロー・ドキュメントは未実装でした。また、参照元として指定された
`katakura/azure-container-app-minecraft` は本タスク実行環境のネットワーク制限により
アクセスできず、内容を直接検証することができませんでした。

そのため本実装は、問題文に明記された必須要件・Azure Container Apps/Bicep/
itzg-minecraft-serverの現行仕様(2024年時点のAPIバージョン)に基づき、
**ゼロベースでの新規構築**として計画・実装しました。

## 現在のリソース構成 (実装前)

| 項目 | 状態 |
|---|---|
| IaC (Bicep/ARM/Terraform等) | なし |
| GitHub Actions workflow | なし |
| 運用スクリプト | なし |
| ドキュメント | README.mdのタイトルのみ |

## 採用したAzure APIバージョン

新規実装にあたり、2024年時点で一般提供(GA)されている以下のAPIバージョンを採用しました。

| リソース種別 | APIバージョン |
|---|---|
| `Microsoft.App/managedEnvironments` | `2024-03-01` |
| `Microsoft.App/managedEnvironments/storages` | `2024-03-01` |
| `Microsoft.App/containerApps` | `2024-03-01` |
| `Microsoft.Network/virtualNetworks` | `2023-11-01` |
| `Microsoft.Storage/storageAccounts` | `2023-01-01` |
| `Microsoft.OperationalInsights/workspaces` | `2023-09-01` |
| `Microsoft.Insights/diagnosticSettings` | `2021-05-01-preview` (GA相当の安定版が存在しないため、広く利用されているpreview版を採用) |
| `Microsoft.Authorization/locks` | `2020-05-01` |

## 現行Azure仕様との差分・非推奨/更新が必要な箇所

ベースリポジトリの内容を直接確認できなかったため一般的に古い実装との差分になりがちな点を
以下に列挙し、本実装ではすべて現行仕様に合わせています。

- **Container Apps EnvironmentのVNet統合**: 旧仕様では `Microsoft.Web/kubeEnvironments` を
  利用する構成が存在しましたが、現行は `Microsoft.App/managedEnvironments` を使用します。
  本実装ではこちらを採用済みです。
- **Consumption専用環境**: 2023年以降、Workload Profiles対応の環境が既定になりつつありますが、
  Consumptionのみで完結する構成も引き続きサポートされています。要件に明記の通り
  Consumption環境のみを利用し、追加のWorkload Profileは定義していません。
- **TCPイングレス**: Container AppsのTCPイングレス(`transport: tcp`, `exposedPort`)は
  比較的新しい機能のため、古い実装では未対応の場合があります。本実装ではこれを利用し、
  Minecraft Java Edition用のTCP 25565を外部公開しています。
- **`activeRevisionsMode`**: 既定値は `Multiple` です。要件に従い明示的に `Single` を設定しています。
- **Azure Filesのライフサイクル**: 古いテンプレートでは `complete` モードでのデプロイや、
  ストレージアカウントをメインテンプレート内で `dependsOn` 経由の再作成対象にしてしまい、
  再デプロイ時にデータが失われるリスクがある実装が見られます。本実装では
  `Incremental` デプロイを前提とし、削除防止ロック (`Microsoft.Authorization/locks`) を
  付与することでこのリスクを低減しています。

## セキュリティ上の改善点

- Storage Accountの `allowBlobPublicAccess` を `false` に設定し、`networkAcls` で
  既定拒否 + 許可サブネットのみアクセス可能とする構成にしています。
- RCON (デフォルト25575番ポート) はContainer AppsのIngress設定に含めず、外部非公開としています。
  運用操作(ワールド保存等)は `az containerapp exec` を用いてコンテナー内部からのみ実行します。
- GitHub ActionsはOIDC (`azure/login@v2` の `client-id`/`tenant-id`/`subscription-id`) を用い、
  長期間有効なクライアントシークレットを利用しない構成としています。
- Bicepの出力 (`outputs`) にはストレージアカウントキーやRCONパスワードなどの機密情報を
  一切含めていません。ストレージアカウントキーはモジュール内部でのみ `listKeys()` を用いて
  取得し、Container Apps Environmentのストレージ定義へ直接渡しています。

## 移行時の互換性リスク

- **VMベースのMinecraftサーバーからの移行**を想定する場合、ワールドデータのフォーマットは
  Minecraftのバージョン間で互換性がある一方、`server.properties` やプラグイン(該当する場合)の
  設定内容は手動で確認・移植する必要があります。詳細は `docs/migration-from-vm.md` を参照してください。
- **既存のホワイトリスト/opsファイル**をそのまま利用する場合、UUIDベースの記法である必要が
  あるため、旧サーバーのファイルをAzure Filesへそのままコピーすることで概ね移行可能と
  判断しました(破壊的変更なし)。
- ベースリポジトリの詳細な実装内容(リソース名規則、既存のパラメーター名など)を検証できな
  かったため、既存デプロイ済みリソースがある場合は、リソース名の衝突を避けるために
  `namePrefix` パラメーターを環境ごとに調整する必要があります。**TODO**: ベースリポジトリへの
  アクセスが可能になった時点で、命名規則やパラメーター名の整合性を再確認してください。

## 判断が難しかった点 (TODOとして記録)

- **RCONの利用要否**: 要件では「RCONは外部公開しない」とのみ指定されており、RCON自体の
  有効/無効は明記されていません。本実装ではバックアップ・停止処理での `save-all flush` 実行に
  必要なため、RCONを有効化した上で外部非公開としています。TODO: 運用上RCONが不要と判断できる
  場合は `ENABLE_RCON=FALSE` に変更してください。
- **Minecraftのバージョン確認方法**: `VERSION=LATEST` は開発環境で最新版追従を優先する設計判断
  です。本番では明示バージョン固定を必須運用としてください(`docs/version-upgrade.md` 参照)。
- **コールドスタートの実測値**: 本タスクの実行環境からは実際のAzureサブスクリプションへ
  デプロイして計測することができなかったため、`docs/troubleshooting.md` の
  「コールドスタート検証」章には計測手順と想定値の目安のみを記載し、実測値は
  実運用環境での検証後に追記することをTODOとしています。
