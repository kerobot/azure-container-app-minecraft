// storage.bicep
// ワールドデータ・設定・ホワイトリスト・operator情報を永続化するためのAzure Files共有を作成します。
// リソースの再デプロイ (increment mode) ではストレージアカウント・ファイル共有は削除されず、
// 既存データはそのまま維持されます。誤操作による削除を防ぐため、CanNotDeleteロックを付与します。

@description('リソースの共通名プレフィックス (英数字のみ、storage account名の生成に利用)')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('Minecraftデータ用ファイル共有名')
param fileShareName string = 'minecraft-data'

@description('ファイル共有の割り当て容量(GiB)')
@minValue(1)
@maxValue(102400)
param fileShareQuotaGiB int = 64

@description('Storage Accountへのアクセスを許可するサブネットのリソースID')
param allowedSubnetId string

@description('ストレージアカウントの再デプロイ時に誤って削除されないようリソースロックを付与するか')
param enableDeleteLock bool = true

@description('共通タグ')
param tags object = {}

var storageAccountName = toLower(replace('${namePrefix}stg', '-', ''))
var sanitizedStorageAccountName = length(storageAccountName) > 24 ? substring(storageAccountName, 0, 24) : storageAccountName

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: sanitizedStorageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    // 公開アクセスを制限し、指定サブネットからのアクセスのみを許可する。
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // Azure Files SMB mount requires Storage account key (Container Apps supports azureFile with accountKey only).
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: allowedSubnetId
          action: 'Allow'
        }
      ]
    }
    supportsHttpsTrafficOnly: true
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource minecraftShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileServices
  name: fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

resource deleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: storageAccount
  name: '${sanitizedStorageAccountName}-delete-lock'
  properties: {
    level: 'CanNotDelete'
    notes: 'Minecraftワールドデータ保護のための削除防止ロック。解除するには明示的にロックを削除すること。'
  }
}

@description('ストレージアカウント名')
output storageAccountName string = storageAccount.name

@description('ファイル共有名')
output fileShareName string = minecraftShare.name

@description('ストレージアカウントのリソースID')
output storageAccountId string = storageAccount.id
