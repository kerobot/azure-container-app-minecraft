// log-analytics.bicep
// Container Apps Environment向けのログ集約先となるLog Analytics workspaceを作成します。

@description('リソースの共通名プレフィックス')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('ログ保持日数')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('価格レベル (SKU)')
param sku string = 'PerGB2018'

@description('共通タグ')
param tags object = {}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      disableLocalAuth: false
    }
  }
}

@description('Log Analytics workspaceのリソースID')
output workspaceId string = logAnalyticsWorkspace.id

@description('Log Analytics workspaceのカスタマーID (GUID)')
output customerId string = logAnalyticsWorkspace.properties.customerId

@description('Log Analytics workspace名')
output workspaceName string = logAnalyticsWorkspace.name
