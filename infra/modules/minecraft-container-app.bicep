// minecraft-container-app.bicep
// itzg/minecraft-server を実行するContainer Appを作成します。
// 通常時はminReplicas=0でスケールインし、TCP接続をトリガーに起動します。
// activeRevisionsModeはSingleとし、常に単一リビジョンのみが稼働するようにします。

@description('リソースの共通名プレフィックス')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('Container Apps EnvironmentのリソースID')
param environmentId string

@description('Container Apps Environmentに登録済みのAzure Filesストレージ定義名')
param storageDefinitionName string

@description('itzg/minecraft-serverのコンテナーイメージ')
param containerImage string = 'itzg/minecraft-server:latest'

@description('Minecraftのバージョン (例: 1.20.4, LATEST)。本番では固定バージョンを指定すること')
param minecraftVersion string = 'LATEST'

@description('ホワイトリストに登録するMinecraftユーザー名またはUUIDのカンマ区切りリスト')
param whitelistUsers string

@description('ホワイトリストを有効にするか (要件により既定でtrue)')
param enableWhitelist bool = true

@description('ONLINE_MODEを有効にするか (要件により既定でtrue)')
param onlineMode bool = true

@description('サーバー管理者(op)として登録するMinecraftユーザー名またはUUIDのカンマ区切りリスト')
param opUsers string = ''

@description('コンテナーに割り当てるCPUコア数 (0.25刻み)')
param cpuCores string = '1.0'

@description('コンテナーに割り当てるメモリ (Gi単位)')
param memorySize string = '2Gi'

@description('JVMの最大ヒープサイズ (itzg MAX_MEMORY環境変数, 例: 1536M)')
param javaMaxMemory string = '1536M'

@description('JVMの初期ヒープサイズ (itzg INIT_MEMORY環境変数, 例: 1024M)')
param javaInitMemory string = '1024M'

@description('最小レプリカ数。通常時は0にしてスケールインする')
@minValue(0)
@maxValue(1)
param minReplicas int = 0

@description('最大レプリカ数。同時に複数のワールドインスタンスが起動しないよう1に固定する')
@minValue(1)
@maxValue(1)
param maxReplicas int = 1

@description('TCPスケールルールの同時接続数しきい値')
param tcpConcurrentConnections int = 1

@description('共通タグ')
param tags object = {}

var minecraftEnv = concat(
  [
    {
      name: 'EULA'
      value: 'TRUE'
    }
    {
      name: 'VERSION'
      value: minecraftVersion
    }
    {
      name: 'TYPE'
      value: 'VANILLA'
    }
    {
      name: 'ONLINE_MODE'
      value: onlineMode ? 'TRUE' : 'FALSE'
    }
    {
      name: 'ENABLE_WHITELIST'
      value: enableWhitelist ? 'TRUE' : 'FALSE'
    }
    {
      name: 'WHITELIST'
      value: whitelistUsers
    }
    {
      name: 'ENFORCE_WHITELIST'
      value: enableWhitelist ? 'TRUE' : 'FALSE'
    }
    {
      name: 'MAX_MEMORY'
      value: javaMaxMemory
    }
    {
      name: 'INIT_MEMORY'
      value: javaInitMemory
    }
    {
      name: 'ENABLE_RCON'
      value: 'TRUE'
    }
    {
      name: 'RCON_PASSWORD'
      secretRef: 'rcon-password'
    }
    {
      name: 'STOP_SERVER_ANNOUNCE_DELAY'
      value: '60'
    }
  ],
  empty(opUsers)
    ? []
    : [
        {
          name: 'OPS'
          value: opUsers
        }
      ]
)

@description('RCON接続用パスワード。RCONは外部公開せず、コンテナー内部/管理操作専用として利用する')
@secure()
param rconPassword string

resource minecraftApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${namePrefix}-minecraft'
  location: location
  tags: tags
  properties: {
    environmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        {
          name: 'rcon-password'
          value: rconPassword
        }
      ]
      ingress: {
        external: true
        transport: 'tcp'
        exposedPort: 25565
        targetPort: 25565
        // RCON(25575)は additionalPortMappings に含めないことで外部非公開とする。
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'minecraft'
          image: containerImage
          resources: {
            cpu: json(cpuCores)
            memory: memorySize
          }
          env: minecraftEnv
          volumeMounts: [
            {
              volumeName: 'minecraft-data'
              mountPath: '/data'
            }
          ]
          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: 25565
              }
              initialDelaySeconds: 60
              periodSeconds: 30
              failureThreshold: 10
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'minecraft-data'
          storageType: 'AzureFile'
          storageName: storageDefinitionName
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'tcp-scale-rule'
            tcp: {
              metadata: {
                concurrentConnections: string(tcpConcurrentConnections)
              }
            }
          }
        ]
      }
    }
  }
}

@description('Container Appのリソースid')
output containerAppId string = minecraftApp.id

@description('Container App名')
output containerAppName string = minecraftApp.name

@description('MinecraftサーバーへのFQDN (ポート25565で接続)')
output fqdn string = minecraftApp.properties.configuration.ingress.fqdn
