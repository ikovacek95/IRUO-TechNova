metadata description = 'Virtual Machine Scale Set s automatskim skaliranjem - horizontalna skalabilnost VM sloja. ISKLJUCEN po defaultu (aktivira se prekidacem -WithVmss).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('ID Frontend subneta')
param subnetId string

@description('ID backend poola Load Balancera')
param backendPoolId string

@description('ID health probe-a Load Balancera (potrebno za automatski popravak instanci)')
param healthProbeId string

@description('Resource ID Log Analytics Workspace-a')
param logAnalyticsWorkspaceId string

param adminUsername string = 'azureuser'

@secure()
param adminPassword string

param vmSize string = 'Standard_B1s'
param instanceCountMin int = 2
param instanceCountMax int = 5

var vmssName = '${namePrefix}-vmss-${env}'
var autoscaleName = '${namePrefix}-autoscale-vmss-${env}'

var cloudInit = '''
#cloud-config
package_update: true
packages:
  - nginx
  - openssl
write_files:
  - path: /var/www/html/index.html
    permissions: '0644'
    content: |
      <!DOCTYPE html>
      <html lang="hr">
      <head><meta charset="utf-8"><title>TechNova Solutions - VMSS</title></head>
      <body style="font-family:sans-serif;text-align:center;padding:60px;background:#f3f2f1">
        <h1 style="color:#0078d4">TechNova Solutions</h1>
        <p>Instanca Virtual Machine Scale Seta: <b>__HOSTNAME__</b></p>
      </body>
      </html>
  - path: /etc/nginx/sites-available/technova
    permissions: '0644'
    content: |
      server {
          listen 80 default_server;
          server_name _;
          location = /health { access_log off; add_header Content-Type text/plain; return 200 "OK"; }
          location / { return 301 https://$host$request_uri; }
      }
      server {
          listen 443 ssl default_server;
          server_name _;
          ssl_certificate     /etc/ssl/certs/technova.crt;
          ssl_certificate_key /etc/ssl/private/technova.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          add_header Strict-Transport-Security "max-age=31536000" always;
          root /var/www/html;
          index index.html;
          location = /health { access_log off; add_header Content-Type text/plain; return 200 "OK"; }
      }
runcmd:
  - openssl req -x509 -nodes -days 730 -newkey rsa:2048 -keyout /etc/ssl/private/technova.key -out /etc/ssl/certs/technova.crt -subj "/C=HR/ST=Zagreb/L=Zagreb/O=TechNova Solutions d.o.o./CN=technova.local"
  - chmod 600 /etc/ssl/private/technova.key
  - sed -i "s/__HOSTNAME__/$(hostname)/g" /var/www/html/index.html
  - rm -f /etc/nginx/sites-enabled/default
  - ln -sf /etc/nginx/sites-available/technova /etc/nginx/sites-enabled/technova
  - systemctl enable nginx
  - systemctl restart nginx
'''

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: vmssName
  location: location
  tags: tags
  sku: {
    name: vmSize
    tier: 'Standard'
    capacity: instanceCountMin
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    overprovision: true
    singlePlacementGroup: false
    upgradePolicy: {
      mode: 'Automatic'
      automaticOSUpgradePolicy: {
        enableAutomaticOSUpgrade: false
      }
    }
    // Automatski popravak instanci koje padnu na health probe (oporavak u slucaju kvara)
    automaticRepairsPolicy: {
      enabled: true
      gracePeriod: 'PT10M'
      repairAction: 'Replace'
    }
    virtualMachineProfile: {
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      }
      osProfile: {
        computerNamePrefix: 'tnvmss'
        adminUsername: adminUsername
        adminPassword: adminPassword
        customData: base64(cloudInit)
        linuxConfiguration: {
          disablePasswordAuthentication: false
          provisionVMAgent: true
        }
      }
      networkProfile: {
        healthProbe: {
          id: healthProbeId
        }
        networkInterfaceConfigurations: [
          {
            name: 'nic-vmss'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    subnet: {
                      id: subnetId
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: backendPoolId
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'AzureMonitorLinuxAgent'
            properties: {
              publisher: 'Microsoft.Azure.Monitor'
              type: 'AzureMonitorLinuxAgent'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
              enableAutomaticUpgrade: true
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
    }
  }
}

// ---------------------------------------------------------------------
// Automatsko skaliranje: scale-out na CPU > 75%, scale-in na CPU < 25%
// ---------------------------------------------------------------------
resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: autoscaleName
  location: location
  tags: tags
  properties: {
    name: autoscaleName
    enabled: true
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'TechNova-VMSS-Profile'
        capacity: {
          minimum: string(instanceCountMin)
          maximum: string(instanceCountMax)
          default: string(instanceCountMin)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 75
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
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 25
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

resource vmssDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vmss
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output vmssName string = vmss.name
output vmssId string = vmss.id
output autoscaleSettingName string = autoscale.name
