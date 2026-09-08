metadata description = 'Alarmi i obavijesti za kljucne dogadaje: CPU > 80%, nedostupnost servisa, greske aplikacije (Ishod 5).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Action Groupa za obavijesti')
param actionGroupId string

@description('Resource ID-ovi virtualnih strojeva')
param vmIds array

@description('Resource ID Load Balancera')
param loadBalancerId string

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

@description('Resource ID Web Appa (prazno = alarm se ne kreira)')
param webAppId string = ''

// =====================================================================
// 1. CPU > 80% na virtualnim strojevima
// =====================================================================
resource alertVmCpu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-alert-vm-cpu-${env}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Prosjecno opterecenje procesora VM-a prelazi 80% kroz 5 minuta.'
    severity: 2
    enabled: true
    scopes: vmIds
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'HighCpu'
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// =====================================================================
// 2. Nedostupnost servisa - data path Load Balancera
// =====================================================================
resource alertLbAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-alert-lb-availability-${env}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Load Balancer prijavljuje nedostupnost podatkovne putanje (VIP availability < 100%).'
    severity: 1
    enabled: true
    scopes: [
      loadBalancerId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'VipUnavailable'
          metricName: 'VipAvailability'
          metricNamespace: 'Microsoft.Network/loadBalancers'
          operator: 'LessThan'
          threshold: 100
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// =====================================================================
// 3. Nezdrave instance iza Load Balancera (health probe)
// =====================================================================
resource alertLbProbe 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-alert-lb-probe-${env}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Manje od 100% backend instanci prolazi health probe - moguci ispad VM-a.'
    severity: 2
    enabled: true
    scopes: [
      loadBalancerId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'UnhealthyBackend'
          metricName: 'DipAvailability'
          metricNamespace: 'Microsoft.Network/loadBalancers'
          operator: 'LessThan'
          threshold: 100
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// =====================================================================
// 4. Izostanak heartbeata VM-a (VM je pao ili je izgubio mrezu)
// =====================================================================
resource alertHeartbeat 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-alert-vm-heartbeat-${env}'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'TechNova - VM ne salje heartbeat'
    description: 'Virtualni stroj nije poslao heartbeat u zadnjih 10 minuta.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: 'Heartbeat\n| where Computer startswith "technova-vm"\n| summarize LastHeartbeat = max(TimeGenerated) by Computer\n| where LastHeartbeat < ago(10m)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}

// =====================================================================
// 5. HTTP 5xx greske interne web aplikacije (App Service)
// =====================================================================
resource alertApp5xx 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(webAppId)) {
  name: '${namePrefix}-alert-app-5xx-${env}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Interna web aplikacija vraca vise od 10 HTTP 5xx odgovora u 5 minuta.'
    severity: 2
    enabled: true
    scopes: [
      webAppId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'Http5xx'
          metricName: 'Http5xx'
          metricNamespace: 'Microsoft.Web/sites'
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

output alertNames array = [
  alertVmCpu.name
  alertLbAvailability.name
  alertLbProbe.name
  alertHeartbeat.name
]
