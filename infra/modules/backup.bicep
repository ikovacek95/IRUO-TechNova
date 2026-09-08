metadata description = 'Recovery Services Vault i dnevna backup politika za VM-ove (kontinuitet poslovanja).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

var vaultName = '${namePrefix}-rsv-${env}'
var policyName = '${namePrefix}-backup-daily-${env}'

resource vault 'Microsoft.RecoveryServices/vaults@2023-04-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    securitySettings: {
      softDeleteSettings: {
        // 'Disabled' kako bi se okruzenje moglo u potpunosti ukloniti nakon predaje
        // projekta. U produkciji obavezno 'AlwaysON' (zastita od zlonamjernog brisanja
        // sigurnosnih kopija). Napomena: 'Off' NIJE valjana vrijednost ovog polja.
        softDeleteState: 'Disabled'
      }
    }
  }
}

// LRS umjesto zadanog GRS-a - znacajno jeftinije za studentsku pretplatu.
// Mora se postaviti prije nego se zastiti prvi resurs.
resource vaultStorageConfig 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2023-04-01' = {
  parent: vault
  name: 'vaultstorageconfig'
  properties: {
    storageModelType: 'LocallyRedundant'
    crossRegionRestoreFlag: false
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = {
  parent: vault
  name: policyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    timeZone: 'Central European Standard Time'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        '2025-01-01T22:00:00Z'
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2025-01-01T22:00:00Z'
        ]
        retentionDuration: {
          count: 7
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: [
          'Sunday'
        ]
        retentionTimes: [
          '2025-01-01T22:00:00Z'
        ]
        retentionDuration: {
          count: 4
          durationType: 'Weeks'
        }
      }
    }
  }
  dependsOn: [
    vaultStorageConfig
  ]
}

output vaultName string = vault.name
output vaultId string = vault.id
output backupPolicyName string = backupPolicy.name
