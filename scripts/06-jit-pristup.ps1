<#
.SYNOPSIS
    Simulacija Just-in-Time (JIT) administrativnog pristupa bez Defender for Servers Plan 2.

.DESCRIPTION
    Pravi Azure JIT VM Access zahtijeva Microsoft Defender for Servers Plan 2 (plaćeno).
    Ova skripta postiže isti sigurnosni učinak besplatno:

      1. SSH port 22 je u NSG-u trajno blokiran s Interneta (pravilo Deny-SSH-From-Internet-JIT).
      2. Skripta na zahtjev dodaje privremeno Allow pravilo na višem prioritetu (300),
         ograničeno isključivo na vašu trenutnu javnu IP adresu.
      3. Nakon isteka odobrenog vremena pravilo se automatski uklanja.

.EXAMPLE
    .\scripts\06-jit-pristup.ps1 -Minuta 60
    Otvara SSH na 60 minuta i zatim ga automatski zatvara.

.EXAMPLE
    .\scripts\06-jit-pristup.ps1 -Zatvori
    Odmah uklanja sva privremena JIT pravila.
#>
[CmdletBinding()]
param(
    [int]$Minuta = 60,
    [switch]$Zatvori,
    [switch]$BezCekanja
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @('resourceGroup', 'izlazi')
$rg     = $konfig.resourceGroup
$nsg    = $konfig.izlazi.nsgFrontend

Write-Naslov 'JUST-IN-TIME ADMINISTRATIVNI PRISTUP'

# ---------------------------------------------------------------------
# Uklanjanje postojećih JIT pravila
# ---------------------------------------------------------------------
function Remove-JitPravila {
    $pravila = @(Invoke-AzCli -Argumenti @('network', 'nsg', 'rule', 'list',
        '--resource-group', $rg, '--nsg-name', $nsg, '--query', "[?starts_with(name,'JIT-')]") -Tiho)

    if ($pravila.Count -eq 0) {
        Write-Info 'Nema aktivnih JIT pravila.'
        return 0
    }
    foreach ($p in $pravila) {
        Invoke-AzCli -Argumenti @('network', 'nsg', 'rule', 'delete',
            '--resource-group', $rg, '--nsg-name', $nsg, '--name', $p.name) -Tiho | Out-Null
        Write-Ok "Uklonjeno pravilo: $($p.name)"
    }
    return $pravila.Count
}

if ($Zatvori) {
    Write-Korak 'Zatvaranje administrativnog pristupa'
    $broj = Remove-JitPravila
    Write-Naslov "PRISTUP ZATVOREN ($broj pravila uklonjeno)"
    return
}

# ---------------------------------------------------------------------
# Otvaranje pristupa
# ---------------------------------------------------------------------
Write-Korak 'Otkrivanje vaše javne IP adrese'
$mojaIp = Get-MojaJavnaIp
if (-not $mojaIp) { throw 'Javnu IP adresu nije bilo moguće utvrditi. Provjerite internetsku vezu.' }
Write-Ok "Vaša javna IP adresa: $mojaIp"

Write-Korak 'Uklanjanje eventualnih starih JIT pravila'
Remove-JitPravila | Out-Null

$istekUtc = (Get-Date).ToUniversalTime().AddMinutes($Minuta)
$nazivPravila = "JIT-SSH-$($mojaIp -replace '\.', '-')"

Write-Korak "Otvaranje SSH pristupa za $mojaIp na $Minuta minuta"
Invoke-AzCli -Argumenti @(
    'network', 'nsg', 'rule', 'create',
    '--resource-group', $rg,
    '--nsg-name', $nsg,
    '--name', $nazivPravila,
    '--priority', '300',
    '--direction', 'Inbound',
    '--access', 'Allow',
    '--protocol', 'Tcp',
    '--source-address-prefixes', $mojaIp,
    '--source-port-ranges', '*',
    '--destination-address-prefixes', '*',
    '--destination-port-ranges', '22',
    '--description', "JIT pristup odobren $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC, istice $($istekUtc.ToString('yyyy-MM-dd HH:mm')) UTC"
) -Tiho | Out-Null

Write-Ok "Pravilo '$nazivPravila' aktivno do $($istekUtc.ToString('HH:mm')) UTC"

$vmovi = @($konfig.izlazi.virtualniStrojevi)
Write-Host ''
Write-Info 'Virtualni strojevi nemaju javnu IP adresu. Za SSH koristite:'
Write-Host ("    az vm run-command invoke -g {0} -n {1} --command-id RunShellScript --scripts `"uptime`"" -f $rg, $vmovi[0]) -ForegroundColor White
Write-Host '  ili preko Azure Bastiona (uključite ga s: .\scripts\03-deploy-infra.ps1 -SBastion)' -ForegroundColor Gray

Save-Dokaz -Naziv 'ishod4-jit-pristup' -Sadrzaj @"
# Dokaz: Just-in-Time administrativni pristup (simulacija)

Vrijeme odobrenja: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Istek: $($istekUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC
Odobrena izvorišna adresa: $mojaIp
NSG: $nsg
Pravilo: $nazivPravila (prioritet 300, Allow TCP 22)

## Model

| Stanje | NSG pravilo | Prioritet | Učinak |
|---|---|---|---|
| Zadano | Deny-SSH-From-Internet-JIT | 3900 | SSH s Interneta blokiran |
| Zadano | Deny-All-Inbound | 4000 | Sve ostalo blokirano |
| Nakon zahtjeva | $nazivPravila | 300 | SSH dopušten samo s $mojaIp |
| Nakon isteka | (pravilo uklonjeno) | - | Vraćeno u blokirano stanje |

## Odnos prema izvornom Azure JIT-u

Microsoft Defender for Servers Plan 2 pruža istu funkcionalnost kroz portal,
uz dodatno: evidenciju odobrenja u Defender for Cloud, integraciju s RBAC-om
(uloga "Security Admin" odobrava zahtjeve) i automatsko zatvaranje porta.
Plan 2 se naplaćuje po poslužitelju mjesečno, pa je u ovom PoC-u zamijenjen
skriptiranom simulacijom identičnog sigurnosnog ishoda.
"@ | Out-Null

if ($BezCekanja) {
    Write-Upozorenje "Pravilo NIJE automatski zatvoreno. Zatvorite ga s:  .\scripts\06-jit-pristup.ps1 -Zatvori"
    return
}

Write-Korak "Automatsko zatvaranje za $Minuta minuta (Ctrl+C prekida čekanje, pravilo tada ostaje otvoreno)"
Wait-SOdbrojavanjem -Sekunde ($Minuta * 60) -Poruka "JIT pristup aktivan - zatvaranje u tijeku"

Write-Korak 'Isteklo vrijeme - zatvaranje pristupa'
Remove-JitPravila | Out-Null
Write-Naslov 'JIT PRISTUP ZATVOREN'
