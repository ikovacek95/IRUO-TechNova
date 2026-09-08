<#
.SYNOPSIS
    Korak 0 - provjera preduvjeta, prijava na Azure i kreiranje konfiguracije projekta.

.DESCRIPTION
    Provjerava Azure CLI i Bicep, prijavljuje korisnika, odabire pretplatu,
    registrira potrebne resource providere, provjerava kvote i regiju,
    te sprema sve u config.local.json koji koriste ostale skripte.

.EXAMPLE
    .\scripts\00-preduvjeti.ps1

.EXAMPLE
    .\scripts\00-preduvjeti.ps1 -Regija swedencentral -Email ime.prezime@algebra.hr
#>
[CmdletBinding()]
param(
    [string]$Regija,
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$Email,
    [string]$VelicinaVm
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Naslov 'KORAK 0 - PREDUVJETI I PRIJAVA'

# ---------------------------------------------------------------------
# 1. Azure CLI
# ---------------------------------------------------------------------
Write-Korak 'Provjera Azure CLI alata'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Greska 'Azure CLI nije instaliran.'
    Write-Info 'Instalirajte ga naredbom:  winget install -e --id Microsoft.AzureCLI'
    throw 'Azure CLI nedostaje.'
}
$verzija = Invoke-AzCli -Argumenti @('version')
Write-Ok "Azure CLI $($verzija.'azure-cli')"

# ---------------------------------------------------------------------
# 2. Bicep
# ---------------------------------------------------------------------
Write-Korak 'Provjera Bicep prevoditelja'
$bicep = Invoke-AzCli -Argumenti @('bicep', 'version') -Tekstualno -Tiho
if (-not $bicep) {
    Write-Info 'Bicep nije pronađen, instaliram...'
    Invoke-AzCli -Argumenti @('bicep', 'install') | Out-Null
    $bicep = Invoke-AzCli -Argumenti @('bicep', 'version') -Tekstualno
}
Write-Ok ($bicep -replace "`r?`n", ' ')

# ---------------------------------------------------------------------
# 3. Prijava
# ---------------------------------------------------------------------
Write-Korak 'Prijava na Azure'
$racun = Invoke-AzCli -Argumenti @('account', 'show') -Tiho

if (-not $racun -or ($TenantId -and $racun.tenantId -ne $TenantId)) {
    $argPrijava = @('login', '--output', 'none')
    if ($TenantId) { $argPrijava += @('--tenant', $TenantId) }
    Write-Info 'Otvara se preglednik za prijavu...'
    try {
        Invoke-AzCli -Argumenti $argPrijava | Out-Null
    } catch {
        Write-Upozorenje 'Interaktivna prijava nije uspjela, prebacujem se na device code.'
        Invoke-AzCli -Argumenti ($argPrijava + '--use-device-code') | Out-Null
    }
    $racun = Invoke-AzCli -Argumenti @('account', 'show')
}

# ---------------------------------------------------------------------
# 4. Odabir pretplate
# ---------------------------------------------------------------------
if ($SubscriptionId) {
    Invoke-AzCli -Argumenti @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    $racun = Invoke-AzCli -Argumenti @('account', 'show')
}

$pretplate = @(Invoke-AzCli -Argumenti @('account', 'list', '--query', '[?state==`Enabled`]'))
if ($pretplate.Count -gt 1 -and -not $SubscriptionId) {
    Write-Info 'Dostupne pretplate:'
    for ($i = 0; $i -lt $pretplate.Count; $i++) {
        Write-Host ("    [{0}] {1}  ({2})" -f $i, $pretplate[$i].name, $pretplate[$i].id) -ForegroundColor Gray
    }
    $izbor = Read-Host "Odaberite redni broj pretplate (Enter = trenutna '$($racun.name)')"
    if (-not [string]::IsNullOrWhiteSpace($izbor)) {
        Invoke-AzCli -Argumenti @('account', 'set', '--subscription', $pretplate[[int]$izbor].id) | Out-Null
        $racun = Invoke-AzCli -Argumenti @('account', 'show')
    }
}

Write-Ok "Pretplata:  $($racun.name)"
Write-Ok "ID:         $($racun.id)"
Write-Ok "Tenant:     $($racun.tenantId)"
Write-Ok "Prijavljen: $($racun.user.name)"

# ---------------------------------------------------------------------
# 5. Regija
# ---------------------------------------------------------------------
Write-Korak 'Odabir Azure regije'
$dostupne = @(Invoke-AzCli -Argumenti @('account', 'list-locations', '--query', "[?metadata.regionType=='Physical'].name"))

