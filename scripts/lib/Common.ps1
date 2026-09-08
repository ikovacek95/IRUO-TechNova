# =====================================================================
#  TechNova Solutions - zajedničke pomoćne funkcije
#  Kompatibilno s Windows PowerShell 5.1 i PowerShell 7+
# =====================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Azure CLI na Windowsu ispisuje u ANSI kodnoj stranici sustava (npr. windows-1250),
# a NE u UTF-8. Bez ovoga PowerShell 5.1 dekodira izlaz OEM stranicom (CP852) pa
# hrvatski znakovi stizu iskrivljeno ("Ana Mari?") i takvi zavrse u dokumentaciji.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::Default
} catch { }

# $PSScriptRoot je ...\technova-azure\scripts\lib -> korijen je dvije razine iznad
$script:ProjektKorijen = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:KonfigDatoteka = Join-Path $script:ProjektKorijen 'config.local.json'
$script:DokaziMapa     = Join-Path $script:ProjektKorijen 'docs\dokazi'

# ---------------------------------------------------------------------
#  Ispis
# ---------------------------------------------------------------------
function Write-Naslov {
    param([string]$Tekst)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $Tekst" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Write-Korak {
    param([string]$Tekst)
    Write-Host "`n[>] $Tekst" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Tekst)
    Write-Host "  [OK]   $Tekst" -ForegroundColor Green
}

function Write-Info {
    param([string]$Tekst)
    Write-Host "  [i]    $Tekst" -ForegroundColor Gray
}

function Write-Upozorenje {
    param([string]$Tekst)
    Write-Host "  [!]    $Tekst" -ForegroundColor Yellow
}

function Write-Greska {
    param([string]$Tekst)
    Write-Host "  [X]    $Tekst" -ForegroundColor Red
}

# ---------------------------------------------------------------------
#  Pokretanje Azure CLI naredbi s provjerom greške
# ---------------------------------------------------------------------
$script:AzPython = $null
$script:AzPythonProvjeren = $false

function Get-AzPokretac {
    <#
        .SYNOPSIS
        Vraca putanju do python.exe koji pokrece Azure CLI, ili $null ako nije nadena.

        .DESCRIPTION
        Na Windowsu je 'az' zapravo batch datoteka az.cmd. Svaki poziv time prolazi
        kroz cmd.exe, koji znakove & % ! ^ | < > ( ) tumaci kao operatore. Argumenti
        bez razmaka (npr. JMESPath filtar "startswith(displayName,'TechNova')" ili
        lozinka sa znakom &) PowerShell ne citira, pa ih cmd.exe razbije.

        Zato pozivamo Python ulaznu tocku izravno - identicno onome sto radi az.cmd,
        ali bez cmd.exe u lancu, pa nikakvo citiranje nije potrebno.
    #>
    if ($script:AzPythonProvjeren) { return $script:AzPython }
    $script:AzPythonProvjeren = $true

    $azNaredba = Get-Command az -ErrorAction SilentlyContinue
    if ($azNaredba -and $azNaredba.Source -and $azNaredba.Source.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)) {
        $kandidat = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $azNaredba.Source -Parent) '..\python.exe'))
        if (Test-Path $kandidat) {
            $script:AzPython = $kandidat
            $env:AZ_INSTALLER = 'MSI'
        }
    }

    # Sprjecavamo da 'az' ikad ceka na interaktivni unos. Neke naredbe
    # (npr. 'az monitor data-collection', 'az portal dashboard') trebaju
    # extension i pitaju za potvrdu instalacije. Buduci da skripte hvataju
    # izlaz u varijablu, taj se prompt ne vidi i skripta izgleda kao da je zapela.
    $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
    $env:AZURE_CORE_DISABLE_CONFIRM_PROMPT = 'true'

    return $script:AzPython
}

