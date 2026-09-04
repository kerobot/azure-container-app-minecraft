// container-app-environment.bicep
// VNet統合されたContainer Apps (Consumption) 環境を作成し、Azure Files (NFS 4.1) を
// マウント用ストレージとして登録し、Log Analyticsへログを送信します。
// NFSマウントはVNet統合された環境でのみ利用でき、アカウントキーを必要としません。

@description('リソースの共通名プレフィックス')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('Container Apps Environmentのインフラサブネットのリソースid')
param infraSubnetId string

@description('Log Analytics workspace名 (同一リソースグループ内に存在すること)')
param logAnalyticsWorkspaceName string

@description('NFSマウント先のサーバーアドレス (<account>.file.core.windows.net)')
param nfsServer string

@description('NFS共有パス (/<account>/<share> 形式)')
param nfsShareName string

@description('Container Apps Environmentへ登録するAzure Filesストレージ定義名')
param storageDefinitionName string = 'minecraft-data'

@description('共通タグ')
param tags object = {}

// ログ共有キーはBicep出力へ含めず、このモジュール内でのみ既存リソース参照から取得して利用する。
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: logAnalyticsWorkspaceName
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

resource nfsAzureFilesStorage 'Microsoft.App/managedEnvironments/storages@2026-01-01' = {
  parent: managedEnvironment
  name: storageDefinitionName
  properties: {
    nfsAzureFile: {
      server: nfsServer
      shareName: nfsShareName
      accessMode: 'ReadWrite'
    }
  }
}

@description('Container Apps Environmentのリソースid')
output environmentId string = managedEnvironment.id

@description('Container Apps Environment名')
output environmentName string = managedEnvironment.name

@description('マウント用ストレージ定義名')
output storageDefinitionName string = nfsAzureFilesStorage.name

@description('Container Apps Environmentの静的IP')
output staticIp string = managedEnvironment.properties.staticIp
