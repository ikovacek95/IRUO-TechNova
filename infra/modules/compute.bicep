metadata description = 'Dva Ubuntu 22.04 VM-a u Availability Setu iza Load Balancera, s nginx/HTTPS i Azure Monitor Agentom (Ishod 3).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('ID Frontend subneta')
param subnetId string

@description('ID backend poola Load Balancera')
param backendPoolId string

@description('Resource ID Data Collection Rule-a za VM Insights')
param dcrId string

@description('Lokalno administratorsko korisnicko ime')
param adminUsername string = 'azureuser'

@description('Lozinka lokalnog administratora')
@secure()
param adminPassword string

@description('Velicina VM-a. Standard_B2ls_v2 = 2 vCPU / 4 GB (v2 B-serija).')
param vmSize string = 'Standard_B2ls_v2'

var vmNames = [
  '${namePrefix}-vm1-${env}'
  '${namePrefix}-vm2-${env}'
]
var availabilitySetName = '${namePrefix}-avset-${env}'

// ---------------------------------------------------------------------
// cloud-init: nginx + self-signed TLS certifikat + HTTP->HTTPS redirect
// + /health endpoint za Load Balancer probe
// ---------------------------------------------------------------------
var cloudInit = '''
#cloud-config
package_update: true
packages:
  - nginx
  - openssl
  - stress-ng
write_files:
  - path: /var/www/html/index.html
    permissions: '0644'
    content: |
      <!DOCTYPE html>
      <html lang="hr">
      <head>
        <meta charset="utf-8">
        <title>TechNova Solutions d.o.o.</title>
        <style>
          body { font-family: Segoe UI, sans-serif; background:#f3f2f1; margin:0; padding:60px; text-align:center; }
          .card { background:#fff; max-width:640px; margin:0 auto; padding:40px; border-radius:8px; box-shadow:0 2px 12px rgba(0,0,0,.1); }
          h1 { color:#0078d4; margin-bottom:4px; }
          .host { font-family:Consolas,monospace; background:#0078d4; color:#fff; padding:8px 16px; border-radius:4px; display:inline-block; margin-top:16px; }
          .meta { color:#605e5c; font-size:14px; margin-top:24px; line-height:1.7; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>TechNova Solutions</h1>
          <p>Poslovna web aplikacija - Microsoft Azure</p>
          <div class="host">Posluzuje: __HOSTNAME__</div>
          <div class="meta">
            Ubuntu 22.04 LTS &middot; nginx &middot; TLS 1.2/1.3<br>
            Iza Azure Standard Load Balancera<br>
            Osvjezite stranicu vise puta - naziv posluzitelja se mijenja (dokaz balansiranja).
          </div>
        </div>
      </body>
      </html>
  - path: /etc/nginx/sites-available/technova
    permissions: '0644'
    content: |
      server {
          listen 80 default_server;
          server_name _;

          # Health probe Load Balancera mora ostati na HTTP-u
          location = /health {
              access_log off;
              add_header Content-Type text/plain;
              return 200 "OK";
          }

          # Sav ostali promet se prisilno preusmjerava na HTTPS
          location / {
              return 301 https://$host$request_uri;
          }
      }

      server {
          listen 443 ssl default_server;
          server_name _;

          ssl_certificate     /etc/ssl/certs/technova.crt;
          ssl_certificate_key /etc/ssl/private/technova.key;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_ciphers         HIGH:!aNULL:!MD5;
          ssl_prefer_server_ciphers on;

          add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
          add_header X-Frame-Options "DENY" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header Referrer-Policy "no-referrer-when-downgrade" always;

          root /var/www/html;
          index index.html;

          location = /health {
              access_log off;
              add_header Content-Type text/plain;
              return 200 "OK";
          }

          location / {
              try_files $uri $uri/ =404;
          }
      }

      # Interni port za Application Gateway (WAF terminira TLS na rubu).
      # NSG pravilo dopusta pristup iskljucivo iz snet-appgw segmenta.
      server {
          listen 8080;
          server_name _;
          root /var/www/html;
          index index.html;

          location = /health {
              access_log off;
              add_header Content-Type text/plain;
              return 200 "OK";
          }
      }
runcmd:
  - openssl req -x509 -nodes -days 730 -newkey rsa:2048 -keyout /etc/ssl/private/technova.key -out /etc/ssl/certs/technova.crt -subj "/C=HR/ST=Zagreb/L=Zagreb/O=TechNova Solutions d.o.o./OU=IT/CN=technova.local"
  - chmod 600 /etc/ssl/private/technova.key
  - sed -i "s/__HOSTNAME__/$(hostname)/g" /var/www/html/index.html
  - rm -f /etc/nginx/sites-enabled/default
  - ln -sf /etc/nginx/sites-available/technova /etc/nginx/sites-enabled/technova
  - nginx -t
  - systemctl enable nginx
  - systemctl restart nginx
'''

// ---------------------------------------------------------------------
// Availability Set - zastita od kvara pojedinog fizickog racka/hosta
// (99.95% SLA, oporavak u slucaju kvara)
// ---------------------------------------------------------------------
resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-09-01' = {
  name: availabilitySetName
  location: location
  tags: tags
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

// ---------------------------------------------------------------------
// Mrezne kartice - bez javne IP adrese, pristup samo preko Load Balancera
// ---------------------------------------------------------------------
resource nics 'Microsoft.Network/networkInterfaces@2023-11-01' = [for (vmName, i) in vmNames: {
  name: '${namePrefix}-nic${i + 1}-${env}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
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
}]

// ---------------------------------------------------------------------
// Virtualni strojevi
// ---------------------------------------------------------------------
resource vms 'Microsoft.Compute/virtualMachines@2023-09-01' = [for (vmName, i) in vmNames: {
  name: vmName
  location: location
  tags: tags
  identity: {
    // Managed Identity => pristup Key Vaultu i pohrani bez lozinke
    type: 'SystemAssigned'
  }
  properties: {
    availabilitySet: {
      id: availabilitySet.id
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}]

// ---------------------------------------------------------------------
// Azure Monitor Agent - prikupljanje metrika i logova s VM-ova
// ---------------------------------------------------------------------
resource monitorAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for (vmName, i) in vmNames: {
  parent: vms[i]
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}]

// ---------------------------------------------------------------------
// Povezivanje VM-ova s Data Collection Rule-om
// ---------------------------------------------------------------------
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [for (vmName, i) in vmNames: {
  name: 'dcra-vm-insights'
  scope: vms[i]
  properties: {
    description: 'Povezivanje VM-a s TechNova DCR pravilom za prikupljanje performansi'
    dataCollectionRuleId: dcrId
  }
  dependsOn: [
    monitorAgent[i]
  ]
}]

output vm1Name string = vms[0].name
output vm2Name string = vms[1].name
output vmNames array = vmNames
output vmIds array = [for (vmName, i) in vmNames: vms[i].id]
output vmPrincipalIds array = [for (vmName, i) in vmNames: vms[i].identity.principalId]
output vmPrivateIps array = [for (vmName, i) in vmNames: nics[i].properties.ipConfigurations[0].properties.privateIPAddress]
output availabilitySetId string = availabilitySet.id
