targetScope = 'resourceGroup'

// main.bicep
// Azure Container Apps上でscale-to-zero対応のMinecraft Java Editionサーバーを構築する
// エントリーポイント。各リソースはモジュールに分割している。

@description('環境名 (dev / prod)。リソース名の一部として利用する')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('リソースを配置するAzureリージョン')
param location string = resourceGroup().location

@description('リソース名の共通プレフィックス')
param namePrefix string = 'mcaca-${environmentName}'

@description('仮想ネットワークのアドレス空間')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('Container Apps Environment用インフラサブネットのアドレス空間')
param infraSubnetAddressPrefix string = '10.100.0.0/23'

@description('Log Analyticsのログ保持日数')
param logRetentionInDays int = 30

@description('Minecraftデータ用ファイル共有の割り当て容量(GiB)。NFS(Premium FileStorage)のため最小100GiB')
@minValue(100)
param fileShareQuotaGiB int = 100

@description('ストレージアカウントに削除防止ロックを付与するか')
param enableStorageDeleteLock bool = true

@description('itzg/minecraft-serverのコンテナーイメージ')
param containerImage string = 'itzg/minecraft-server:latest'

@description('Minecraftのバージョン (例: 26.2, LATEST)。本番運用では固定バージョンを指定すること')
param minecraftVersion string = 'LATEST'

@description('ホワイトリストに登録するMinecraftユーザー名またはUUIDのカンマ区切りリスト')
param whitelistUsers string

@description('サーバー管理者(op)として登録するMinecraftユーザー名またはUUIDのカンマ区切りリスト')
param opUsers string = ''

@description('ONLINE_MODEを有効にするか')
param onlineMode bool = true

@description('ホワイトリストを有効にするか')
param enableWhitelist bool = true

@description('コンテナーに割り当てるCPUコア数 (0.25刻み)')
param cpuCores string = '1.0'

@description('コンテナーに割り当てるメモリ (Gi単位)')
param memorySize string = '2Gi'

@description('JVMの最大ヒープサイズ')
param javaMaxMemory string = '1536M'

@description('JVMの初期ヒープサイズ')
param javaInitMemory string = '1024M'

@description('通常時の最小レプリカ数。リビジョン間のワールド衝突を避けるため0固定で運用すること')
@minValue(0)
@maxValue(1)
param minReplicas int = 0

@description('最大レプリカ数 (要件によ1固定)')
@minValue(1)
@maxValue(1)
param maxReplicas int = 1

@description('TCPスケールルールの同時接続数しきい値')
param tcpConcurrentConnections int = 1

@description('接続が途絶えてからスケールインするまでの待機秒数')
param scaleCooldownSeconds int = 120

@description('コンテナー停止時にワールド保存を待つ猝予秒数')
param terminationGracePeriodSeconds int = 90

@description('Startupプローブの失敗許容回数。初回ワールド生成に時間がかかる場合は大きくする')
param startupProbeFailureThreshold int = 60

@description('RCON接続用パスワード。GitHub Actions等のCI/CDシークレットから注入し、リポジトリへ平文で保存しないこと')
@secure()
param rconPassword string

@description('共通タグ')
param tags object = {
  project: 'azure-container-app-minecraft'
  environment: environmentName
}

module network 'modules/network.bicep' = {
  name: 'network-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    infraSubnetAddressPrefix: infraSubnetAddressPrefix
    tags: tags
  }
}

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'log-analytics-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    retentionInDays: logRetentionInDays
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    fileShareQuotaGiB: fileShareQuotaGiB
    allowedSubnetId: network.outputs.infraSubnetId
    enableDeleteLock: enableStorageDeleteLock
    tags: tags
  }
}

module containerAppEnvironment 'modules/container-app-environment.bicep' = {
  name: 'container-app-environment-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    infraSubnetId: network.outputs.infraSubnetId
    logAnalyticsWorkspaceName: logAnalytics.outputs.workspaceName
    nfsServer: storage.outputs.nfsServer
    nfsShareName: storage.outputs.nfsShareName
    tags: tags
  }
}

module minecraftContainerApp 'modules/minecraft-container-app.bicep' = {
  name: 'minecraft-container-app-deployment'
  params: {
    namePrefix: namePrefix
    location: location
    environmentId: containerAppEnvironment.outputs.environmentId
    storageDefinitionName: containerAppEnvironment.outputs.storageDefinitionName
    containerImage: containerImage
    minecraftVersion: minecraftVersion
    whitelistUsers: whitelistUsers
    opUsers: opUsers
    enableWhitelist: enableWhitelist
    onlineMode: onlineMode
    cpuCores: cpuCores
    memorySize: memorySize
    javaMaxMemory: javaMaxMemory
    javaInitMemory: javaInitMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    tcpConcurrentConnections: tcpConcurrentConnections
    scaleCooldownSeconds: scaleCooldownSeconds
    terminationGracePeriodSeconds: terminationGracePeriodSeconds
    startupProbeFailureThreshold: startupProbeFailureThreshold
    rconPassword: rconPassword
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-deployment'
  params: {
    environmentName: containerAppEnvironment.outputs.environmentName
    containerAppName: minecraftContainerApp.outputs.containerAppName
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

@description('MinecraftサーバーへのFQDN (ポート25565で接続)')
output minecraftFqdn string = minecraftContainerApp.outputs.fqdn

@description('Container Apps Environment名')
output containerAppEnvironmentName string = containerAppEnvironment.outputs.environmentName

@description('ストレージアカウント名 (キーは出力しない)')
output storageAccountName string = storage.outputs.storageAccountName
