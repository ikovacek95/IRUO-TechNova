metadata description = 'Pohrana: objektna (Blob) + dijeljeni dokumenti (Azure Files), passwordless pristup preko Entra ID + Hot/Cool tiering (Ishod 2).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

@description('ID Frontend subneta (service endpoint pravilo)')
param frontendSubnetId string

@description('ID Backend subneta (service endpoint pravilo)')
param backendSubnetId string

@description('Javna IP adresa administratora koja smije pristupiti pohrani (za rad iz portala/CLI-a)')
param allowedAdminIp string = ''

@description('Zadana mrezna akcija: Deny = pristup samo iz VNet-a i s navedene IP adrese')
@allowed([
  'Allow'
  'Deny'
])
param networkDefaultAction string = 'Deny'

// Naziv storage accounta: samo mala slova i brojke, max 24 znaka
// Odstupanje od standarda <tvrtka>-<resurs>-<okruzenje> jer Azure ne dopusta crtice.
var storageName = take('${namePrefix}st${env}${uniqueString(resourceGroup().id)}', 24)
var flowLogStorageName = take('${namePrefix}flow${env}${uniqueString(resourceGroup().id)}', 24)

var ipRules = empty(allowedAdminIp) ? [] : [
  {
    value: allowedAdminIp
    action: 'Allow'
  }
]

// =====================================================================
// 1. GLAVNI STORAGE ACCOUNT - aplikacijski podaci, staticki resursi, file share
// =====================================================================
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // HOT tier kao zadani - cesto koristeni aplikacijski podaci
    accessTier: 'Hot'
    // KLJUCNO: onemogucen pristup preko account keya => nema "lozinke",
    // autentikacija je iskljucivo preko Entra ID (Azure RBAC).
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: networkDefaultAction
      bypass: 'AzureServices, Logging, Metrics'
      virtualNetworkRules: [
        {
          id: frontendSubnetId
          action: 'Allow'
        }
        {
          id: backendSubnetId
          action: 'Allow'
        }
      ]
      ipRules: ipRules
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

// ---------------------------------------------------------------------
// Blob service: verzioniranje, soft delete, change feed
// ---------------------------------------------------------------------
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    // Obavezno za lifecycle pravilo koje koristi 'daysAfterLastAccessTimeGreaterThan'.
    // Bez ovoga Azure odbija politiku greskom MissingLastAccessTimeBasedTrackingPolicy.
    lastAccessTimeTrackingPolicy: {
      enable: true
      name: 'AccessTimeTracking'
      trackingGranularityInDays: 1
      blobType: [
        'blockBlob'
      ]
    }
    changeFeed: {
      enabled: true
      retentionInDays: 7
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource containerAppData 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'app-data'
  properties: {
    publicAccess: 'None'
    metadata: {
      opis: 'Aplikacijski podaci - HOT tier'
    }
  }
}

resource containerStatic 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'static-assets'
  properties: {
    publicAccess: 'None'
    metadata: {
      opis: 'Staticki resursi web aplikacije - HOT tier'
    }
  }
}

resource containerArchive 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'archive'
  properties: {
    publicAccess: 'None'
    metadata: {
      opis: 'Rijetko koristeni podaci - automatski prelaze u COOL tier'
    }
  }
}

// ---------------------------------------------------------------------
// Azure Files: dijeljeni dokumenti izmedu odjela
// ---------------------------------------------------------------------
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    protocolSettings: {
      smb: {
        versions: 'SMB3.0;SMB3.1.1'
        authenticationMethods: 'NTLMv2;Kerberos'
        channelEncryption: 'AES-128-GCM;AES-256-GCM'
      }
    }
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource shareShared 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'odjeli-dijeljeno'
  properties: {
    // HOT tier - dijeljeni dokumenti kojima se cesto pristupa.
    // Zadatak trazi izricito tierove Hot i Cool, pa se ne koristi
    // TransactionOptimized (koji je zadani za Azure Files).
    accessTier: 'Hot'
    shareQuota: 10
    metadata: {
      opis: 'Dijeljeni dokumenti Development / Sales / Support odjela - HOT tier'
    }
  }
}

resource shareArchive 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'arhiva-dokumenata'
  properties: {
    // COOL tier za rijetko koristene dijeljene dokumente
    accessTier: 'Cool'
    shareQuota: 10
    metadata: {
      opis: 'Arhiva dokumenata - COOL tier zbog niske frekvencije pristupa'
    }
  }
}

// ---------------------------------------------------------------------
// Lifecycle management: HOT -> COOL -> ARCHIVE prema frekvenciji koristenja
// ---------------------------------------------------------------------
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'archive-container-tiering'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'archive/'
              ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 15
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 90
                }
                delete: {
                  daysAfterModificationGreaterThan: 365
                }
              }
              snapshot: {
                delete: {
                  daysAfterCreationGreaterThan: 30
                }
              }
              version: {
                delete: {
                  daysAfterCreationGreaterThan: 30
                }
              }
            }
          }
        }
        {
          enabled: true
          name: 'appdata-cool-after-90d'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'app-data/'
              ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterLastAccessTimeGreaterThan: 90
                }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [
    blobService
    containerAppData
    containerArchive
  ]
}

// ---------------------------------------------------------------------
// Dijagnostika pohrane -> Log Analytics
// ---------------------------------------------------------------------
resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobService
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'StorageRead', enabled: true }
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

resource fileDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: fileService
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'StorageRead', enabled: true }
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

// =====================================================================
// 2. STORAGE ZA NSG FLOW LOGOVE
// Odvojen account jer Network Watcher Flow Logs zahtijeva pristup preko
// account keya, sto je na glavnom accountu namjerno onemoguceno.
// =====================================================================
resource flowLogStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: flowLogStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
    }
  }
}

output storageAccountName string = storage.name
output storageAccountId string = storage.id
output storagePrimaryBlobEndpoint string = storage.properties.primaryEndpoints.blob
output storagePrimaryFileEndpoint string = storage.properties.primaryEndpoints.file
output fileShareName string = shareShared.name
output flowLogStorageId string = flowLogStorage.id
output flowLogStorageName string = flowLogStorage.name
