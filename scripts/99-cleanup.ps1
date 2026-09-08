<#
.SYNOPSIS
    Potpuno uklanjanje TechNova okruženja - Azure resursi i Entra ID objekti.

.DESCRIPTION
    Briše Resource Group TechNova-RG, trajno uklanja soft-deleted Key Vault,
    briše Conditional Access politike, named location, testne korisnike i grupe,
    proračun te dijagnostičke postavke Entra ID-a.

    Pokrenite tek NAKON što ste prikupili sve screenshotove i dokaze!

.EXAMPLE
    .\scripts\99-cleanup.ps1

.EXAMPLE
    .\scripts\99-cleanup.ps1 -SamoAzure
    Briše samo Azure resurse, a identitete ostavlja.
#>
[CmdletBinding()]
param(
    [switch]$SamoAzure,
    [switch]$BezPotvrde
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @('subscriptionId', 'resourceGroup')
$rg  = $konfig.resourceGroup
$sub = $konfig.subscriptionId

Write-Naslov 'UKLANJANJE TECHNOVA OKRUŽENJA'

if (-not $BezPotvrde) {
    Write-Upozorenje 'Ovo TRAJNO briše:'
    Write-Host "    - Resource Group '$rg' i sve resurse u njoj" -ForegroundColor Yellow
    if (-not $SamoAzure) {
        Write-Host '    - Conditional Access politike CA01-CA04 i named location' -ForegroundColor Yellow
        Write-Host '    - Grupe TechNova-Dev / Sales / Support i testne korisnike' -ForegroundColor Yellow
        Write-Host '    - Break-glass račun' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Upozorenje 'Jeste li prikupili SVE screenshotove za dokumentaciju?'
    $potvrda = Read-Host "Upišite 'OBRISI' za nastavak"
    if ($potvrda -ne 'OBRISI') { Write-Info 'Prekinuto.'; return }
}

# =====================================================================
# 1. Flow logovi (moraju se ukloniti prije brisanja NSG-ova)
# =====================================================================
Write-Korak 'Uklanjanje NSG flow logova'
try {
    $flowLogs = @(Invoke-AzCli -Argumenti @('network', 'watcher', 'flow-log', 'list', '--location', $konfig.regija) -Tiho)
    foreach ($fl in ($flowLogs | Where-Object { $_.name -like 'flowlog-technova*' })) {
        Invoke-AzCli -Argumenti @('network', 'watcher', 'flow-log', 'delete',
            '--location', $konfig.regija, '--name', $fl.name) -Tiho | Out-Null
        Write-Ok "Obrisan flow log: $($fl.name)"
    }
} catch { Write-Info 'Nema flow logova za brisanje.' }

# =====================================================================
# 2. Backup - onemogući zaštitu i obriši točke oporavka
# =====================================================================
Write-Korak 'Uklanjanje zaštite backupa'
try {
    $vault = "$($konfig.tvrtka)-rsv-$($konfig.okruzenje)"
    $stavke = @(Invoke-AzCli -Argumenti @('backup', 'item', 'list', '--resource-group', $rg, '--vault-name', $vault) -Tiho)
    foreach ($s in $stavke) {
        Invoke-AzCli -Argumenti @('backup', 'protection', 'disable',
            '--resource-group', $rg, '--vault-name', $vault,
            '--container-name', $s.properties.containerName,
            '--item-name', $s.properties.friendlyName,
            '--delete-backup-data', 'true', '--yes') -Tiho | Out-Null
        Write-Ok "Backup uklonjen za $($s.properties.friendlyName)"
    }
} catch { Write-Info 'Nema aktivnih backup stavki.' }

# =====================================================================
# 3. Resource Group
# =====================================================================
Write-Korak "Brisanje Resource Grupe '$rg' (5-15 minuta)"
$postoji = Invoke-AzCli -Argumenti @('group', 'exists', '--name', $rg) -Tekstualno -Tiho
if ($postoji -eq 'true') {
    Invoke-AzCli -Argumenti @('group', 'delete', '--name', $rg, '--yes', '--output', 'none') -Tiho | Out-Null
    Write-Ok "Resource Group '$rg' obrisana."
} else {
    Write-Info "Resource Group '$rg' ne postoji."
}

# =====================================================================
# 4. Trajno uklanjanje Key Vaulta (soft-delete)
# =====================================================================
Write-Korak 'Trajno uklanjanje soft-deleted Key Vaultova'
try {
    $obrisani = @(Invoke-AzCli -Argumenti @('keyvault', 'list-deleted', '--resource-type', 'vault',
        '--query', "[?starts_with(name,'$($konfig.tvrtka)-kv')]") -Tiho)
    foreach ($kv in $obrisani) {
        Invoke-AzCli -Argumenti @('keyvault', 'purge', '--name', $kv.name, '--no-wait') -Tiho | Out-Null
        Write-Ok "Key Vault trajno uklonjen: $($kv.name)"
    }
    if ($obrisani.Count -eq 0) { Write-Info 'Nema soft-deleted Key Vaultova.' }
} catch { Write-Info 'Provjera Key Vaultova preskočena.' }

# =====================================================================
# 5. Proračun i dijagnostika Entra ID-a
# =====================================================================
Write-Korak 'Uklanjanje proračuna i dijagnostičkih postavki'
Invoke-ArmRest -Metoda DELETE -Tiho -Url ("https://management.azure.com/subscriptions/{0}/providers/Microsoft.Consumption/budgets/technova-budget-{1}?api-version=2023-05-01" -f $sub, $konfig.okruzenje) | Out-Null
Invoke-ArmRest -Metoda DELETE -Tiho -Url 'https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/technova-entra-to-law?api-version=2017-04-01-preview' | Out-Null
Write-Ok 'Proračun i dijagnostičke postavke uklonjeni.'

if ($SamoAzure) {
    Write-Naslov 'AZURE RESURSI UKLONJENI (identiteti zadržani)'
    return
}

# =====================================================================
# 6. Conditional Access politike i named location
# =====================================================================
Write-Korak 'Brisanje Conditional Access politika'
$graf = 'https://graph.microsoft.com/v1.0'
try {
    $politike = Invoke-GraphRest -Metoda GET -Url "$graf/identity/conditionalAccess/policies" -Tiho
    if ($politike -and $politike.value) {
        foreach ($p in ($politike.value | Where-Object { $_.displayName -like 'CA0*' })) {
            Invoke-GraphRest -Metoda DELETE -Url "$graf/identity/conditionalAccess/policies/$($p.id)" -Tiho | Out-Null
            Write-Ok "Obrisana politika: $($p.displayName)"
        }
    }

    $lokacije = Invoke-GraphRest -Metoda GET -Url "$graf/identity/conditionalAccess/namedLocations" -Tiho
    if ($lokacije -and $lokacije.value) {
        foreach ($l in ($lokacije.value | Where-Object { $_.displayName -like 'TechNova*' })) {
            Invoke-GraphRest -Metoda DELETE -Url "$graf/identity/conditionalAccess/namedLocations/$($l.id)" -Tiho | Out-Null
            Write-Ok "Obrisana lokacija: $($l.displayName)"
        }
    }
} catch { Write-Info 'Conditional Access objekti nisu pronađeni.' }

# =====================================================================
# 7. Korisnici i grupe
# =====================================================================
Write-Korak 'Brisanje testnih korisnika'
$domena = $konfig.domena
foreach ($upn in @("ivan.horvat@$domena", "ana.maric@$domena", "marko.ivic@$domena", "technova-breakglass@$domena")) {
    $u = Invoke-AzCli -Argumenti @('ad', 'user', 'list', '--filter', "userPrincipalName eq '$upn'") -Tiho
    if ($u -and @($u).Count -gt 0) {
        Invoke-AzCli -Argumenti @('ad', 'user', 'delete', '--id', @($u)[0].id) -Tiho | Out-Null
        Write-Ok "Obrisan korisnik: $upn"
    }
}

Write-Korak 'Brisanje grupa'
foreach ($naziv in @('TechNova-Dev', 'TechNova-Sales', 'TechNova-Support')) {
    $g = Invoke-AzCli -Argumenti @('ad', 'group', 'list', '--filter', "displayName eq '$naziv'") -Tiho
    if ($g -and @($g).Count -gt 0) {
        Invoke-AzCli -Argumenti @('ad', 'group', 'delete', '--group', @($g)[0].id) -Tiho | Out-Null
        Write-Ok "Obrisana grupa: $naziv"
    }
}

# =====================================================================
# 8. Lokalne datoteke s tajnama
# =====================================================================
Write-Korak 'Brisanje lokalnih datoteka s lozinkama'
$korijen = Get-ProjektKorijen
foreach ($f in @('BREAK-GLASS-LOZINKA.txt', 'TESTNI-KORISNICI.txt', 'VM-ADMIN-LOZINKA.txt', 'infra\main.parameters.generated.json')) {
    $putanja = Join-Path $korijen $f
    if (Test-Path $putanja) {
        Remove-Item $putanja -Force
        Write-Ok "Obrisano: $f"
    }
}

Write-Naslov 'OKRUŽENJE JE POTPUNO UKLONJENO'
Write-Info 'Provjerite u Azure portalu da nema zaostalih resursa (Cost Management > Cost analysis).'
Write-Info 'config.local.json je zadržan - obrišite ga ručno ako više ne trebate.'
