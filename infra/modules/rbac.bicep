metadata description = 'RBAC: dodjela uloga grupama odjela i managed identityjima po nacelu najmanjih privilegija (Ishod 1).'

param namePrefix string = 'technova'

@description('Object ID grupe TechNova-Dev')
param devGroupObjectId string

@description('Object ID grupe TechNova-Sales')
param salesGroupObjectId string

@description('Object ID grupe TechNova-Support')
param supportGroupObjectId string

@description('Naziv Storage Accounta')
param storageAccountName string

@description('Naziv Key Vaulta')
param keyVaultName string

@description('Principal ID-ovi managed identityja koji trebaju citati tajne i podatke')
param workloadPrincipalIds array = []

// --- Ugradene Azure uloge (built-in role definition ID-ovi) ---
var roleReader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var roleVirtualMachineContributor = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var roleMonitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var roleStorageFileDataSmbShareContributor = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
var roleStorageFileDataSmbShareReader = 'aba4ae5f-2193-4029-9191-0cb91df5e314'
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var roleKeyVaultSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// =====================================================================
// 1. Uloge na razini Resource Grupe
//    Development -> upravlja VM-ovima
//    Sales       -> samo citanje
//    Support     -> citanje + nadzor
// =====================================================================
var rgRoleAssignments = [
  {
    key: 'dev-vm-contributor'
    principalId: devGroupObjectId
    roleId: roleVirtualMachineContributor
  }
  {
    key: 'sales-reader'
    principalId: salesGroupObjectId
    roleId: roleReader
  }
  {
    key: 'support-reader'
    principalId: supportGroupObjectId
    roleId: roleReader
  }
  {
    key: 'support-monitoring-reader'
    principalId: supportGroupObjectId
    roleId: roleMonitoringReader
  }
]

resource rgRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in rgRoleAssignments: {
  name: guid(resourceGroup().id, item.principalId, item.roleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', item.roleId)
    principalId: item.principalId
    principalType: 'Group'
  }
}]

// =====================================================================
// 2. Data-plane uloge na Storage Accountu
//    Pristup podacima ide iskljucivo preko Entra ID identiteta,
//    jer je allowSharedKeyAccess onemogucen (nema account keya / lozinke).
// =====================================================================
var storageRoleAssignments = [
  {
    key: 'dev-blob-contributor'
    principalId: devGroupObjectId
    roleId: roleStorageBlobDataContributor
  }
  {
    key: 'dev-file-contributor'
    principalId: devGroupObjectId
    roleId: roleStorageFileDataSmbShareContributor
  }
  {
    key: 'sales-blob-reader'
    principalId: salesGroupObjectId
    roleId: roleStorageBlobDataReader
  }
  {
    key: 'sales-file-contributor'
    principalId: salesGroupObjectId
    roleId: roleStorageFileDataSmbShareContributor
  }
  {
    key: 'support-blob-reader'
    principalId: supportGroupObjectId
    roleId: roleStorageBlobDataReader
  }
  {
    key: 'support-file-reader'
    principalId: supportGroupObjectId
    roleId: roleStorageFileDataSmbShareReader
  }
]

resource storageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in storageRoleAssignments: {
  name: guid(storage.id, item.principalId, item.roleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', item.roleId)
    principalId: item.principalId
    principalType: 'Group'
  }
}]

// =====================================================================
// 3. Key Vault uloge
// =====================================================================
resource kvDevOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, devGroupObjectId, roleKeyVaultSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsOfficer)
    principalId: devGroupObjectId
    principalType: 'Group'
  }
}

// =====================================================================
// 4. Managed Identity radnih opterecenja (VM-ovi, App Service)
//    -> citaju tajne iz Key Vaulta i podatke iz pohrane bez ikakve lozinke
// =====================================================================
resource workloadKvRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (pid, i) in workloadPrincipalIds: {
  name: guid(keyVault.id, pid, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]

resource workloadStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (pid, i) in workloadPrincipalIds: {
  name: guid(storage.id, pid, roleStorageBlobDataReader)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]

output assignedRoleSummary array = [
  '${namePrefix}: Development -> Virtual Machine Contributor (RG), Storage Blob Data Contributor, Key Vault Secrets Officer'
  '${namePrefix}: Sales -> Reader (RG), Storage Blob Data Reader, Storage File Data SMB Share Contributor'
  '${namePrefix}: Support -> Reader + Monitoring Reader (RG), Storage Blob Data Reader, Storage File Data SMB Share Reader'
  '${namePrefix}: Managed Identity (VM/App Service) -> Key Vault Secrets User, Storage Blob Data Reader'
]
