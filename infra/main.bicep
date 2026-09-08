metadata description = 'TechNova Solutions d.o.o. - kompletno Azure okruzenje (Ishodi 1-5). Deploya se na razini pretplate jer sam kreira Resource Group.'

targetScope = 'subscription'

// =====================================================================
// PARAMETRI
// =====================================================================
@description('Azure regija. Sve se deploya u JEDNU regiju (tehnicko ogranicenje projekta).')
param location string = 'westeurope'

@description('Naziv tvrtke - prvi dio standarda imenovanja <tvrtka>-<resurs>-<okruzenje>')
param companyName string = 'technova'

@description('Oznaka okruzenja - treci dio standarda imenovanja')
param environmentName string = 'prod'

@description('Naziv Resource Grupe (tehnicko ogranicenje: TechNova-RG)')
param resourceGroupName string = 'TechNova-RG'

@description('Lokalno administratorsko korisnicko ime na Ubuntu VM-ovima')
param adminUsername string = 'azureuser'

@description('Lozinka lokalnog administratora - pohranjuje se u Key Vault')
@secure()
param vmAdminPassword string

@description('Object ID Entra ID grupe TechNova-Dev')
param devGroupObjectId string

@description('Object ID Entra ID grupe TechNova-Sales')
param salesGroupObjectId string

@description('Object ID Entra ID grupe TechNova-Support')
param supportGroupObjectId string

@description('E-mail adresa za primanje alarma')
param alertEmail string

@description('Javna IP adresa administratora (dodaje se u firewall pohrane)')
param allowedAdminIp string = ''

@description('Velicina virtualnih strojeva')
param vmSize string = 'Standard_B2ls_v2'

@description('SKU App Service plana. S1 je minimum za automatsko skaliranje.')
@allowed([
  'B1'
  'S1'
  'P0v3'
])
param appServiceSku string = 'S1'

// --- Prekidaci za pojedine komponente (kontrola troska) ---
@description('Kubernetes klaster (~30 EUR/mj za jedan B2s cvor)')
param deployAks bool = true

@description('Azure SQL Database (~5 EUR/mj, Basic)')
param deploySql bool = true

@description('App Service + automatsko skaliranje (~62 EUR/mj na S1)')
param deployAppService bool = true

@description('Recovery Services Vault i backup politika')
param deployBackup bool = true

@description('VM Scale Set s autoscaleom (dodatni trosak VM instanci)')
param deployVmss bool = false

@description('Azure Bastion (~130 EUR/mj) - po defaultu iskljuceno, samo dokumentirano')
param deployBastion bool = false

@description('Application Gateway + WAF (~250 EUR/mj) - po defaultu iskljuceno, samo dokumentirano')
param deployAppGateway bool = false

@description('Base64 PFX certifikat za Application Gateway')
@secure()
param appGwPfxBase64 string = ''

@description('Lozinka PFX certifikata za Application Gateway')
@secure()
param appGwPfxPassword string = ''

// =====================================================================
// ZAJEDNICKE OZNAKE
// =====================================================================
var commonTags = {
  Projekt: 'TechNova-Azure-Migracija'
  Tvrtka: 'TechNova Solutions d.o.o.'
  Okruzenje: environmentName
  UpravljanoS: 'Bicep-IaC'
  Kolegij: 'Implementacija racunarstva u oblaku'
}

// =====================================================================
// RESOURCE GROUP
// =====================================================================
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

// =====================================================================
// 1. NADZOR (prvi jer svi ostali moduli salju logove u Log Analytics)
// =====================================================================
module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'deploy-monitoring'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    alertEmail: alertEmail
  }
}

// =====================================================================
// 2. MREZNA ARHITEKTURA (Frontend / Backend / Management)
// =====================================================================
module network 'modules/network.bicep' = {
  scope: rg
  name: 'deploy-network'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// =====================================================================
// 3. POHRANA (objektna + dijeljeni dokumenti, passwordless)
// =====================================================================
module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'deploy-storage'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    frontendSubnetId: network.outputs.frontendSubnetId
    backendSubnetId: network.outputs.backendSubnetId
    allowedAdminIp: allowedAdminIp
    networkDefaultAction: empty(allowedAdminIp) ? 'Allow' : 'Deny'
  }
}

// =====================================================================
// 4. KEY VAULT
// =====================================================================
module keyvault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'deploy-keyvault'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    vmAdminPassword: vmAdminPassword
  }
}

// =====================================================================
// 5. LOAD BALANCER
// =====================================================================
module loadbalancer 'modules/loadbalancer.bicep' = {
  scope: rg
  name: 'deploy-loadbalancer'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// =====================================================================
// 6. VIRTUALNI STROJEVI (technova-vm1-prod, technova-vm2-prod)
// =====================================================================
module compute 'modules/compute.bicep' = {
  scope: rg
  name: 'deploy-compute'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    subnetId: network.outputs.frontendSubnetId
    backendPoolId: loadbalancer.outputs.backendPoolId
    dcrId: monitoring.outputs.dcrId
    adminUsername: adminUsername
    adminPassword: vmAdminPassword
    vmSize: vmSize
  }
}

