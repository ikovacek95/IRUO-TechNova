<#
.SYNOPSIS
    Korak 5 - automatizirani testovi mrežne učinkovitosti, sigurnosti i performansi VM-ova.

.DESCRIPTION
    Pokriva bodovne stavke:
      Ishod 3 - "Testiranje performansi virtualnih strojeva"
      Ishod 3 - "Aktivan nadzor i prikupljanje metrika virtualnih strojeva"
      Ishod 4 - "Dokumentirani testovi mrežne učinkovitosti i sigurnosti"

    Rezultati se zapisuju u docs\dokazi\ kao markdown izvještaj spreman za kopiranje
    u dokumentaciju.

.EXAMPLE
    .\scripts\05-testovi.ps1
    Pokreće sve testove osim opterećenja procesora.

.EXAMPLE
    .\scripts\05-testovi.ps1 -SOpterecenjem
    Uključuje i stress test (traje ~10 minuta, dokazuje alarm CPU > 80%).
#>
[CmdletBinding()]
param(
    [int]$BrojZahtjeva = 40,
    [switch]$SOpterecenjem,
    [int]$TrajanjeOpterecenjaSek = 600
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @('resourceGroup', 'izlazi')
$izlazi = $konfig.izlazi
$rg     = $konfig.resourceGroup
$url    = $izlazi.aplikacijaUrl
$ip     = $izlazi.loadBalancerIp

Write-Naslov 'KORAK 5 - TESTIRANJE'
Write-Info "Ciljna adresa: $url  ($ip)"

$rezultati = New-Object System.Collections.ArrayList
function Dodaj-Rezultat {
    param([string]$Test, [string]$Ocekivano, [string]$Dobiveno, [bool]$Prolaz)
    [void]$rezultati.Add([pscustomobject]@{
        Test = $Test; Ocekivano = $Ocekivano; Dobiveno = $Dobiveno
        Status = $(if ($Prolaz) { 'PROLAZ' } else { 'PAD' })
    })
    if ($Prolaz) { Write-Ok "$Test -> $Dobiveno" } else { Write-Greska "$Test -> $Dobiveno (očekivano: $Ocekivano)" }
}

# =====================================================================
# TEST 1 - Dostupnost preko HTTPS-a
# =====================================================================
Write-Korak 'Test 1: dostupnost aplikacije preko HTTPS-a'
try {
    $odg = Invoke-WebZahtjev -Url $url
    Dodaj-Rezultat -Test 'HTTPS dostupnost' -Ocekivano 'HTTP 200' -Dobiveno "HTTP $($odg.StatusCode)" -Prolaz ($odg.StatusCode -eq 200)
} catch {
    Dodaj-Rezultat -Test 'HTTPS dostupnost' -Ocekivano 'HTTP 200' -Dobiveno $_.Exception.Message -Prolaz $false
}

# =====================================================================
# TEST 2 - Preusmjeravanje HTTP -> HTTPS
# =====================================================================
Write-Korak 'Test 2: prisilno preusmjeravanje s HTTP-a na HTTPS'
$redirect = Get-HttpStatus -Url "http://$($izlazi.loadBalancerFqdn)/"
$opis = "HTTP $($redirect.Kod)"
if ($redirect.Lokacija) { $opis += " -> $($redirect.Lokacija)" }
Dodaj-Rezultat -Test 'HTTP -> HTTPS redirect' -Ocekivano 'HTTP 301 na https://' -Dobiveno $opis `
    -Prolaz ($redirect.Kod -eq 301 -and $redirect.Lokacija -like 'https://*')

# =====================================================================
# TEST 3 - Health endpoint Load Balancera
# =====================================================================
Write-Korak 'Test 3: health endpoint koji koristi Load Balancer probe'
try {
    $odg = Invoke-WebZahtjev -Url "http://$($izlazi.loadBalancerFqdn)/health"
    $tijelo = (Get-TijeloOdgovora -Odgovor $odg).Trim()
    Dodaj-Rezultat -Test 'Health probe /health' -Ocekivano 'OK' -Dobiveno $tijelo -Prolaz ($tijelo -eq 'OK')
} catch {
    Dodaj-Rezultat -Test 'Health probe /health' -Ocekivano 'OK' -Dobiveno $_.Exception.Message -Prolaz $false
}

# =====================================================================
# TEST 4 - TLS parametri
# =====================================================================
Write-Korak 'Test 4: parametri TLS veze'
$tlsInfo = 'nije utvrđeno'
try {
    $tls = Get-TlsPodaci -Posluzitelj $izlazi.loadBalancerFqdn
    $tlsInfo = "$($tls.Protokol), certifikat: $($tls.Subjekt), vrijedi do $($tls.VrijediDo)"
    Dodaj-Rezultat -Test 'TLS verzija' -Ocekivano 'TLS 1.2 ili 1.3' -Dobiveno $tls.Protokol `
        -Prolaz ($tls.Protokol -match 'Tls12|Tls13')
} catch {
    Dodaj-Rezultat -Test 'TLS verzija' -Ocekivano 'TLS 1.2 ili 1.3' -Dobiveno $_.Exception.Message -Prolaz $false
}

