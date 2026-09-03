// network.bicep
// Container Apps 環境をVNet統合するための仮想ネットワークとサブネットを作成します。
// Consumption専用環境では、Container Apps用サブネットにサブネット委任は不要ですが、
// Container Apps Environmentへインフラサブネットとして割り当てるために十分なアドレス空間を確保します。

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

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
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
          // Container Apps Environment (Workload Profiles/Consumption) が
          // このサブネットを専有できるように、他ワークロードとの共有は行わない。
          delegations: []
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