// =====================================================================
// 7. VM SCALE SET (opcionalno)
// =====================================================================
module vmss 'modules/vmss.bicep' = if (deployVmss) {
  scope: rg
  name: 'deploy-vmss'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    subnetId: network.outputs.frontendSubnetId
    backendPoolId: loadbalancer.outputs.backendPoolId
    healthProbeId: loadbalancer.outputs.healthProbeId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    adminUsername: adminUsername
    adminPassword: vmAdminPassword
  }
}

// =====================================================================
// 8. APP SERVICE (interna web aplikacija + autoscale)
// =====================================================================
module appService 'modules/appservice.bicep' = if (deployAppService) {
  scope: rg
  name: 'deploy-appservice'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    sku: appServiceSku
  }
}

// =====================================================================
// 9. KUBERNETES
// =====================================================================
module aks 'modules/aks.bicep' = if (deployAks) {
  scope: rg
  name: 'deploy-aks'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    adminGroupObjectId: devGroupObjectId
  }
}

// =====================================================================
// 10. AZURE SQL (Backend segment, Entra-only autentikacija)
// =====================================================================
module sql 'modules/sql.bicep' = if (deploySql) {
  scope: rg
  name: 'deploy-sql'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    backendSubnetId: network.outputs.backendSubnetId
    adminGroupObjectId: devGroupObjectId
  }
}

// =====================================================================
// 11. BACKUP
// =====================================================================
module backup 'modules/backup.bicep' = if (deployBackup) {
  scope: rg
  name: 'deploy-backup'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
  }
}

// =====================================================================
// 12. RBAC - dodjela uloga grupama odjela i managed identityjima
// =====================================================================
var workloadPrincipalIds = deployAppService ? [
  compute.outputs.vmPrincipalIds[0]
  compute.outputs.vmPrincipalIds[1]
  appService!.outputs.webAppPrincipalId
] : [
  compute.outputs.vmPrincipalIds[0]
  compute.outputs.vmPrincipalIds[1]
]

module rbac 'modules/rbac.bicep' = {
  scope: rg
  name: 'deploy-rbac'
  params: {
    namePrefix: companyName
    devGroupObjectId: devGroupObjectId
    salesGroupObjectId: salesGroupObjectId
    supportGroupObjectId: supportGroupObjectId
    storageAccountName: storage.outputs.storageAccountName
    keyVaultName: keyvault.outputs.keyVaultName
    workloadPrincipalIds: workloadPrincipalIds
  }
}

// =====================================================================
// 13. ALARMI I OBAVIJESTI
// =====================================================================
module alerts 'modules/alerts.bicep' = {
  scope: rg
  name: 'deploy-alerts'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    actionGroupId: monitoring.outputs.actionGroupId
    vmIds: compute.outputs.vmIds
    loadBalancerId: loadbalancer.outputs.loadBalancerId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    webAppId: deployAppService ? appService!.outputs.webAppId : ''
  }
}

// =====================================================================
// 14. DASHBOARD
// =====================================================================
module dashboard 'modules/dashboard.bicep' = {
  scope: rg
  name: 'deploy-dashboard'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    vm1Id: compute.outputs.vmIds[0]
    vm2Id: compute.outputs.vmIds[1]
    loadBalancerId: loadbalancer.outputs.loadBalancerId
    appServicePlanId: deployAppService ? appService!.outputs.appServicePlanId : ''
  }
}

// =====================================================================
// 15. BASTION (opcionalno)
// =====================================================================
module bastion 'modules/bastion.bicep' = if (deployBastion) {
  scope: rg
  name: 'deploy-bastion'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    bastionSubnetId: network.outputs.bastionSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// =====================================================================
// 16. APPLICATION GATEWAY + WAF (opcionalno)
// =====================================================================
module appGateway 'modules/appgateway.bicep' = if (deployAppGateway) {
  scope: rg
  name: 'deploy-appgateway'
  params: {
    location: location
    namePrefix: companyName
    env: environmentName
    tags: commonTags
    appGwSubnetId: network.outputs.appGwSubnetId
    backendIpAddresses: compute.outputs.vmPrivateIps
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    pfxBase64: appGwPfxBase64
    pfxPassword: appGwPfxPassword
  }
}

// =====================================================================
// IZLAZNE VRIJEDNOSTI
// =====================================================================
output resourceGroup string = rg.name
output regija string = location
output aplikacijaUrl string = loadbalancer.outputs.appUrlHttps
output loadBalancerIp string = loadbalancer.outputs.publicIpAddress
output loadBalancerFqdn string = loadbalancer.outputs.fqdn
output internaWebAplikacija string = deployAppService ? appService!.outputs.webAppUrl : 'nije deployano'
output storageAccount string = storage.outputs.storageAccountName
output fileShare string = storage.outputs.fileShareName
output keyVault string = keyvault.outputs.keyVaultName
output logAnalyticsWorkspace string = monitoring.outputs.workspaceName
output aksKlaster string = deployAks ? aks!.outputs.aksClusterName : 'nije deployano'
output sqlServer string = deploySql ? sql!.outputs.sqlServerFqdn : 'nije deployano'
output backupVault string = deployBackup ? backup!.outputs.vaultName : 'nije deployano'
output dashboardNaziv string = dashboard.outputs.dashboardName
output nsgFrontend string = network.outputs.nsgFrontendName
output flowLogStorage string = storage.outputs.flowLogStorageName
output virtualniStrojevi array = compute.outputs.vmNames