# =====================================================================
# TEST 5 - Raspodjela prometa između oba VM-a (balansiranje)
# =====================================================================
Write-Korak "Test 5: raspodjela $BrojZahtjeva zahtjeva između virtualnih strojeva"
$posluzitelji = @{}
$latencije = New-Object System.Collections.ArrayList

for ($i = 1; $i -le $BrojZahtjeva; $i++) {
    try {
        $sat = [System.Diagnostics.Stopwatch]::StartNew()
        $odg = Invoke-WebZahtjev -Url $url -Timeout 15
        $sat.Stop()
        [void]$latencije.Add($sat.Elapsed.TotalMilliseconds)

        if ((Get-TijeloOdgovora -Odgovor $odg) -match 'Posluzuje:\s*([A-Za-z0-9\-]+)') {
            $host_ = $Matches[1]
            if ($posluzitelji.ContainsKey($host_)) { $posluzitelji[$host_]++ } else { $posluzitelji[$host_] = 1 }
        }
    } catch { }
    Write-Progress -Activity 'Slanje zahtjeva' -Status "$i / $BrojZahtjeva" -PercentComplete (($i / $BrojZahtjeva) * 100)
}
Write-Progress -Activity 'Slanje zahtjeva' -Completed

$raspodjela = ($posluzitelji.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join ', '
Dodaj-Rezultat -Test 'Balansiranje između 2 VM-a' -Ocekivano 'oba VM-a poslužuju promet' `
    -Dobiveno $(if ($raspodjela) { $raspodjela } else { 'nema odgovora' }) -Prolaz ($posluzitelji.Keys.Count -ge 2)

# =====================================================================
# TEST 6 - Latencija
# =====================================================================
Write-Korak 'Test 6: latencija odgovora'
if ($latencije.Count -gt 0) {
    $sortirano = $latencije | Sort-Object
    $stat = [pscustomobject]@{
        Min  = [math]::Round(($latencije | Measure-Object -Minimum).Minimum, 1)
        Prosjek = [math]::Round(($latencije | Measure-Object -Average).Average, 1)
        P95  = [math]::Round($sortirano[[math]::Floor($sortirano.Count * 0.95) - 1], 1)
        Max  = [math]::Round(($latencije | Measure-Object -Maximum).Maximum, 1)
        Uspjesnih = $latencije.Count
    }
    Dodaj-Rezultat -Test 'Latencija (prosjek)' -Ocekivano '< 1000 ms' -Dobiveno "$($stat.Prosjek) ms" -Prolaz ($stat.Prosjek -lt 1000)
    Write-Info "min $($stat.Min) ms | prosjek $($stat.Prosjek) ms | p95 $($stat.P95) ms | max $($stat.Max) ms | uspješnih $($stat.Uspjesnih)/$BrojZahtjeva"
} else {
    $stat = $null
    Dodaj-Rezultat -Test 'Latencija (prosjek)' -Ocekivano '< 1000 ms' -Dobiveno 'nema uspješnih zahtjeva' -Prolaz $false
}

# =====================================================================
# TEST 7 - Sigurnost: koji su portovi otvoreni prema Internetu
# =====================================================================
Write-Korak 'Test 7: provjera otvorenih portova s Interneta'
foreach ($port in @(443, 80, 22, 3389, 1433)) {
    $otvoren = $false
    try {
        $klijent = New-Object System.Net.Sockets.TcpClient
        $veza = $klijent.BeginConnect($ip, $port, $null, $null)
        $otvoren = $veza.AsyncWaitHandle.WaitOne(3000, $false) -and $klijent.Connected
        $klijent.Close()
    } catch { $otvoren = $false }

    $ocekivanoOtvoren = ($port -in @(443, 80))
    Dodaj-Rezultat -Test "Port $port s Interneta" `
        -Ocekivano $(if ($ocekivanoOtvoren) { 'otvoren' } else { 'zatvoren' }) `
        -Dobiveno $(if ($otvoren) { 'otvoren' } else { 'zatvoren' }) `
        -Prolaz ($otvoren -eq $ocekivanoOtvoren)
}

