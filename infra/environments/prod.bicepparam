using '../main.bicep'

// 本番環境向けパラメーター。
// Minecraftバージョンは意図しない自動更新を避けるため必ず固定バージョンを指定する。

param environmentName = 'prod'
param location = 'japaneast'
param namePrefix = 'mcaca-prod'

param vnetAddressPrefix = '10.101.0.0/16'
param infraSubnetAddressPrefix = '10.101.0.0/23'

param logRetentionInDays = 90
param fileShareQuotaGiB = 64

// 本番環境ではワールドデータ保護のため削除ロックを必ず付与する。
param enableStorageDeleteLock = true

param containerImage = 'itzg/minecraft-server:latest'
// 本番環境ではバージョンを明示的に固定すること (例: '26.2')。
// TODO: 実運用開始時に稼働確認済みの具体的なバージョンへ固定すること。
param minecraftVersion = readEnvironmentVariable('MINECRAFT_VERSION', '26.2')

// ホワイトリストユーザーはCI/CD変数(GitHub Environment Secrets/Variables)から注入する。
param whitelistUsers = readEnvironmentVariable('MINECRAFT_WHITELIST_USERS', '')
param opUsers = readEnvironmentVariable('MINECRAFT_OP_USERS', '')

param onlineMode = true
param enableWhitelist = true

param cpuCores = '2.0'
param memorySize = '4Gi'
param javaMaxMemory = '3072M'
param javaInitMemory = '2048M'

param minReplicas = 0
param maxReplicas = 1
param tcpConcurrentConnections = 1

// RCONパスワードはGitHub Environmentのシークレットから環境変数経由で注入する。
param rconPassword = readEnvironmentVariable('MINECRAFT_RCON_PASSWORD', '')
