<#
.SYNOPSIS
    Korak 3 - deployment kompletne Azure infrastrukture iz Bicep predložaka (Infrastructure as Code).

.DESCRIPTION
    Kreira Resource Group "TechNova-RG" i sve resurse: mrežu s tri segmenta, NSG-ove,
    Load Balancer, dva Ubuntu VM-a, Storage, Key Vault, App Service, AKS, SQL, backup,
    RBAC dodjele, alarme i dashboard.

    Trajanje: 15-25 minuta (najviše traje AKS).

.EXAMPLE
    .\scripts\03-deploy-infra.ps1 -Pregled
    Prikazuje što bi se promijenilo (what-if), bez stvarnog deploymenta.

.EXAMPLE
    .\scripts\03-deploy-infra.ps1

.EXAMPLE
    .\scripts\03-deploy-infra.ps1 -BezAks -BezSql
    Deploy bez Kubernetesa i baze (ušteda kvote i troška).

.EXAMPLE
    .\scripts\03-deploy-infra.ps1 -SVmss -SAppGateway
    Uključuje i VM Scale Set te Application Gateway s WAF-om (znatno skuplje).
#>
[CmdletBinding()]
param(
    [switch]$Pregled,
    [switch]$BezAks,
    [switch]$BezSql,
    [switch]$BezAppService,
    [switch]$BezBackup,
    [switch]$SVmss,
    [switch]$SBastion,
    [switch]$SAppGateway,
    [ValidateSet('B1', 'S1', 'P0v3')][string]$AppServiceSku = 'S1',
    [string]$VelicinaVm
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @(
    'subscriptionId', 'regija', 'alertEmail',
    'devGroupObjectId', 'salesGroupObjectId', 'supportGroupObjectId'
)

$korijen   = Get-ProjektKorijen
$predlozak = Join-Path $korijen 'infra\main.bicep'
$paramFile = Join-Path $korijen 'infra\main.parameters.generated.json'

# Velicina VM-a: parametar > provjerena vrijednost iz Koraka 0 > zadana
if (-not $VelicinaVm) {
    if ($konfig.PSObject.Properties.Name -contains 'velicinaVm' -and -not [string]::IsNullOrWhiteSpace([string]$konfig.velicinaVm)) {
        $VelicinaVm = $konfig.velicinaVm
    } else {
        $VelicinaVm = 'Standard_B2ls_v2'
    }
}

Write-Naslov 'KORAK 3 - DEPLOYMENT INFRASTRUKTURE (Bicep / IaC)'

# ---------------------------------------------------------------------
# Lozinka lokalnog administratora VM-ova
# ---------------------------------------------------------------------
Write-Korak 'Priprema lozinke lokalnog administratora'
$lozinkaDatoteka = Join-Path $korijen 'VM-ADMIN-LOZINKA.txt'

if ($konfig.PSObject.Properties.Name -contains 'vmAdminLozinka' -and -not [string]::IsNullOrWhiteSpace($konfig.vmAdminLozinka)) {
    $vmLozinka = $konfig.vmAdminLozinka
    Write-Info 'Koristim postojeću lozinku iz konfiguracije.'
} else {
    $vmLozinka = New-JakaLozinka -Duljina 22
    Set-TechNovaVrijednost -Kljuc 'vmAdminLozinka' -Vrijednost $vmLozinka | Out-Null
@"
TechNova Solutions - lokalni administrator virtualnih strojeva
==============================================================
Korisnicko ime: azureuser
Lozinka:        $vmLozinka

Ista lozinka pohranjena je i u Azure Key Vault kao tajna 'VmAdminPassword'.
Ova datoteka je u .gitignore.
"@ | Set-Content -Path $lozinkaDatoteka -Encoding UTF8 -Force
    Write-Ok 'Generirana nova lozinka i spremljena u VM-ADMIN-LOZINKA.txt'
}

# ---------------------------------------------------------------------
# Certifikat za Application Gateway (samo ako je uključen)
# ---------------------------------------------------------------------
$pfxBase64 = ''
$pfxLozinka = ''
if ($SAppGateway) {
    Write-Korak 'Generiranje self-signed certifikata za Application Gateway'
    $pfxLozinka = New-JakaLozinka -Duljina 16
    $cert = New-SelfSignedCertificate -DnsName 'technova.local', 'www.technova.local' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(2) `
        -KeyExportPolicy Exportable `
        -KeyLength 2048
    $pfxPutanja = Join-Path $env:TEMP 'technova-appgw.pfx'
    Export-PfxCertificate -Cert $cert -FilePath $pfxPutanja `
        -Password (ConvertTo-SecureString -String $pfxLozinka -Force -AsPlainText) | Out-Null
    $pfxBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pfxPutanja))
    Remove-Item $pfxPutanja -Force -ErrorAction SilentlyContinue
    Remove-Item ("Cert:\CurrentUser\My\" + $cert.Thumbprint) -Force -ErrorAction SilentlyContinue
    Write-Ok 'Certifikat generiran (2048-bit RSA, vrijedi 2 godine).'
}

# ---------------------------------------------------------------------
# Datoteka s parametrima
# ---------------------------------------------------------------------
Write-Korak 'Priprema parametara deploymenta'

$adminIp = ''
if ($konfig.PSObject.Properties.Name -contains 'adminIp' -and $konfig.adminIp) { $adminIp = $konfig.adminIp }

$parametri = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        location             = @{ value = $konfig.regija }
        companyName          = @{ value = $konfig.tvrtka }
        environmentName      = @{ value = $konfig.okruzenje }
        resourceGroupName    = @{ value = $konfig.resourceGroup }
        adminUsername        = @{ value = 'azureuser' }
        vmAdminPassword      = @{ value = $vmLozinka }
        devGroupObjectId     = @{ value = $konfig.devGroupObjectId }
        salesGroupObjectId   = @{ value = $konfig.salesGroupObjectId }
        supportGroupObjectId = @{ value = $konfig.supportGroupObjectId }
        alertEmail           = @{ value = $konfig.alertEmail }
        allowedAdminIp       = @{ value = $adminIp }
        vmSize               = @{ value = $VelicinaVm }
        appServiceSku        = @{ value = $AppServiceSku }
        deployAks            = @{ value = (-not $BezAks) }
        deploySql            = @{ value = (-not $BezSql) }
        deployAppService     = @{ value = (-not $BezAppService) }
        deployBackup         = @{ value = (-not $BezBackup) }
        deployVmss           = @{ value = [bool]$SVmss }
        deployBastion        = @{ value = [bool]$SBastion }
        deployAppGateway     = @{ value = [bool]$SAppGateway }
        appGwPfxBase64       = @{ value = $pfxBase64 }
        appGwPfxPassword     = @{ value = $pfxLozinka }
    }
}

$parametri | ConvertTo-Json -Depth 10 | Set-Content -Path $paramFile -Encoding UTF8 -Force
Write-Ok "Parametri zapisani u infra\main.parameters.generated.json"

Write-Info "Regija:        $($konfig.regija)"
Write-Info "ResourceGroup: $($konfig.resourceGroup)"
Write-Info ("Komponente:    VM x2, LoadBalancer, Storage, KeyVault, Monitor" +
    $(if (-not $BezAppService) { ', AppService' } else { '' }) +
    $(if (-not $BezAks) { ', AKS' } else { '' }) +
    $(if (-not $BezSql) { ', SQL' } else { '' }) +
    $(if (-not $BezBackup) { ', Backup' } else { '' }) +
    $(if ($SVmss) { ', VMSS' } else { '' }) +
    $(if ($SBastion) { ', Bastion' } else { '' }) +
    $(if ($SAppGateway) { ', AppGateway+WAF' } else { '' }))

$imeDeploymenta = "TechNova-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# ---------------------------------------------------------------------
# What-if pregled
# ---------------------------------------------------------------------
if ($Pregled) {
    Write-Korak 'Pregled promjena (what-if) - ništa se ne mijenja'
    Invoke-AzCliZivo -Argumenti @(
        'deployment', 'sub', 'what-if',
        '--name', $imeDeploymenta,
        '--location', $konfig.regija,
        '--template-file', $predlozak,
        '--parameters', "@$paramFile"
    ) | Out-Null
    Write-Naslov 'PREGLED ZAVRŠEN'
    Write-Info 'Za stvarni deployment pokrenite skriptu bez -Pregled.'
    return
}

# ---------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------
Write-Korak "Pokretanje deploymenta '$imeDeploymenta'"
Write-Info 'Očekivano trajanje 15-25 minuta. Ne zatvarajte prozor.'
$start = Get-Date

$kod = Invoke-AzCliZivo -Argumenti @(
    'deployment', 'sub', 'create',
    '--name', $imeDeploymenta,
    '--location', $konfig.regija,
    '--template-file', $predlozak,
    '--parameters', "@$paramFile",
    '--output', 'none'
)

if ($kod -ne 0) {
    Write-Greska 'Deployment nije uspio.'
    Write-Info 'Detalji greške:'
    Invoke-AzCliZivo -Argumenti @(
        'deployment', 'operation', 'sub', 'list', '--name', $imeDeploymenta,
        '--query', "[?properties.provisioningState=='Failed'].{Resurs:properties.targetResource.resourceName, Greska:properties.statusMessage.error.message}",
        '--output', 'table'
    ) | Out-Null
    throw 'Deployment neuspješan - pogledajte poruke iznad.'
}

$trajanje = (Get-Date) - $start
Write-Ok ("Deployment uspješno završen za {0:hh\:mm\:ss}" -f $trajanje)

# ---------------------------------------------------------------------
# Izlazne vrijednosti
# ---------------------------------------------------------------------
Write-Korak 'Dohvat izlaznih vrijednosti'
$izlazi = Invoke-AzCli -Argumenti @('deployment', 'sub', 'show', '--name', $imeDeploymenta, '--query', 'properties.outputs')

$mapa = @{}
foreach ($p in $izlazi.PSObject.Properties) { $mapa[$p.Name] = $p.Value.value }

Set-TechNovaVrijednost -Kljuc 'izlazi'          -Vrijednost $mapa | Out-Null
Set-TechNovaVrijednost -Kljuc 'imeDeploymenta'  -Vrijednost $imeDeploymenta | Out-Null

Write-Host ''
Write-Host '  REZULTAT:' -ForegroundColor Green
foreach ($k in ($mapa.Keys | Sort-Object)) {
    $v = $mapa[$k]
    if ($v -is [array]) { $v = $v -join ', ' }
    Write-Host ("    {0,-24} {1}" -f $k, $v) -ForegroundColor White
}

# ---------------------------------------------------------------------
# Dokaz
# ---------------------------------------------------------------------
$popisResursa = Invoke-AzCli -Argumenti @(
    'resource', 'list', '--resource-group', $konfig.resourceGroup,
    '--query', '[].{Naziv:name, Tip:type, Lokacija:location}', '--output', 'table'
) -Tekstualno

$brojResursa = @(Invoke-AzCli -Argumenti @('resource', 'list', '--resource-group', $konfig.resourceGroup)).Count

Save-Dokaz -Naziv 'ishod2-3-infrastruktura' -Sadrzaj @"
# Dokaz: deployment infrastrukture (IaC)

Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Deployment: $imeDeploymenta
Trajanje: $("{0:hh\:mm\:ss}" -f $trajanje)
Regija: $($konfig.regija)
Resource Group: $($konfig.resourceGroup)
Ukupno resursa: $brojResursa

## Izlazne vrijednosti

$(($mapa.Keys | Sort-Object | ForEach-Object { "- **$_**: $(if ($mapa[$_] -is [array]) { $mapa[$_] -join ', ' } else { $mapa[$_] })" }) -join "`n")

## Svi resursi u TechNova-RG

``````
$popisResursa
``````
"@ | Out-Null

Write-Naslov 'KORAK 3 ZAVRŠEN'
Write-Info "Aplikacija (Load Balancer): $($mapa['aplikacijaUrl'])"
if ($mapa['internaWebAplikacija']) { Write-Info "Interna web aplikacija:     $($mapa['internaWebAplikacija'])" }
Write-Info 'Sljedeći korak:  .\scripts\04-post-deploy.ps1'
