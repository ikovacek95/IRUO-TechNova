metadata description = 'Azure Kubernetes Service - priprema za buducu migraciju aplikacije na kontejnere (Ishod 3).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

@description('Resource ID Log Analytics Workspace-a za Container Insights')
param logAnalyticsWorkspaceId string

@description('Object ID Entra ID grupe koja dobiva administratorska prava nad klasterom')
param adminGroupObjectId string

@description('Velicina cvorova. Standard_B2s_v2 = 2 vCPU / 8 GB (minimum za AKS system pool).')
param nodeVmSize string = 'Standard_B2s_v2'

param nodeCountMin int = 1
param nodeCountMax int = 3

var clusterName = '${namePrefix}-aks-${env}'

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusterName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${namePrefix}-k8s-${env}'
    enableRBAC: true
    // Autentikacija preko Entra ID + autorizacija preko Azure RBAC
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: [
        adminGroupObjectId
      ]
      tenantID: subscription().tenantId
    }
    // Lokalni admin racun ostaje omogucen radi jednostavnijeg pristupa u PoC fazi.
    // U produkciji postaviti na true (samo Entra ID pristup).
    disableLocalAccounts: false
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        vmSize: nodeVmSize
        count: nodeCountMin
        osDiskSizeGB: 32
        osDiskType: 'Managed'
        // Cluster Autoscaler - automatsko skaliranje broja cvorova
        enableAutoScaling: true
        minCount: nodeCountMin
        maxCount: nodeCountMax
        maxPods: 60
      }
    ]
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
    }
    addonProfiles: {
      // Container Insights - metrike i logovi kontejnera u Log Analytics
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
      }
      azurepolicy: {
        enabled: false
      }
    }
  }
}

resource aksDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: aks
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'kube-apiserver', enabled: true }
      { category: 'kube-controller-manager', enabled: true }
      { category: 'kube-audit-admin', enabled: true }
      { category: 'cluster-autoscaler', enabled: true }
      { category: 'guard', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output aksClusterName string = aks.name
output aksFqdn string = aks.properties.fqdn
output aksId string = aks.id
output aksNodeResourceGroup string = aks.properties.nodeResourceGroup