if ($dostupne.Count -eq 0) {
    throw 'Popis regija je prazan. Provjerite prijavu naredbom: az account show'
}
Write-Info "Pretplata ima $($dostupne.Count) dostupnih regija."

# Provjera ogranicava li Azure Policy dopustene regije
$dopusteneP = $null
try {
    $dodjele = @(Invoke-AzCli -Argumenti @('policy', 'assignment', 'list') -Tiho)
    foreach ($d in $dodjele) {
        if ($d.policyDefinitionId -match '/e56962a6-4747-49cd-b67b-bf8b01975c4c$' -and $d.parameters.listOfAllowedLocations.value) {
            $dopusteneP = @($d.parameters.listOfAllowedLocations.value)
            Write-Upozorenje "Azure Policy '$($d.displayName)' ogranicava regije na: $($dopusteneP -join ', ')"
        }
    }
    if (-not $dopusteneP) { Write-Info 'Nema Azure Policyja koji ogranicava regije.' }
} catch {
    Write-Info 'Provjera policyja preskocena.'
}

if ($dopusteneP) { $dostupne = @($dostupne | Where-Object { $dopusteneP -contains $_ }) }

# Interaktivni odabir ako regija nije zadana parametrom
if (-not $Regija) {
    $preporucene = @(
        'westeurope', 'northeurope', 'swedencentral', 'francecentral',
        'germanywestcentral', 'italynorth', 'norwayeast', 'polandcentral',
        'switzerlandnorth', 'uksouth', 'spaincentral'
    )
    $kandidati = @($preporucene | Where-Object { $dostupne -contains $_ })
    if ($kandidati.Count -eq 0) { $kandidati = @($dostupne | Select-Object -First 12) }

    Write-Host ''
    Write-Host '  Dostupne europske regije:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $kandidati.Count; $i++) {
        Write-Host ("    [{0,2}] {1}" -f $i, $kandidati[$i]) -ForegroundColor White
    }
    Write-Host '    [ s] prikazi sve regije' -ForegroundColor DarkGray
    Write-Host ''

    $unos = Read-Host "Odaberite redni broj ili upisite naziv regije (Enter = $($kandidati[0]))"

    if ($unos -eq 's') {
        Write-Host ($dostupne -join ', ') -ForegroundColor Gray
        $unos = Read-Host "Upisite naziv regije (Enter = $($kandidati[0]))"
    }

    if ([string]::IsNullOrWhiteSpace($unos)) {
        $Regija = $kandidati[0]
    } elseif ($unos -match '^\d+$' -and [int]$unos -lt $kandidati.Count) {
        $Regija = $kandidati[[int]$unos]
    } else {
        $Regija = $unos.Trim().ToLower()
    }
}

if ($dostupne -notcontains $Regija) {
    Write-Greska "Regija '$Regija' nije dostupna na ovoj pretplati."
    Write-Info "Dostupne regije: $($dostupne -join ', ')"
    throw "Neispravna regija: $Regija"
}
Write-Ok "Odabrana regija: $Regija"

# ---------------------------------------------------------------------
# 5b. Stvarna provjera regije i velicine VM-a
# ---------------------------------------------------------------------
# 'az account list-locations' navodi regije koje POSTOJE, ali ne i one koje su
# otvorene za vasu pretplatu. Isto vrijedi za velicine VM-a: 'az vm list-skus'
# zna vratiti nepotpun katalog. Jedini pouzdan test je stvarna validacija
# deploymenta, pa je ovdje radimo prije nego potrosimo 20 minuta na Korak 3.
Write-Korak 'Provjera dostupnosti regije i velicine virtualnog stroja'

