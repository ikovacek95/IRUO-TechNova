metadata description = 'Azure Key Vault s RBAC autorizacijom - centralno cuvanje tajni (bez lozinki u kodu).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

@description('Lozinka lokalnog administratora VM-a koja se pohranjuje kao tajna')
@secure()
param vmAdminPassword string

// Key Vault naziv: 3-24 znaka, globalno jedinstven
var kvName = take('${namePrefix}-kv-${env}-${uniqueString(resourceGroup().id)}', 24)

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    // Moderni model: dozvole se dodjeljuju preko Azure RBAC-a, ne access policyja
    enableRbacAuthorization: true
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Namjerno false kako bi se okruzenje moglo potpuno ukloniti nakon predaje projekta.
    // U produkciji: true.
    enablePurgeProtection: null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource secretVmPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'VmAdminPassword'
  properties: {
    value: vmAdminPassword
    contentType: 'Lozinka lokalnog administratora Ubuntu VM-ova'
  }
}

resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'AuditEvent', enabled: true }
      { category: 'AzurePolicyEvaluationDetails', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
