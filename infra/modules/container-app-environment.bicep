// container-app-environment.bicep
// VNet統合されたContainer Apps (Consumption) 環境を作成し、Azure Filesを
// マウント用ストレージとして登録し、Log Analyticsへログを送信します。

@description('リソースの共通名プレフィックス')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('Container Apps Environmentのインフラサブネットのリソースid')
param infraSubnetId string

@description('Log Analytics workspace名 (同一リソースグループ内に存在すること)')
param logAnalyticsWorkspaceName string

@description('Azure Filesをマウントするためのストレージアカウント名 (同一リソースグループ内に存在すること)')
param storageAccountName string

@description('Azure Filesの共有名')
param fileShareName string

@description('Container Apps Environmentへ登録するAzure Filesストレージ定義名')
param storageDefinitionName string = 'minecraft-data'

@description('共通タグ')
param tags object = {}

// ログ共有キー・ストレージアクセスキーはBicep出力へ含めず、
// このモジュール内でのみ既存リソース参照から取得して利用する。
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
  name: storageAccountName
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2026-01-01' = {
  name: '${namePrefix}-cae'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infraSubnetId
      internal: false
    }
    zoneRedundant: false
  }
}

resource azureFilesStorage 'Microsoft.App/managedEnvironments/storages@2026-01-01' = {
  parent: managedEnvironment
  name: storageDefinitionName
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShareName
      accessMode: 'ReadWrite'
    }
  }
}

@description('Container Apps Environmentのリソースid')
output environmentId string = managedEnvironment.id

@description('Container Apps Environment名')
output environmentName string = managedEnvironment.name

@description('マウント用ストレージ定義名')
output storageDefinitionName string = azureFilesStorage.name

@description('Container Apps Environmentの静的IP')
output staticIp string = managedEnvironment.properties.staticIp