$probni = Join-Path (Get-ProjektKorijen) 'infra\probe-region.json'
if (-not (Test-Path $probni)) {
    Write-Upozorenje 'Probni predlozak infra\probe-region.json nedostaje - preskacem provjeru.'
} else {
    # Resource Group je besplatna i kasnije je koristi Korak 3
    Invoke-AzCli -Argumenti @('group', 'create', '--name', 'TechNova-RG', '--location', $Regija, '--output', 'none') -Tiho | Out-Null

    function Test-Kombinacija {
        param([string]$Reg, [string]$Velicina)
        $izlaz = Invoke-AzCli -Argumenti @(
            'deployment', 'group', 'validate',
            '--resource-group', 'TechNova-RG',
            '--template-file', $probni,
            '--parameters', "location=$Reg", "vmSize=$Velicina",
            '--output', 'none'
        ) -Tiho
        if ($null -ne $izlaz -or $LASTEXITCODE -eq 0) { return 'OK' }
        return 'NE'
    }

    # Kandidati poredani od najjeftinijeg prema vecem
    $velicine = @(
        'Standard_B2ls_v2',   # 2 vCPU / 4 GB - zadana
        'Standard_B1ms',      # 1 vCPU / 2 GB - klasicna, stedi kvotu
        'Standard_B2s',       # 2 vCPU / 4 GB - klasicna
        'Standard_B2s_v2',    # 2 vCPU / 8 GB
        'Standard_B2as_v2',   # 2 vCPU / 8 GB (AMD)
        'Standard_D2s_v3'     # 2 vCPU / 8 GB
    )
    if ($VelicinaVm) { $velicine = @($VelicinaVm) + @($velicine | Where-Object { $_ -ne $VelicinaVm }) }

    $nadena = $null
    foreach ($v in $velicine) {
        Write-Info "Provjeravam $Regija / $v ..."
        if ((Test-Kombinacija -Reg $Regija -Velicina $v) -eq 'OK') { $nadena = $v; break }
    }

    if ($nadena) {
        Write-Ok "Radna kombinacija: regija $Regija, velicina $nadena"
        Set-TechNovaVrijednost -Kljuc 'velicinaVm' -Vrijednost $nadena | Out-Null
    } else {
        Write-Upozorenje "Nijedna uobicajena velicina VM-a nije dostupna u regiji '$Regija'."
        Write-Info 'Trazim regiju koja radi (ovo moze potrajati par minuta)...'

        $drugeRegije = @('swedencentral', 'northeurope', 'germanywestcentral', 'francecentral', 'uksouth', 'polandcentral', 'italynorth', 'norwayeast') |
            Where-Object { $_ -ne $Regija -and $dostupne -contains $_ }

        :vanjska foreach ($r in $drugeRegije) {
            foreach ($v in $velicine) {
                if ((Test-Kombinacija -Reg $r -Velicina $v) -eq 'OK') {
                    Write-Ok "Pronadeno: regija $r, velicina $v"
                    $Regija = $r
                    $nadena = $v
                    Set-TechNovaVrijednost -Kljuc 'velicinaVm' -Vrijednost $v | Out-Null
                    break vanjska
                }
            }
            Write-Info "  $r - nema dostupnih velicina"
        }

        if (-not $nadena) {
            Write-Greska 'Nijedna regija ne dopusta uobicajene velicine VM-a na ovoj pretplati.'
            Write-Info 'Najcesci uzrok je Free Trial pretplata s ogranicenom listom VM obitelji.'
            Write-Info 'Rjesenja: nadogradnja na Pay-As-You-Go, Azure for Students, ili'
            Write-Info 'deployment bez virtualnih strojeva uz dokumentiranje (zadatak to dopusta).'
        }
    }
}

# ---------------------------------------------------------------------
# 6. Resource provideri
# ---------------------------------------------------------------------
Write-Korak 'Registracija resource providera'
$provideri = @(
    'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault',
    'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.Web',
    'Microsoft.ContainerService', 'Microsoft.Sql', 'Microsoft.RecoveryServices',
    'Microsoft.Portal', 'Microsoft.Security', 'Microsoft.Authorization', 'Microsoft.AlertsManagement',
    # Obavezan za AKS Container Insights (omsagent dodatak). Bez njega deployment
    # klastera pada s MissingSubscriptionRegistration.
    'Microsoft.OperationsManagement'
)
foreach ($p in $provideri) {
    $stanje = Invoke-AzCli -Argumenti @('provider', 'show', '--namespace', $p, '--query', 'registrationState', '--output', 'tsv') -Tekstualno -Tiho
    if ($stanje -ne 'Registered') {
        Write-Info "Pokrecem registraciju: $p"
        Invoke-AzCli -Argumenti @('provider', 'register', '--namespace', $p) -Tiho | Out-Null
    }
}

# Registracija je asinkrona i na novoj pretplati traje 1-5 minuta.
# Bez cekanja bi deployment pao s greskom "MissingSubscriptionRegistration",
# a provjera kvota ispod vratila bi prazan popis.
$kljucni = @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.Insights')
$istek = (Get-Date).AddMinutes(8)
$preostali = @($kljucni)

while ($preostali.Count -gt 0 -and (Get-Date) -lt $istek) {
    $jos = @()
    foreach ($p in $preostali) {
        $stanje = Invoke-AzCli -Argumenti @('provider', 'show', '--namespace', $p, '--query', 'registrationState', '--output', 'tsv') -Tekstualno -Tiho
        if ($stanje -eq 'Registered') { Write-Ok "$p registriran" } else { $jos += $p }
    }
    $preostali = @($jos)
    if ($preostali.Count -gt 0) {
        Write-Progress -Activity 'Cekam registraciju resource providera' -Status ("Preostalo: {0}" -f ($preostali -join ', '))
        Start-Sleep -Seconds 15
    }
}
Write-Progress -Activity 'Cekam registraciju resource providera' -Completed