# =====================================================================
# TEST 8 - Provjera NSG pravila preko Network Watchera (IP flow verify)
# =====================================================================
Write-Korak 'Test 8: verifikacija NSG pravila (Network Watcher IP flow verify)'
$vmovi = @($izlazi.virtualniStrojevi)
$privatneIp = @{}
foreach ($vm in $vmovi) {
    $adr = Invoke-AzCli -Argumenti @('vm', 'list-ip-addresses', '--resource-group', $rg, '--name', $vm,
        '--query', '[0].virtualMachine.network.privateIpAddresses[0]', '--output', 'tsv') -Tekstualno -Tiho
    if ($adr) { $privatneIp[$vm] = $adr }
}

$ipFlowRezultati = New-Object System.Collections.ArrayList
if ($privatneIp.Count -gt 0) {
    $prviVm = $vmovi[0]
    $prvaIp = $privatneIp[$prviVm]

    $scenariji = @(
        @{ Opis = 'HTTPS (443) s Interneta';        Port = '443';  Smjer = 'Inbound';  Udaljeni = '203.0.113.10:51000'; Ocekivano = 'Allow' }
        @{ Opis = 'SSH (22) s Interneta';           Port = '22';   Smjer = 'Inbound';  Udaljeni = '203.0.113.10:51001'; Ocekivano = 'Deny'  }
        @{ Opis = 'RDP (3389) s Interneta';         Port = '3389'; Smjer = 'Inbound';  Udaljeni = '203.0.113.10:51002'; Ocekivano = 'Deny'  }
        @{ Opis = 'SSH (22) iz Management segmenta'; Port = '22';  Smjer = 'Inbound';  Udaljeni = '10.10.3.4:51003';    Ocekivano = 'Allow' }
    )

    foreach ($s in $scenariji) {
        try {
            $r = Invoke-AzCli -Argumenti @(
                'network', 'watcher', 'test-ip-flow',
                '--resource-group', $rg,
                '--vm', $prviVm,
                '--direction', $s.Smjer,
                '--protocol', 'TCP',
                '--local', "$prvaIp`:$($s.Port)",
                '--remote', $s.Udaljeni
            ) -Tiho

            $pristup = if ($r) { $r.access } else { 'nepoznato' }
            $pravilo = if ($r) { $r.ruleName } else { '-' }
            [void]$ipFlowRezultati.Add([pscustomobject]@{ Scenarij = $s.Opis; Pristup = $pristup; Pravilo = $pravilo; Ocekivano = $s.Ocekivano })
            Dodaj-Rezultat -Test "NSG: $($s.Opis)" -Ocekivano $s.Ocekivano -Dobiveno "$pristup ($pravilo)" -Prolaz ($pristup -eq $s.Ocekivano)
        } catch {
            Write-Upozorenje "IP flow verify nije uspio za '$($s.Opis)': $($_.Exception.Message)"
        }
    }
}