function Invoke-AzCli {
    <#
        .SYNOPSIS
        Pokreće 'az' s danim argumentima i vraća rezultat kao PowerShell objekt.

        .PARAMETER Argumenti
        Polje argumenata, npr. @('group','show','--name','TechNova-RG')

        .PARAMETER Tekstualno
        Vraća sirovi tekst umjesto parsiranja JSON-a.

        .PARAMETER Tiho
        Ne baca iznimku ako naredba ne uspije; vraća $null.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Argumenti,
        [switch]$Tekstualno,
        [switch]$Tiho
    )

    # VAZNO: 'az' pise upozorenja (WARNING, deprecation obavijesti) na stderr.
    # Uz 2>&1 i $ErrorActionPreference = 'Stop' PowerShell takav zapis pretvara
    # u terminirajucu gresku iako je izlazni kod 0 i naredba je uspjela.
    # Zato oko samog poziva privremeno prebacujemo na 'Continue'.
    $prethodni = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $py = Get-AzPokretac
        if ($py) {
            $izlaz = & $py -IBm azure.cli @Argumenti 2>&1
        } else {
            $izlaz = & az @Argumenti 2>&1
        }
        $kod = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prethodni
    }

    if ($kod -ne 0) {
        if ($Tiho) { return $null }
        $poruka = ($izlaz | Out-String).Trim()
        throw "Azure CLI naredba nije uspjela (izlazni kod $kod):`n  az $($Argumenti -join ' ')`n$poruka"
    }

    # Upozorenja i dijagnostiku odbacujemo - zanima nas samo stdout
    $tekst = ($izlaz | Where-Object {
        $_ -isnot [System.Management.Automation.ErrorRecord] -and
        $_ -notmatch '^\s*(WARNING|INFO|DEBUG)\s*:'
    } | Out-String).Trim()
    if ($Tekstualno) { return $tekst }
    if ([string]::IsNullOrWhiteSpace($tekst)) { return $null }

    # VAZNO: rezultat se prvo sprema u varijablu pa tek onda vraca.
    # ConvertFrom-Json u PowerShellu 5.1 ne raspakirava polje kroz pipeline,
    # pa bi 'return $tekst | ConvertFrom-Json' vratio ugnijezdeno polje
    # i svaki '@(...)' kod pozivatelja dao bi Count = 1.
    try { $rezultat = $tekst | ConvertFrom-Json }
    catch { return $tekst }

    return $rezultat
}

function Invoke-AzCliZivo {
    <#
        .SYNOPSIS
        Pokrece 'az' uz izravan ispis u konzolu (za dugotrajne operacije poput
        deploymenta, gdje zelimo pratiti napredak). Vraca izlazni kod.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Argumenti)

    $prethodni = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $py = Get-AzPokretac
        if ($py) {
            & $py -IBm azure.cli @Argumenti | Out-Host
        } else {
            & az @Argumenti | Out-Host
        }
        $kod = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prethodni
    }
    return $kod
}