if ($preostali.Count -gt 0) {
    Write-Upozorenje "Jos nisu registrirani: $($preostali -join ', ')"
    Write-Info 'Registracija se nastavlja u pozadini. Pricekajte par minuta pa provjerite:'
    Write-Info '  az provider list --query "[?registrationState==''Registering''].namespace" -o tsv'
} else {
    Write-Ok 'Svi kljucni resource provideri su registrirani.'
}

# ---------------------------------------------------------------------
# 7. Kvote (studentske pretplate imaju svega 4-6 vCPU)
# ---------------------------------------------------------------------
Write-Korak 'Provjera kvota za virtualne strojeve'
$kvote = @(Invoke-AzCli -Argumenti @('vm', 'list-usage', '--location', $Regija) -Tiho)
$vazne = @($kvote | Where-Object { $_.localName -match 'Total Regional vCPUs|Standard BS Family' })

if ($vazne.Count -eq 0) {
    Write-Upozorenje 'Kvote nije bilo moguce ocitati (Microsoft.Compute se vjerojatno jos registrira).'
    Write-Info 'Provjerite rucno prije deploymenta:'
    Write-Info "  az vm list-usage --location $Regija --output table"
    Write-Info 'Projekt traži 4 vCPU-a: 2x Standard_B1ms (VM-ovi) + 1x Standard_B2s (AKS).'
} else {
    $upozorenje = $false
    foreach ($k in $vazne) {
        $slobodno = [int]$k.limit - [int]$k.currentValue
        Write-Info ("{0}: iskorišteno {1} / {2} (slobodno {3})" -f $k.localName, $k.currentValue, $k.limit, $slobodno)
        if ($slobodno -lt 4) { $upozorenje = $true }
    }
    if ($upozorenje) {
        Write-Upozorenje 'Manje od 4 slobodnih vCPU-a. Projekt traži 4 (2x B1ms za VM-ove + 1x B2s za AKS).'
        Write-Upozorenje 'Rješenje: deployajte bez AKS-a (-BezAks) ili zatražite povećanje kvote u Azure portalu.'
    }
}

# ---------------------------------------------------------------------
# 8. E-mail za alarme
# ---------------------------------------------------------------------
if (-not $Email) {
    $Email = Read-Host 'E-mail adresa za primanje alarma (Action Group)'
}
if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "Neispravna e-mail adresa: $Email"
}

# ---------------------------------------------------------------------
# 9. Javna IP adresa (za firewall pohrane)
# ---------------------------------------------------------------------
Write-Korak 'Otkrivanje vaše javne IP adrese'
$mojaIp = Get-MojaJavnaIp
if ($mojaIp) {
    Write-Ok "Javna IP adresa: $mojaIp (bit će dodana u firewall Storage Accounta)"
} else {
    Write-Upozorenje 'Javnu IP adresu nije bilo moguće utvrditi - firewall pohrane ostaje otvoren (defaultAction=Allow).'
}

# ---------------------------------------------------------------------
# 10. Spremanje konfiguracije
# ---------------------------------------------------------------------
Write-Korak 'Spremanje konfiguracije'
# VAZNO: konfiguracija se DOPUNJUJE, a ne prepisuje. Ponovno pokretanje ovog
# koraka inace bi obrisalo vrijednosti koje spremaju kasniji koraci
# (Object ID-ove Entra grupa, lozinke, izlaze deploymenta).
$noveVrijednosti = [ordered]@{
    tenantId        = $racun.tenantId
    subscriptionId  = $racun.id
    subscriptionIme = $racun.name
    korisnik        = $racun.user.name
    regija          = $Regija
    resourceGroup   = 'TechNova-RG'
    tvrtka          = 'technova'
    okruzenje       = 'prod'
    alertEmail      = $Email
    adminIp         = $mojaIp
    kreirano        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
foreach ($par in $noveVrijednosti.GetEnumerator()) {
    Set-TechNovaVrijednost -Kljuc $par.Key -Vrijednost $par.Value | Out-Null
}
$konfig = Get-TechNovaKonfig
Write-Ok "Konfiguracija spremljena u config.local.json"

Write-Naslov 'KORAK 0 ZAVRŠEN'
Write-Info 'Sljedeći korak:  .\scripts\01-identiteti.ps1'