# =====================================================================
# TEST 9 - Opterećenje procesora i provjera alarma
# =====================================================================
$metrikeTablica = ''
$alarmiTablica = ''
if ($SOpterecenjem) {
    Write-Korak "Test 9: opterećenje procesora ($TrajanjeOpterecenjaSek s) na oba VM-a"
    $skripta = "command -v stress-ng >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq stress-ng); setsid nohup stress-ng --cpu 2 --cpu-method matrixprod --timeout ${TrajanjeOpterecenjaSek}s >/dev/null 2>&1 </dev/null & echo pokrenuto"

    foreach ($vm in $vmovi) {
        try {
            Invoke-AzCli -Argumenti @('vm', 'run-command', 'invoke', '--resource-group', $rg, '--name', $vm,
                '--command-id', 'RunShellScript', '--scripts', $skripta) -Tiho | Out-Null
            Write-Ok "Opterećenje pokrenuto na $vm"
        } catch {
            Write-Upozorenje "Opterećenje nije pokrenuto na ${vm}: $($_.Exception.Message)"
        }
    }

    $cekanje = $TrajanjeOpterecenjaSek + 120
    Write-Info "Čekam $cekanje s da Azure Monitor prikupi metrike i evaluira alarm..."
    Wait-SOdbrojavanjem -Sekunde $cekanje -Poruka 'Prikupljanje metrika opterećenja'

    Write-Korak 'Očitavanje metrika procesora'
    $pocetak = (Get-Date).ToUniversalTime().AddMinutes(-([math]::Ceiling($cekanje / 60)) - 2).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $redovi = New-Object System.Collections.ArrayList

    foreach ($vm in $vmovi) {
        $vmId = Invoke-AzCli -Argumenti @('vm', 'show', '--resource-group', $rg, '--name', $vm, '--query', 'id', '--output', 'tsv') -Tekstualno
        $m = Invoke-AzCli -Argumenti @('monitor', 'metrics', 'list', '--resource', $vmId,
            '--metric', 'Percentage CPU', '--interval', 'PT1M', '--aggregation', 'Average', 'Maximum',
            '--start-time', $pocetak) -Tiho

        if ($m -and $m.value) {
            $tocke = @($m.value[0].timeseries[0].data | Where-Object { $null -ne $_.maximum })
            if ($tocke.Count -gt 0) {
                $maks = ($tocke | Measure-Object -Property maximum -Maximum).Maximum
                $pros = ($tocke | Measure-Object -Property average -Average).Average
                [void]$redovi.Add([pscustomobject]@{
                    VM = $vm
                    MaxCPU = [math]::Round($maks, 1)
                    ProsjekCPU = [math]::Round($pros, 1)
                    BrojUzoraka = $tocke.Count
                })
                Write-Ok "$vm : max $([math]::Round($maks,1)) % / prosjek $([math]::Round($pros,1)) % ($($tocke.Count) uzoraka)"
            }
        }
    }
    $metrikeTablica = ($redovi | Format-Table -AutoSize | Out-String)

    Write-Korak 'Provjera aktiviranih alarma'
    # Alerts API ima kasnjenje od nekoliko minuta izmedu prelaska praga i
    # pojavljivanja zapisa, pa provjeru ponavljamo umjesto da pitamo samo jednom.
    $alarmiNadeni = @()
    $pokusaja = 10
    for ($p = 1; $p -le $pokusaja; $p++) {
        try {
            $alarmi = Invoke-ArmRest -Metoda GET -Url ("https://management.azure.com/subscriptions/{0}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" -f $konfig.subscriptionId) -Tiho
            if ($alarmi -and $alarmi.value) {
                $alarmiNadeni = @($alarmi.value | Where-Object {
                    $_.properties.essentials.alertRule -match 'technova' -and
                    [datetime]$_.properties.essentials.startDateTime -gt (Get-Date).ToUniversalTime().AddHours(-1)
                })
            }
        } catch { }

        if ($alarmiNadeni.Count -gt 0) { break }
        if ($p -lt $pokusaja) {
            Write-Info "Alarmi se jos nisu pojavili (pokusaj $p/$pokusaja) - cekam 30 s..."
            Start-Sleep -Seconds 30
        }
    }

    $cpuAlarmi = @($alarmiNadeni | Where-Object { $_.properties.essentials.alertRule -match 'vm-cpu' })
    foreach ($a in $alarmiNadeni) {
        $naziv = ($a.properties.essentials.alertRule -split '/')[-1]
        Write-Ok "Alarm: $naziv | stanje: $($a.properties.essentials.monitorCondition) | $($a.properties.essentials.startDateTime)"
    }

    Dodaj-Rezultat -Test 'Alarm CPU > 80% aktiviran' -Ocekivano 'barem 1 alarm' `
        -Dobiveno "$($cpuAlarmi.Count) CPU alarma (ukupno $($alarmiNadeni.Count))" -Prolaz ($cpuAlarmi.Count -gt 0)

    $alarmiTablica = ''
    if ($alarmiNadeni.Count -gt 0) {
        $alarmiTablica = "| Alarm | Stanje | Vrijeme (UTC) |`n|---|---|---|`n"
        foreach ($a in $alarmiNadeni) {
            $naziv = ($a.properties.essentials.alertRule -split '/')[-1]
            $alarmiTablica += "| $naziv | $($a.properties.essentials.monitorCondition) | $($a.properties.essentials.startDateTime) |`n"
        }
    }
} else {
    Write-Info 'Test opterećenja preskočen. Pokrenite s -SOpterecenjem za dokaz alarma CPU > 80%.'
}

# =====================================================================
# IZVJEŠTAJ
# =====================================================================
Write-Korak 'Izrada izvještaja'

$tablicaRezultata = $rezultati | Format-Table -AutoSize | Out-String
$prosli = @($rezultati | Where-Object { $_.Status -eq 'PROLAZ' }).Count
$ukupno = $rezultati.Count

