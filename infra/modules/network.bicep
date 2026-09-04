// network.bicep
// Container Apps 環境をVNet統合するための仮想ネットワークとサブネットを作成します。
// Container Apps Environment用サブネットは 'Microsoft.App/environments' への
// サブネット委任が必須です。

@description('リソースの共通名プレフィックス')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('仮想ネットワークのアドレス空間')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('Container Apps Environment用インフラサブネットのアドレス空間')
param infraSubnetAddressPrefix string = '10.100.0.0/23'

@description('共通タグ')
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'infra-subnet'
        properties: {
          addressPrefix: infraSubnetAddressPrefix
          // Container Apps Environment (VNet統合) はサブネットが
          // 'Microsoft.App/environments' に委任されていることを必須とする。
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          // Storage Accountへのアクセスをこのサブネットからのみ許可するため、
          // サービスエンドポイントを有効化する。
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
    ]
  }
}

@description('Container Apps Environmentへ渡すインフラサブネットのリソースID')
output infraSubnetId string = vnet.properties.subnets[0].id

@description('仮想ネットワークのリソースID')
output vnetId string = vnet.id

@description('仮想ネットワーク名')
output vnetName string = vnet.name
