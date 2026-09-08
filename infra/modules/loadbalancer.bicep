metadata description = 'Standard Load Balancer - balansiranje prometa prema oba VM-a za korisnike izvan oblaka (Ishod 4).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

var lbName = '${namePrefix}-lb-${env}'
var pipName = '${namePrefix}-pip-lb-${env}'
var frontendConfigName = 'fe-public'
var backendPoolName = 'bepool-web'
var probeName = 'probe-http-health'
var dnsLabel = '${namePrefix}-${env}-${uniqueString(resourceGroup().id)}'

// ---------------------------------------------------------------------
// Javna IP adresa (Standard SKU, staticka, zone-redundantna)
// ---------------------------------------------------------------------
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

// ---------------------------------------------------------------------
// Load Balancer
// ---------------------------------------------------------------------
resource lb 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: lbName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: frontendConfigName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: backendPoolName
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          // HTTP probe na /health -> stvarna provjera zdravlja aplikacije,
          // a ne samo otvorenog TCP porta.
          protocol: 'Http'
          port: 80
          requestPath: '/health'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, frontendConfigName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 5
          // Distribucija po izvorisnom IP-u i portu (5-tuple)
          loadDistribution: 'Default'
          // Obavezno kada koristimo eksplicitno outbound pravilo
          disableOutboundSnat: true
        }
      }
      {
        name: 'rule-http-redirect'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, frontendConfigName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 5
          loadDistribution: 'Default'
          disableOutboundSnat: true
        }
      }
    ]
    outboundRules: [
      {
        name: 'outbound-internet'
        properties: {
          // Kontrolirani izlaz VM-ova na Internet (apt update, Azure Monitor)
          protocol: 'All'
          allocatedOutboundPorts: 1024
          idleTimeoutInMinutes: 4
          enableTcpReset: true
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, frontendConfigName)
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
          }
        }
      }
    ]
  }
}

resource lbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: lb
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output loadBalancerId string = lb.id
output loadBalancerName string = lb.name
output backendPoolId string = resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
output healthProbeId string = resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
output publicIpAddress string = publicIp.properties.ipAddress
output publicIpName string = publicIp.name
output fqdn string = publicIp.properties.dnsSettings.fqdn
output appUrlHttps string = 'https://${publicIp.properties.dnsSettings.fqdn}'