Write-Host ''
Write-Host $tablicaRezultata
Write-Host ("  REZULTAT: $prosli / $ukupno testova prošlo") -ForegroundColor $(if ($prosli -eq $ukupno) { 'Green' } else { 'Yellow' })

$mdTablica = "| Test | Očekivano | Dobiveno | Status |`n|---|---|---|---|`n"
foreach ($r in $rezultati) {
    $mdTablica += "| $($r.Test) | $($r.Ocekivano) | $($r.Dobiveno) | $($r.Status) |`n"
}

$mdIpFlow = ''
if ($ipFlowRezultati.Count -gt 0) {
    $mdIpFlow = "| Scenarij | Rezultat | NSG pravilo | Očekivano |`n|---|---|---|---|`n"
    foreach ($r in $ipFlowRezultati) {
        $mdIpFlow += "| $($r.Scenarij) | $($r.Pristup) | $($r.Pravilo) | $($r.Ocekivano) |`n"
    }
}

$mdLatencija = ''
if ($stat) {
    $mdLatencija = @"
| Mjera | Vrijednost |
|---|---|
| Minimum | $($stat.Min) ms |
| Prosjek | $($stat.Prosjek) ms |
| 95. percentil | $($stat.P95) ms |
| Maksimum | $($stat.Max) ms |
| Uspješnih zahtjeva | $($stat.Uspjesnih) / $BrojZahtjeva |
"@
}

$mdRaspodjela = "| Poslužitelj | Broj zahtjeva | Udio |`n|---|---|---|`n"
$ukupnoZahtjeva = ($posluzitelji.Values | Measure-Object -Sum).Sum
foreach ($k in ($posluzitelji.Keys | Sort-Object)) {
    $udio = if ($ukupnoZahtjeva -gt 0) { [math]::Round(($posluzitelji[$k] / $ukupnoZahtjeva) * 100, 1) } else { 0 }
    $mdRaspodjela += "| $k | $($posluzitelji[$k]) | $udio % |`n"
}

Save-Dokaz -Naziv 'ishod3-4-testovi' -Sadrzaj @"
# Dokaz: testovi mrežne učinkovitosti, sigurnosti i performansi

Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Ciljna adresa: $url
Javna IP Load Balancera: $ip
Rezultat: **$prosli / $ukupno testova prošlo**

## 1. Sažetak svih testova

$mdTablica

## 2. Balansiranje mrežnog prometa

Poslano $BrojZahtjeva HTTPS zahtjeva s jednog klijenta prema javnoj adresi Load Balancera.
Azure Standard Load Balancer koristi hash po pet elemenata (izvorišna IP i port,
odredišna IP i port, protokol), pa se zahtjevi raspoređuju između oba virtualna stroja.

$mdRaspodjela

## 3. Latencija

$mdLatencija

## 4. TLS

$tlsInfo

Napomena: certifikat je self-signed jer PoC nema registriranu javnu domenu.
U produkciji se koristi certifikat izdan od javnog CA ili Azure managed certifikat,
pohranjen u Key Vaultu i automatski obnavljan.

## 5. Verifikacija mrežnih sigurnosnih pravila (Network Watcher IP flow verify)

Ovo je programska provjera stvarnog učinka NSG pravila, a ne samo pregled konfiguracije.

$mdIpFlow

## 6. Performanse virtualnih strojeva pod opterećenjem

$(if ($SOpterecenjem) {
@"
Na oba VM-a pokrenut je ``stress-ng --cpu 2 --cpu-method matrixprod`` u trajanju od $TrajanjeOpterecenjaSek sekundi
putem ``az vm run-command invoke``. Metrike su očitane iz Azure Monitora.

``````
$metrikeTablica
``````

Očekivano ponašanje: iskorištenost procesora prelazi 80 %, alarm
``technova-alert-vm-cpu-prod`` prelazi u stanje Fired i Action Group
``technova-ag-prod`` šalje e-mail obavijest.

### Aktivirani alarmi

$(if ($alarmiTablica) { $alarmiTablica } else { 'U promatranom razdoblju nije zabiljezen nijedan alarm.' })
"@
} else {
"Test opterećenja nije pokrenut u ovom prolazu. Pokrenite ``.\scripts\05-testovi.ps1 -SOpterecenjem``."
})
"@ | Out-Null

Write-Naslov 'KORAK 5 ZAVRŠEN'
Write-Info 'Izvještaj je u docs\dokazi\. Sljedeće: prikupite screenshotove iz Azure portala.'
