<#
.SYNOPSIS
    Pokreće cijeli lanac: preduvjeti -> identiteti -> Conditional Access -> infrastruktura -> post-konfiguracija -> testovi.

.DESCRIPTION
    Jedna naredba za cjelokupno okruženje. Svaki korak se može pokrenuti i zasebno
    (skripte 00 do 06) ako neki od njih zapne.

.EXAMPLE
    .\scripts\deploy-all.ps1

.EXAMPLE
    .\scripts\deploy-all.ps1 -Regija swedencentral -Email ime@algebra.hr -BezAks
#>
[CmdletBinding()]
param(
    [string]$Regija,
    [string]$Email,
    [switch]$BezAks,
    [switch]$BezSql,
    [switch]$BezAppService,
    [switch]$SVmss,
    [switch]$PostaviAks,
    [switch]$SOpterecenjem,
    [switch]$PreskociIdentitete
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$start = Get-Date

Write-Naslov 'TECHNOVA SOLUTIONS - KOMPLETAN DEPLOYMENT'
Write-Info 'Ukupno očekivano trajanje: 25-40 minuta'

# --- Korak 0 ---
$arg0 = @{}
if ($Regija) { $arg0['Regija'] = $Regija }
if ($Email)  { $arg0['Email']  = $Email }
& (Join-Path $PSScriptRoot '00-preduvjeti.ps1') @arg0
if ($LASTEXITCODE) { throw 'Korak 0 nije uspio.' }

# --- Korak 1 ---
if (-not $PreskociIdentitete) {
    & (Join-Path $PSScriptRoot '01-identiteti.ps1')
}

# --- Korak 2 ---
if (-not $PreskociIdentitete) {
    & (Join-Path $PSScriptRoot '02-conditional-access.ps1')
}

# --- Propagacija identiteta ---
Write-Korak 'Čekanje replikacije Entra ID objekata (90 s)'
Write-Info 'Novokreirane grupe nisu odmah vidljive Azure RBAC servisu.'
Wait-SOdbrojavanjem -Sekunde 90 -Poruka 'Replikacija Entra ID objekata'

# --- Korak 3 ---
$arg3 = @{}
if ($BezAks)        { $arg3['BezAks'] = $true }
if ($BezSql)        { $arg3['BezSql'] = $true }
if ($BezAppService) { $arg3['BezAppService'] = $true }
if ($SVmss)         { $arg3['SVmss'] = $true }
& (Join-Path $PSScriptRoot '03-deploy-infra.ps1') @arg3

# --- Čekanje da cloud-init dovrši instalaciju nginxa ---
Write-Korak 'Čekanje da se web poslužitelji podignu (120 s)'
Wait-SOdbrojavanjem -Sekunde 120 -Poruka 'cloud-init instalira nginx i generira certifikat'

# --- Korak 4 ---
$arg4 = @{}
if ($PostaviAks) { $arg4['PostaviAks'] = $true }
& (Join-Path $PSScriptRoot '04-post-deploy.ps1') @arg4

# --- Korak 5 ---
$arg5 = @{}
if ($SOpterecenjem) { $arg5['SOpterecenjem'] = $true }
& (Join-Path $PSScriptRoot '05-testovi.ps1') @arg5

# --- Prikupljanje dokaza (skripta je opcionalna, nije dio repozitorija) ---
$dokazi = Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence\collect-evidence.ps1'
if (Test-Path $dokazi) {
    & $dokazi
}
else {
    Write-Info 'Skripta evidence\collect-evidence.ps1 nije prisutna - preskacem prikupljanje dokaza.'
}

$trajanje = (Get-Date) - $start
$konfig = Get-TechNovaKonfig

Write-Naslov 'SVE ZAVRŠENO'
Write-Host ("  Ukupno trajanje: {0:hh\:mm\:ss}" -f $trajanje) -ForegroundColor Green
Write-Host ''
Write-Host '  Aplikacija (Load Balancer): ' -NoNewline -ForegroundColor Gray
Write-Host $konfig.izlazi.aplikacijaUrl -ForegroundColor White
Write-Host '  Interna web aplikacija:     ' -NoNewline -ForegroundColor Gray
Write-Host $konfig.izlazi.internaWebAplikacija -ForegroundColor White
Write-Host '  Dashboard:                  ' -NoNewline -ForegroundColor Gray
Write-Host $konfig.izlazi.dashboardNaziv -ForegroundColor White
Write-Host ''
Write-Info 'Dokazi za dokumentaciju: docs\dokazi\'
Write-Info 'Popis screenshotova koje treba snimiti: vidi dokumentaciju projekta.'
Write-Upozorenje 'Nakon prikupljanja dokaza obrišite okruženje:  .\scripts\99-cleanup.ps1'
