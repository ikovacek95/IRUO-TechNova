metadata description = 'Azure Bastion - administrativni pristup bez javnih IP adresa na VM-ovima. ISKLJUCEN po defaultu zbog cijene (~130 EUR/mj).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('ID AzureBastionSubnet subneta')
param bastionSubnetId string

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

var bastionName = '${namePrefix}-bastion-${env}'
var pipName = '${namePrefix}-pip-bastion-${env}'

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource bastionDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: bastion
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'BastionAuditLogs', enabled: true }
    ]
  }
}

output bastionName string = bastion.name