# ---------------------------------------------------------------------
#  Konfiguracija projekta (config.local.json - NIJE u gitu)
# ---------------------------------------------------------------------
function Get-TechNovaKonfig {
    if (Test-Path $script:KonfigDatoteka) {
        return (Get-Content $script:KonfigDatoteka -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $null
}

function Save-TechNovaKonfig {
    param([Parameter(Mandatory = $true)]$Konfig)
    $Konfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:KonfigDatoteka -Encoding UTF8 -Force
}

function Set-TechNovaVrijednost {
    param(
        [Parameter(Mandatory = $true)][string]$Kljuc,
        [Parameter(Mandatory = $true)]$Vrijednost
    )
    $konfig = Get-TechNovaKonfig
    if ($null -eq $konfig) { $konfig = [pscustomobject]@{} }
    if ($konfig.PSObject.Properties.Name -contains $Kljuc) {
        $konfig.$Kljuc = $Vrijednost
    } else {
        $konfig | Add-Member -NotePropertyName $Kljuc -NotePropertyValue $Vrijednost
    }
    Save-TechNovaKonfig -Konfig $konfig
    return $konfig
}

function Assert-TechNovaKonfig {
    <# Učitava konfiguraciju i prekida rad ako obavezni ključevi nedostaju. #>
    param([string[]]$ObavezniKljucevi = @())

    $konfig = Get-TechNovaKonfig
    if ($null -eq $konfig) {
        throw "Konfiguracija nije pronađena. Prvo pokrenite: .\scripts\00-preduvjeti.ps1"
    }
    foreach ($k in $ObavezniKljucevi) {
        if (-not ($konfig.PSObject.Properties.Name -contains $k) -or [string]::IsNullOrWhiteSpace([string]$konfig.$k)) {
            throw "U konfiguraciji nedostaje '$k'. Pokrenite prethodnu skriptu u nizu."
        }
    }
    return $konfig
}

# ---------------------------------------------------------------------
#  Putanje
# ---------------------------------------------------------------------
function Get-ProjektKorijen { return $script:ProjektKorijen }

function Get-DokaziMapa {
    if (-not (Test-Path $script:DokaziMapa)) {
        New-Item -ItemType Directory -Path $script:DokaziMapa -Force | Out-Null
    }
    return $script:DokaziMapa
}

function Save-Dokaz {
    <# Sprema tekstualni dokaz u docs\dokazi\ s vremenskom oznakom. #>
    param(
        [Parameter(Mandatory = $true)][string]$Naziv,
        [Parameter(Mandatory = $true)][string]$Sadrzaj
    )
    $mapa = Get-DokaziMapa
    $putanja = Join-Path $mapa ("{0}_{1}.md" -f $Naziv, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $Sadrzaj | Set-Content -Path $putanja -Encoding UTF8 -Force
    Write-Ok "Dokaz spremljen: $putanja"
    return $putanja
}

# ---------------------------------------------------------------------
#  Ostalo
# ---------------------------------------------------------------------
function New-JakaLozinka {
    param([int]$Duljina = 20)

    $mala    = 'abcdefghijkmnopqrstuvwxyz'
    $velika  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $brojke  = '23456789'
    # Namjerno su izostavljeni znakovi koje cmd.exe tumaci kao operatore
    # (& % ! ^ | < > " ' ( ) ;) jer je 'az' na Windowsu batch datoteka az.cmd,
    # pa bi takva lozinka razbila poziv naredbe.
    $znakovi = '#@+=-_.~'
    $svi     = $mala + $velika + $brojke + $znakovi

    if ($Duljina -lt 12) { $Duljina = 12 }

    # Kriptografski siguran izvor slucajnosti. System.Random se seeda iz
    # Environment.TickCount, pa bi dva poziva unutar iste milisekunde vratila
    # IDENTICNU lozinku - npr. istu za break-glass racun i za testne korisnike.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bajtovi = New-Object 'byte[]' ($Duljina * 8)
        $rng.GetBytes($bajtovi)
    } finally {
        $rng.Dispose()
    }

    $zaOdabir = @(for ($i = 0; $i -lt $Duljina; $i++) { [BitConverter]::ToUInt32($bajtovi, $i * 4) })
    $zaMijesanje = @(for ($i = 0; $i -lt $Duljina; $i++) { [BitConverter]::ToUInt32($bajtovi, ($Duljina + $i) * 4) })

    # Prva cetiri znaka jamce sve cetiri kategorije slozenosti koje Entra ID trazi
    $skupovi = @($mala, $velika, $brojke, $znakovi)
    $znakoviLozinke = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $Duljina; $i++) {
        $skup = if ($i -lt $skupovi.Count) { $skupovi[$i] } else { $svi }
        [void]$znakoviLozinke.Add($skup[[int]($zaOdabir[$i] % [uint32]$skup.Length)])
    }

    # Fisher-Yates mijesanje kako obavezne kategorije ne bi uvijek bile na pocetku
    for ($i = $znakoviLozinke.Count - 1; $i -gt 0; $i--) {
        $j = [int]($zaMijesanje[$i] % [uint32]($i + 1))
        $privremeno = $znakoviLozinke[$i]
        $znakoviLozinke[$i] = $znakoviLozinke[$j]
        $znakoviLozinke[$j] = $privremeno
    }

    return (-join $znakoviLozinke)
}

function Get-MojaJavnaIp {
    foreach ($url in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = (Invoke-RestMethod -Uri $url -TimeoutSec 10 -UseBasicParsing).ToString().Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { }
    }
    return $null
}

function Invoke-GraphRest {
    <#
        .SYNOPSIS
        Poziva Microsoft Graph preko 'az rest'. Tijelo zahtjeva se zapisuje u
        privremenu datoteku kako bi se izbjegli problemi s navodnicima u Windowsu.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Metoda,
        [Parameter(Mandatory = $true)][string]$Url,
        $Tijelo = $null,
        [switch]$Tiho
    )

    $argumenti = @('rest', '--method', $Metoda, '--url', $Url, '--resource', 'https://graph.microsoft.com')

    $temp = $null
    if ($null -ne $Tijelo) {
        $temp = [System.IO.Path]::GetTempFileName()
        ($Tijelo | ConvertTo-Json -Depth 12) | Set-Content -Path $temp -Encoding UTF8 -Force
        $argumenti += @('--headers', 'Content-Type=application/json', '--body', "@$temp")
    }

    try {
        if ($Tiho) { return Invoke-AzCli -Argumenti $argumenti -Tiho }
        return Invoke-AzCli -Argumenti $argumenti
    } finally {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ArmRest {
    <#
        .SYNOPSIS
        Poziva Azure Resource Manager API preko 'az rest' (za operacije koje CLI ne pokriva).
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Metoda,
        [Parameter(Mandatory = $true)][string]$Url,
        $Tijelo = $null,
        [switch]$Tiho
    )

    $argumenti = @('rest', '--method', $Metoda, '--url', $Url)

    $temp = $null
    if ($null -ne $Tijelo) {
        $temp = [System.IO.Path]::GetTempFileName()
        ($Tijelo | ConvertTo-Json -Depth 12) | Set-Content -Path $temp -Encoding UTF8 -Force
        $argumenti += @('--headers', 'Content-Type=application/json', '--body', "@$temp")
    }

    try {
        if ($Tiho) { return Invoke-AzCli -Argumenti $argumenti -Tiho }
        return Invoke-AzCli -Argumenti $argumenti
    } finally {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Disable-CertProvjera {
    <# Dopusta HTTPS pozive prema self-signed certifikatu (PowerShell 5.1). #>
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }
    if (-not ([System.Management.Automation.PSTypeName]'TechNovaTrustAll').Type) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TechNovaTrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TechNovaTrustAll
}

function Invoke-WebZahtjev {
    <# Omotac oko Invoke-WebRequest koji radi sa self-signed certifikatima na PS 5.1 i 7+. #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$Timeout = 20,
        [switch]$BezRedirecta
    )
    $parametri = @{
        Uri              = $Url
        TimeoutSec       = $Timeout
        UseBasicParsing  = $true
        DisableKeepAlive = $true
        ErrorAction      = 'Stop'
    }
    if ($BezRedirecta) { $parametri['MaximumRedirection'] = 0 }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $parametri['SkipCertificateCheck'] = $true } else { Disable-CertProvjera }
    return Invoke-WebRequest @parametri
}

