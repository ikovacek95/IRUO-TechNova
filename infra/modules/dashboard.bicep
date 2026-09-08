metadata description = 'Azure Portal dashboard - vizualizacija kljucnih pokazatelja sustava (Ishod 5).'

param location string
param namePrefix string = 'technova'
param env string = 'prod'
param tags object = {}

param vm1Id string
param vm2Id string
param loadBalancerId string
param appServicePlanId string = ''

var dashboardName = '${namePrefix}-dashboard-${env}'

resource dashboard 'Microsoft.Portal/dashboards@2020-09-01-preview' = {
  name: dashboardName
  location: location
  tags: union(tags, {
    'hidden-title': 'TechNova Solutions - Pregled sustava'
  })
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          // --- Naslovna kartica ---
          {
            position: {
              x: 0
              y: 0
              colSpan: 12
              rowSpan: 2
            }
            metadata: any({
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  settings: {
                    content: '## TechNova Solutions d.o.o. - Azure produkcijsko okruzenje\nStatus racunalnih resursa, mreznog balansiranja i web usluga. Resource Group: **TechNova-RG**'
                    title: 'TechNova - operativni pregled'
                    subtitle: 'Azure Monitor'
                    markdownSource: 1
                  }
                }
              }
            })
          }
          // --- CPU VM1 i VM2 ---
          {
            position: {
              x: 0
              y: 2
              colSpan: 6
              rowSpan: 4
            }
            metadata: any({
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: []
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: vm1Id
                          }
                          name: 'Percentage CPU'
                          aggregationType: 4
                          namespace: 'microsoft.compute/virtualmachines'
                          metricVisualization: {
                            displayName: 'CPU - technova-vm1-prod'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: vm2Id
                          }
                          name: 'Percentage CPU'
                          aggregationType: 4
                          namespace: 'microsoft.compute/virtualmachines'
                          metricVisualization: {
                            displayName: 'CPU - technova-vm2-prod'
                          }
                        }
                      ]
                      title: 'Opterecenje procesora virtualnih strojeva (%)'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                      }
                      timespan: {
                        relative: {
                          duration: 86400000
                        }
                      }
                    }
                  }
                }
              }
            })
          }
          // --- Dostupnost Load Balancera ---
          {
            position: {
              x: 6
              y: 2
              colSpan: 6
              rowSpan: 4
            }
            metadata: any({
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: []
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: loadBalancerId
                          }
                          name: 'VipAvailability'
                          aggregationType: 4
                          namespace: 'microsoft.network/loadbalancers'
                          metricVisualization: {
                            displayName: 'Dostupnost podatkovne putanje'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: loadBalancerId
                          }
                          name: 'DipAvailability'
                          aggregationType: 4
                          namespace: 'microsoft.network/loadbalancers'
                          metricVisualization: {
                            displayName: 'Zdravlje backend instanci'
                          }
                        }
                      ]
                      title: 'Dostupnost Load Balancera (%)'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                      }
                      timespan: {
                        relative: {
                          duration: 86400000
                        }
                      }
                    }
                  }
                }
              }
            })
          }
          // --- Mrezni promet kroz Load Balancer ---
          {
            position: {
              x: 0
              y: 6
              colSpan: 6
              rowSpan: 4
            }
            metadata: any({
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: []
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: loadBalancerId
                          }
                          name: 'ByteCount'
                          aggregationType: 1
                          namespace: 'microsoft.network/loadbalancers'
                          metricVisualization: {
                            displayName: 'Preneseni bajtovi'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: loadBalancerId
                          }
                          name: 'SYNCount'
                          aggregationType: 1
                          namespace: 'microsoft.network/loadbalancers'
                          metricVisualization: {
                            displayName: 'Novi TCP dolasci (SYN)'
                          }
                        }
                      ]
                      title: 'Mrezni promet kroz Load Balancer'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                      }
                      timespan: {
                        relative: {
                          duration: 86400000
                        }
                      }
                    }
                  }
                }
              }
            })
          }
          // --- App Service plan ---
          {
            position: {
              x: 6
              y: 6
              colSpan: 6
              rowSpan: 4
            }
            metadata: any({
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: []
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: empty(appServicePlanId) ? [] : [
                        {
                          resourceMetadata: {
                            id: appServicePlanId
                          }
                          name: 'CpuPercentage'
                          aggregationType: 4
                          namespace: 'microsoft.web/serverfarms'
                          metricVisualization: {
                            displayName: 'CPU App Service plana'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: appServicePlanId
                          }
                          name: 'MemoryPercentage'
                          aggregationType: 4
                          namespace: 'microsoft.web/serverfarms'
                          metricVisualization: {
                            displayName: 'Memorija App Service plana'
                          }
                        }
                      ]
                      title: 'Interna web aplikacija - iskoristenost (%)'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                      }
                      timespan: {
                        relative: {
                          duration: 86400000
                        }
                      }
                    }
                  }
                }
              }
            })
          }
        ]
      }
    ]
    metadata: {
      model: {
        timeRange: {
          type: 'MsPortalFx.Composition.Configuration.ValueTypes.TimeRange'
          value: {
            relative: {
              duration: 24
              timeUnit: 1
            }
          }
        }
      }
    }
  }
}

output dashboardName string = dashboard.name
output dashboardId string = dashboard.id
