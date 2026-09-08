metadata description = 'Azure SQL Database u Backend segmentu, iskljucivo s Entra ID autentikacijom (bez SQL lozinke).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

@description('ID Backend subneta')
param backendSubnetId string

@description('Object ID Entra ID grupe koja je administrator baze')
param adminGroupObjectId string

@description('Naziv Entra ID grupe koja je administrator baze')
param adminGroupName string = 'TechNova-Dev'

var serverName = '${namePrefix}-sql-${env}-${uniqueString(resourceGroup().id)}'
var dbName = '${namePrefix}-db-${env}'

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: 'Disabled'
    // KLJUCNO: nema SQL korisnickog imena i lozinke.
    // Autentikacija je iskljucivo preko Entra ID identiteta.
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: adminGroupName
      sid: adminGroupObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: dbName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Local'
  }
}

// Dozvola pristupa Azure servisima (App Service, VM-ovi s Managed Identityjem)
resource fwAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Pristup iz Backend segmenta virtualne mreze (service endpoint)
resource vnetRule 'Microsoft.Sql/servers/virtualNetworkRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'allow-backend-subnet'
  properties: {
    virtualNetworkSubnetId: backendSubnetId
    ignoreMissingVnetServiceEndpoint: false
  }
}

// Revizija (auditing) svih pristupa bazi -> Log Analytics
resource auditing 'Microsoft.Sql/servers/auditingSettings@2023-08-01-preview' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    retentionDays: 30
  }
}

resource masterDbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-audit-to-law'
  scope: sqlServerMasterDb
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'SQLSecurityAuditEvents', enabled: true }
    ]
  }
}

resource sqlServerMasterDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' existing = {
  parent: sqlServer
  name: 'master'
}

resource dbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: sqlDb
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'Errors', enabled: true }
      { category: 'Timeouts', enabled: true }
      { category: 'Blocks', enabled: true }
      { category: 'Deadlocks', enabled: true }
    ]
    metrics: [
      { category: 'Basic', enabled: true }
    ]
  }
}

output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDb.name
