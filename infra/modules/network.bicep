metadata description = 'Mrezna arhitektura: VNet s odvojenim Frontend/Backend/Management segmentima + NSG filtriranje prometa (Ishod 2 i 4).'

@description('Azure regija')
param location string

@description('Prefiks naziva tvrtke')
param namePrefix string = 'technova'

@description('Oznaka okruzenja')
param env string = 'prod'

@description('Oznake (tags) koje se primjenjuju na sve resurse')
param tags object = {}

@description('Resource ID Log Analytics Workspace-a za dijagnostiku NSG-ova')
param logAnalyticsWorkspaceId string

param vnetAddressPrefix string = '10.10.0.0/16'
param frontendPrefix string = '10.10.1.0/24'
param backendPrefix string = '10.10.2.0/24'
param managementPrefix string = '10.10.3.0/24'
param bastionPrefix string = '10.10.250.0/26'
param appGwPrefix string = '10.10.251.0/24'
param firewallPrefix string = '10.10.252.0/26'

var vnetName = '${namePrefix}-vnet-${env}'
var nsgFrontendName = '${namePrefix}-nsg-frontend-${env}'
var nsgBackendName = '${namePrefix}-nsg-backend-${env}'
var nsgMgmtName = '${namePrefix}-nsg-mgmt-${env}'

// =====================================================================
// NSG: FRONTEND  - javno dostupan web sloj (VM1 + VM2 iza Load Balancera)
// =====================================================================
resource nsgFrontend 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgFrontendName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          description: 'Kriptirani promet prema web aplikaciji (zahtjev: sva komunikacija HTTPS/SSL)'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-HTTP-Redirect-And-Probe'
        properties: {
          description: 'Port 80 sluzi iskljucivo za 301 redirect na HTTPS i za /health provjeru Load Balancera'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          description: 'Health probe iz Azure Load Balancer infrastrukture'
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-AppGateway-Inbound'
        properties: {
          description: 'Interni port 8080 dostupan iskljucivo iz Application Gateway subneta (WAF putanja)'
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '8080'
          sourceAddressPrefix: appGwPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-SSH-From-Management'
        properties: {
          description: 'Administrativni SSH iskljucivo iz Management segmenta (bastion/jump host)'
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: managementPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-SSH-From-Internet-JIT'
        properties: {
          description: 'Simulacija JIT pristupa: SSH s Interneta je blokiran; skripta 06-jit-pristup.ps1 dodaje Allow pravilo na prioritetu 300.'
          priority: 3900
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          description: 'Explicit deny (zero-trust): sve sto nije eksplicitno dozvoljeno je blokirano'
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// =====================================================================
// NSG: BACKEND - baze podataka i interne aplikacije, bez izlaza na Internet
// =====================================================================
resource nsgBackend 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgBackendName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SQL-From-Frontend'
        properties: {
          description: 'Samo web sloj smije prema bazi na portu 1433'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: frontendPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-InternalApp-From-Frontend'
        properties: {
          description: 'Interne aplikacijske usluge (npr. API na 8080)'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '8080'
          sourceAddressPrefix: frontendPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-SSH-From-Management'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: managementPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          description: 'Backend segment nije dostupan s Interneta'
          priority: 3900
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-VNet-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-AzureMonitor-Outbound'
        properties: {
          description: 'Slanje metrika i logova u Azure Monitor / Log Analytics'
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureMonitor'
        }
      }
      {
        name: 'Deny-Internet-Outbound'
        properties: {
          description: 'Data exfiltration zastita: backend nema slobodan izlaz na Internet'
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
    ]
  }
}

// =====================================================================
// NSG: MANAGEMENT - administrativni pristup i nadzor
// =====================================================================
resource nsgManagement 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgMgmtName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-Inbound'
        properties: {
          description: 'RDP/SSH preko Azure Bastiona (bez javnih IP adresa na VM-ovima)'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// =====================================================================
// VIRTUALNA MREZA + SEGMENTACIJA
// =====================================================================
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-frontend'
        properties: {
          addressPrefix: frontendPrefix
          networkSecurityGroup: {
            id: nsgFrontend.id
          }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.KeyVault' }
            { service: 'Microsoft.Sql' }
          ]
        }
      }
      {
        name: 'snet-backend'
        properties: {
          addressPrefix: backendPrefix
          networkSecurityGroup: {
            id: nsgBackend.id
          }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.KeyVault' }
            { service: 'Microsoft.Sql' }
          ]
        }
      }
      {
        name: 'snet-management'
        properties: {
          addressPrefix: managementPrefix
          networkSecurityGroup: {
            id: nsgManagement.id
          }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
      {
        // Naziv je obavezan i fiksan za Azure Bastion
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionPrefix
        }
      }
      {
        // Rezervirano za Application Gateway + WAF (vidi docs/ - opcija deployAppGateway)
        name: 'snet-appgw'
        properties: {
          addressPrefix: appGwPrefix
        }
      }
      {
        // Naziv je obavezan i fiksan za Azure Firewall
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallPrefix
        }
      }
    ]
  }
}

// =====================================================================
// DIJAGNOSTIKA NSG-ova -> Log Analytics (centralizirani nadzor, Ishod 5)
// =====================================================================
resource nsgFrontendDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: nsgFrontend
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'NetworkSecurityGroupEvent', enabled: true }
      { category: 'NetworkSecurityGroupRuleCounter', enabled: true }
    ]
  }
}

resource nsgBackendDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: nsgBackend
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'NetworkSecurityGroupEvent', enabled: true }
      { category: 'NetworkSecurityGroupRuleCounter', enabled: true }
    ]
  }
}

resource nsgMgmtDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: nsgManagement
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'NetworkSecurityGroupEvent', enabled: true }
      { category: 'NetworkSecurityGroupRuleCounter', enabled: true }
    ]
  }
}

// =====================================================================
// OUTPUTS
// =====================================================================
output vnetId string = vnet.id
output vnetName string = vnet.name
output frontendSubnetId string = vnet.properties.subnets[0].id
output backendSubnetId string = vnet.properties.subnets[1].id
output managementSubnetId string = vnet.properties.subnets[2].id
output bastionSubnetId string = vnet.properties.subnets[3].id
output appGwSubnetId string = vnet.properties.subnets[4].id
output firewallSubnetId string = vnet.properties.subnets[5].id
output nsgFrontendName string = nsgFrontend.name
output nsgBackendName string = nsgBackend.name
output nsgManagementName string = nsgManagement.name
