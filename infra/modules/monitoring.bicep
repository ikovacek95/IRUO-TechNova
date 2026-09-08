metadata description = 'Centralizirani nadzor: Log Analytics, Application Insights, Action Group i Data Collection Rule za VM Insights (Ishod 3 i 5).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('E-mail adresa na koju se salju upozorenja (alarmi)')
param alertEmail string

@description('Zadrzavanje logova u danima')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

var lawName = '${namePrefix}-law-${env}'
var appInsightsName = '${namePrefix}-appi-${env}'
var actionGroupName = '${namePrefix}-ag-${env}'
var dcrName = '${namePrefix}-dcr-vm-${env}'

// ---------------------------------------------------------------------
// 1. Log Analytics Workspace - jedinstveno mjesto za sve logove i metrike
// ---------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------
// 2. Application Insights (workspace-based) - APM za web aplikacije
// ---------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------
// 3. Action Group - kanal za obavijesti (e-mail administratorima)
// ---------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'TechNovaOps'
    enabled: true
    emailReceivers: [
      {
        name: 'AdminEmail'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------
// 4. Data Collection Rule - sto Azure Monitor Agent prikuplja s Linux VM-ova
// ---------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Prikupljanje performansi (CPU/RAM/disk/mreza) i sigurnosnih syslog zapisa s TechNova VM-ova'
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Processor(*)\\% Idle Time'
            'Memory(*)\\% Used Memory'
            'Memory(*)\\Available MBytes Memory'
            'Logical Disk(*)\\% Used Space'
            'Logical Disk(*)\\Disk Reads/sec'
            'Logical Disk(*)\\Disk Writes/sec'
            'Network(*)\\Total Bytes Received'
            'Network(*)\\Total Bytes Transmitted'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslogSecurity'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'syslog'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'laDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'laDestination'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'laDestination'
        ]
      }
    ]
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output workspaceCustomerId string = law.properties.customerId
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output actionGroupId string = actionGroup.id
output dcrId string = dcr.id