function Get-TijeloOdgovora {
    <#
        .SYNOPSIS
        Vraca tijelo HTTP odgovora kao tekst.

        .DESCRIPTION
        Invoke-WebRequest -UseBasicParsing na PowerShellu 5.1 zna vratiti .Content
        kao byte[] umjesto niza znakova, pa bi .Trim() na njemu pukao.
    #>
    param([Parameter(Mandatory = $true)]$Odgovor)

    $sadrzaj = $Odgovor.Content
    if ($null -eq $sadrzaj) { return '' }
    if ($sadrzaj -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($sadrzaj) }
    return [string]$sadrzaj
}

function Get-HttpStatus {
    <#
        .SYNOPSIS
        Vraca HTTP statusni kod bez slijedenja preusmjeravanja.

        .DESCRIPTION
        Invoke-WebRequest s -MaximumRedirection 0 na PowerShellu 5.1 baca
        InvalidOperationException BEZ .Response objekta, pa se statusni kod
        (npr. 301) iz njega ne moze procitati. Zato koristimo HttpWebRequest
        s AllowAutoRedirect = false, koji uredno vraca i kod i Location zaglavlje.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$Timeout = 20
    )

    Disable-CertProvjera
    $zahtjev = [System.Net.HttpWebRequest]::Create($Url)
    $zahtjev.AllowAutoRedirect = $false
    $zahtjev.Timeout = $Timeout * 1000
    $zahtjev.UserAgent = 'TechNova-Test/1.0'

    try {
        $odgovor = $zahtjev.GetResponse()
        $rezultat = [pscustomobject]@{
            Kod      = [int]$odgovor.StatusCode
            Lokacija = $odgovor.Headers['Location']
        }
        $odgovor.Close()
        return $rezultat
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $o = $_.Exception.Response
            $r = [pscustomobject]@{
                Kod      = [int]$o.StatusCode
                Lokacija = $o.Headers['Location']
            }
            $o.Close()
            return $r
        }
        return [pscustomobject]@{ Kod = 0; Lokacija = $null }
    }
}

function Get-TlsPodaci {
    <#
        .SYNOPSIS
        Vraca verziju TLS-a i podatke certifikata za dani posluzitelj.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Posluzitelj,
        [int]$Port = 443
    )

    $tcp = $null
    $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient($Posluzitelj, $Port)
        # Delegat se mora deklarirati s 'param(...)'. Zapis
        # '{ $true } -as [RemoteCertificateValidationCallback]' vraca $null,
        # zbog cega AuthenticateAsClient puca na self-signed certifikatu.
        $provjera = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($posiljatelj, $certifikat, $lanac, $greske)
            return $true
        }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $provjera)
        $ssl.AuthenticateAsClient($Posluzitelj)

        $cert = $null
        if ($ssl.RemoteCertificate) {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        }

        return [pscustomobject]@{
            Protokol   = $ssl.SslProtocol.ToString()
            Subjekt    = $(if ($cert) { $cert.Subject } else { 'nepoznato' })
            Izdavatelj = $(if ($cert) { $cert.Issuer } else { 'nepoznato' })
            VrijediDo  = $(if ($cert) { $cert.NotAfter.ToString('yyyy-MM-dd') } else { 'nepoznato' })
        }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Close() }
    }
}

function Wait-SOdbrojavanjem {
    param(
        [int]$Sekunde = 60,
        [string]$Poruka = 'Čekanje'
    )
    for ($i = 1; $i -le $Sekunde; $i++) {
        Write-Progress -Activity $Poruka -Status "$i / $Sekunde s" -PercentComplete (($i / $Sekunde) * 100)
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity $Poruka -Completed
}
