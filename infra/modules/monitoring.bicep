// monitoring.bicep
// Container Apps環境・Container Appの診断設定をLog Analyticsへ送信します。

@description('診断設定の対象となるContainer Apps Environment名')
param environmentName string

@description('診断設定の対象となるContainer App名')
param containerAppName string

@description('送信先Log Analytics workspaceのリソースID')
param logAnalyticsWorkspaceId string

resource environmentRef 'Microsoft.App/managedEnvironments@2026-01-01' existing = {
  name: environmentName
}

resource containerAppRef 'Microsoft.App/containerApps@2026-01-01' existing = {
  name: containerAppName
}

resource environmentDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-cae'
  scope: environmentRef
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource containerAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-minecraft-app'
  scope: containerAppRef
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    // Microsoft.App/containerApps はログカテゴリを提供しないため(AllMetricsのみ対応)、
    // コンテナーログは環境スコープの診断設定(environmentDiagnostics)で収集する。
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}
