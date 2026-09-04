// minecraft-container-app.bicep
// itzg/minecraft-server を実行するContainer Appを作成します。
// 通常時はminReplicas=0でスケールインし、TCP接続をトリガーに起動します。
// activeRevisionsModeはSingleとし、常に単一リビジョンのみが稼働するようにします。
//
// Minecraftはワールドを session.lock で排他ロックするため、新旧リビジョンが一瞬でも
// 同時に起動すると DirectoryLock$LockException で新しい方が起動できません。
// そのため minReplicas は常に0のまま運用し、起動はTCPスケールルールに任せます
// (スクリプトから minReplicas を変更すると新しいリビジョンが生成され、この衝突を引き起こします)。

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

@description('Minecraftのバージョン (例: 26.2, LATEST)。本番では固定バージョンを指定すること')
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

@description('最小レプリカ数。リビジョン間のワールド衝突を避けるため0固定で運用すること')
@minValue(0)
@maxValue(1)
param minReplicas int = 0

@description('最大レプリカ数。同時に複数のワールドインスタンスが起動しないよう1に固定する')
@minValue(1)
@maxValue(1)
param maxReplicas int = 1

@description('TCPスケールルールの同時接続数しきい値')
param tcpConcurrentConnections int = 1

@description('接続が途絶えてからスケールインするまでの待機秒数')
@minValue(60)
@maxValue(3600)
param scaleCooldownSeconds int = 120

@description('コンテナー停止時にワールド保存を待つ猶予秒数')
@minValue(30)
@maxValue(600)
param terminationGracePeriodSeconds int = 90

@description('Startupプローブの失敗許容回数。periodSeconds(10秒)との積が起動の許容時間になる')
@minValue(6)
@maxValue(240)
param startupProbeFailureThreshold int = 60

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

resource minecraftApp 'Microsoft.App/containerApps@2026-01-01' = {
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
            // Startup・Readinessも必ず明示する。一部だけ定義すると残りはAzure既定
            // (Startupはperiod 1秒) となり、Minecraftの起動時間に合わない。
            {
              type: 'Startup'
              tcpSocket: {
                port: 25565
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: startupProbeFailureThreshold
            }
            {
              type: 'Readiness'
              tcpSocket: {
                port: 25565
              }
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 6
            }
            {
              type: 'Liveness'
              tcpSocket: {
                port: 25565
              }
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 5
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'minecraft-data'
          storageType: 'NfsAzureFile'
          storageName: storageDefinitionName
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        cooldownPeriod: scaleCooldownSeconds
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
      terminationGracePeriodSeconds: terminationGracePeriodSeconds
    }
  }
}

@description('Container Appのリソースid')
output containerAppId string = minecraftApp.id

@description('Container App名')
output containerAppName string = minecraftApp.name

@description('MinecraftサーバーへのFQDN (ポート25565で接続)')
output fqdn string = minecraftApp.properties.configuration.ingress.fqdn
