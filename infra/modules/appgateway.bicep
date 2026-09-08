metadata description = 'Application Gateway v2 + WAF - napredna inspekcija prometa i TLS terminacija na rubu (Ishod 4). ISKLJUCEN po defaultu zbog cijene (~250 EUR/mj).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('ID subneta rezerviranog za Application Gateway')
param appGwSubnetId string

@description('Privatne IP adrese backend VM-ova')
param backendIpAddresses array

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

@description('Base64 sadrzaj PFX certifikata (generira ga scripts/03-deploy-infra.ps1)')
@secure()
param pfxBase64 string

@description('Lozinka PFX certifikata')
@secure()
param pfxPassword string

var appGwName = '${namePrefix}-appgw-${env}'
var wafPolicyName = '${namePrefix}-wafpolicy-${env}'
var pipName = '${namePrefix}-pip-appgw-${env}'

// =====================================================================
// WAF politika: OWASP 3.2 + Bot Manager + geo-filtriranje na Hrvatsku
// =====================================================================
resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-11-01' = {
  name: wafPolicyName
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.0'
        }
      ]
    }
    customRules: [
      {
        name: 'BlokirajIzvanHrvatske'
        priority: 10
        ruleType: 'MatchRule'
        action: 'Block'
        state: 'Enabled'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RemoteAddr'
              }
            ]
            operator: 'GeoMatch'
            negationConditon: true
            matchValues: [
              'HR'
            ]
          }
        ]
      }
      {
        name: 'OgraniciBrojZahtjeva'
        priority: 20
        ruleType: 'RateLimitRule'
        action: 'Block'
        state: 'Enabled'
        rateLimitDuration: 'OneMin'
        rateLimitThreshold: 300
        groupByUserSession: [
          {
            groupByVariables: [
              {
                variableName: 'ClientAddr'
              }
            ]
          }
        ]
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RemoteAddr'
              }
            ]
            operator: 'IPMatch'
            negationConditon: true
            matchValues: [
              '255.255.255.255/32'
            ]
          }
        ]
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${namePrefix}-waf-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource appGw 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 0
      maxCapacity: 2
    }
    enableHttp2: true
    firewallPolicy: {
      id: wafPolicy.id
    }
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    gatewayIPConfigurations: [
      {
        name: 'appGwIpConfig'
        properties: {
          subnet: {
            id: appGwSubnetId
          }
        }
      }
    ]
    sslCertificates: [
      {
        name: 'technova-cert'
        properties: {
          data: pfxBase64
          password: pfxPassword
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIp'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
      {
        name: 'port_443'
        properties: {
          port: 443
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'bepool-vms'
        properties: {
          backendAddresses: [for ip in backendIpAddresses: {
            ipAddress: ip
          }]
        }
      }
    ]
    probes: [
      {
        name: 'probe-health'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/health'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'settings-backend-8080'
        properties: {
          // Interni port 8080 je NSG pravilom dopusten iskljucivo iz App Gateway subneta.
          port: 8080
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'probe-health')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-http'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGwPublicFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_80')
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener-https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGwPublicFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'technova-cert')
          }
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'redirect-http-to-https'
        properties: {
          redirectType: 'Permanent'
          targetListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener-https')
          }
          includePath: true
          includeQueryString: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule-http-redirect'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener-http')
          }
          redirectConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', appGwName, 'redirect-http-to-https')
          }
        }
      }
      {
        name: 'rule-https'
        properties: {
          ruleType: 'Basic'
          priority: 110
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener-https')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'bepool-vms')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'settings-backend-8080')
          }
        }
      }
    ]
  }
}

resource appGwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appGw
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'ApplicationGatewayAccessLog', enabled: true }
      { category: 'ApplicationGatewayPerformanceLog', enabled: true }
      { category: 'ApplicationGatewayFirewallLog', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output appGatewayName string = appGw.name
output appGatewayUrl string = 'https://${pip.properties.dnsSettings.fqdn}'
output wafPolicyName string = wafPolicy.name
