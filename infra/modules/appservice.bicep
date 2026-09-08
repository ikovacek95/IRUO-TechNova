metadata description = 'Azure App Service - interna web aplikacija tvrtke s automatskim skaliranjem (Ishod 5).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

@description('Connection string Application Insightsa')
param appInsightsConnectionString string

@description('SKU App Service plana. Autoscale zahtijeva Standard (S1) ili visi.')
@allowed([
  'B1'
  'S1'
  'P0v3'
])
param sku string = 'S1'

@description('Minimalni broj instanci')
param autoscaleMin int = 1

@description('Maksimalni broj instanci')
param autoscaleMax int = 3

var planName = '${namePrefix}-plan-${env}'
var webAppName = '${namePrefix}-app-${env}-${uniqueString(resourceGroup().id)}'
var autoscaleName = '${namePrefix}-autoscale-app-${env}'
var isAutoscaleCapable = sku != 'B1'

// ---------------------------------------------------------------------
// App Service Plan (Linux)
// ---------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: autoscaleMin
  }
  kind: 'linux'
  properties: {
    reserved: true
    zoneRedundant: false
  }
}

// ---------------------------------------------------------------------
// Web aplikacija
// ---------------------------------------------------------------------
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    // Sva komunikacija iskljucivo preko HTTPS-a
    httpsOnly: true
    clientAffinityEnabled: false
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      linuxFxVersion: 'PHP|8.2'
      alwaysOn: isAutoscaleCapable
      http20Enabled: true
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/'
      httpLoggingEnabled: true
      detailedErrorLoggingEnabled: true
      requestTracingEnabled: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '0'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------
// Automatsko skaliranje App Service plana (vrsna opterecenja)
// ---------------------------------------------------------------------
resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = if (isAutoscaleCapable) {
  name: autoscaleName
  location: location
  tags: tags
  properties: {
    name: autoscaleName
    enabled: true
    targetResourceUri: plan.id
    notifications: []
    profiles: [
      {
        name: 'TechNova-Default-Profile'
        capacity: {
          minimum: string(autoscaleMin)
          maximum: string(autoscaleMax)
          default: string(autoscaleMin)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'MemoryPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 80
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
  }
}

// ---------------------------------------------------------------------
// Dijagnostika -> Log Analytics
// ---------------------------------------------------------------------
resource webAppDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: webApp
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServiceConsoleLogs', enabled: true }
      { category: 'AppServiceAppLogs', enabled: true }
      { category: 'AppServicePlatformLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output webAppName string = webApp.name
output webAppId string = webApp.id
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output webAppPrincipalId string = webApp.identity.principalId
output appServicePlanId string = plan.id
output autoscaleEnabled bool = isAutoscaleCapable
