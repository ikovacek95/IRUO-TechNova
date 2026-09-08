<#
.SYNOPSIS
    Korak 1 - Entra ID: korisničke grupe po odjelima, testni korisnici i break-glass račun.

.DESCRIPTION
    Kreira (idempotentno) grupe TechNova-Dev, TechNova-Sales i TechNova-Support,
    po jednog testnog korisnika u svakoj te break-glass (nužni pristup) račun koji
    se izuzima iz Conditional Access politika kako se ne biste zaključali izvan tenanta.

    Object ID-ovi grupa spremaju se u config.local.json i koriste ih Bicep predlošci
    za dodjelu RBAC uloga.

.EXAMPLE
    .\scripts\01-identiteti.ps1
#>
[CmdletBinding()]
param(
    [switch]$BezKorisnika
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @('tenantId', 'subscriptionId')

Write-Naslov 'KORAK 1 - UPRAVLJANJE IDENTITETIMA (Entra ID)'

# ---------------------------------------------------------------------
# Zadana domena tenanta
# ---------------------------------------------------------------------
Write-Korak 'Dohvat zadane domene tenanta'
$domene = Invoke-GraphRest -Metoda GET -Url 'https://graph.microsoft.com/v1.0/domains'
$zadana = $domene.value | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
if (-not $zadana) { throw 'Nije pronađena zadana domena tenanta. Provjerite dozvole (Domain.Read.All).' }
$domena = $zadana.id
Write-Ok "Domena: $domena"

# ---------------------------------------------------------------------
# Pomoćne funkcije
# ---------------------------------------------------------------------
function New-TechNovaGrupa {
    param([string]$Naziv, [string]$Nadimak, [string]$Opis)

    $postojeca = Invoke-AzCli -Argumenti @('ad', 'group', 'list', '--filter', "displayName eq '$Naziv'") -Tiho
    if ($postojeca -and @($postojeca).Count -gt 0) {
        $g = @($postojeca)[0]
        Write-Info "Grupa '$Naziv' već postoji (ID: $($g.id))"
        return $g
    }

    $g = Invoke-AzCli -Argumenti @(
        'ad', 'group', 'create',
        '--display-name', $Naziv,
        '--mail-nickname', $Nadimak,
        '--description', $Opis
    )
    Write-Ok "Kreirana grupa '$Naziv' (ID: $($g.id))"
    return $g
}

function New-TechNovaKorisnik {
    param([string]$Upn, [string]$Prikaz, [string]$Lozinka, [string]$Odjel, [string]$Titula)

    $postojeci = Invoke-AzCli -Argumenti @('ad', 'user', 'list', '--filter', "userPrincipalName eq '$Upn'") -Tiho
    if ($postojeci -and @($postojeci).Count -gt 0) {
        $u = @($postojeci)[0]
        Write-Info "Korisnik '$Upn' već postoji"
        return $u
    }

    # VAZNO: korisnik se kreira preko Microsoft Graph REST-a, a NE naredbom
    # 'az ad user create'. Na Windowsu je 'az' batch datoteka (az.cmd), pa cmd.exe
    # tumaci znakove poput & u lozinki kao operatore i razbija poziv. Kod Graph
    # poziva tijelo zahtjeva ide kroz privremenu JSON datoteku, sto je sigurno.
    $nadimak = ($Upn -split '@')[0]

    try {
        $u = Invoke-GraphRest -Metoda POST -Url 'https://graph.microsoft.com/v1.0/users' -Tijelo @{
            accountEnabled    = $true
            displayName       = $Prikaz
            mailNickname      = $nadimak
            userPrincipalName = $Upn
            department        = $Odjel
            jobTitle          = $Titula
            usageLocation     = 'HR'
            passwordProfile   = @{
                password                      = $Lozinka
                forceChangePasswordNextSignIn = $false
            }
        }
        Write-Ok "Kreiran korisnik '$Prikaz' ($Upn)"
        return $u
    } catch {
        Write-Greska "Nije uspjelo kreiranje korisnika '$Prikaz'. Detalji: $($_.Exception.Message)"
        return $null
    }
}

function Add-ClanGrupe {
    param($Grupa, $Korisnik)
    if (-not $Grupa -or -not $Korisnik) { return }

    $clan = Invoke-AzCli -Argumenti @('ad', 'group', 'member', 'check', '--group', $Grupa.id, '--member-id', $Korisnik.id) -Tiho
    if ($clan -and $clan.value -eq $true) {
        Write-Info "$($Korisnik.displayName) je već član grupe $($Grupa.displayName)"
        return
    }
    Invoke-AzCli -Argumenti @('ad', 'group', 'member', 'add', '--group', $Grupa.id, '--member-id', $Korisnik.id) -Tiho | Out-Null
    Write-Ok "$($Korisnik.displayName) dodan u grupu $($Grupa.displayName)"
}

# ---------------------------------------------------------------------
# Grupe po odjelima
# ---------------------------------------------------------------------
Write-Korak 'Kreiranje grupa po odjelima'
$grpDev     = New-TechNovaGrupa -Naziv 'TechNova-Dev'     -Nadimak 'technova-dev'     -Opis 'Development odjel - upravljanje virtualnim strojevima i aplikacijskim podacima'
$grpSales   = New-TechNovaGrupa -Naziv 'TechNova-Sales'   -Nadimak 'technova-sales'   -Opis 'Sales odjel - pristup samo za citanje'
$grpSupport = New-TechNovaGrupa -Naziv 'TechNova-Support' -Nadimak 'technova-support' -Opis 'Support odjel - nadzor i dijagnostika'

# ---------------------------------------------------------------------
# Break-glass račun (nužni pristup)
# ---------------------------------------------------------------------
Write-Korak 'Break-glass račun za nužni pristup'
# Lozinka se pamti u konfiguraciji kako bi ponovno pokretanje skripte
# (npr. nakon brisanja racuna) koristilo istu lozinku koja je vec dokumentirana.
if ($konfig.PSObject.Properties.Name -contains 'breakGlassLozinka' -and -not [string]::IsNullOrWhiteSpace([string]$konfig.breakGlassLozinka)) {
    $bgLozinka = $konfig.breakGlassLozinka
} else {
    $bgLozinka = New-JakaLozinka -Duljina 24
    Set-TechNovaVrijednost -Kljuc 'breakGlassLozinka' -Vrijednost $bgLozinka | Out-Null
}
$bgUpn = "technova-breakglass@$domena"
$bgKorisnik = New-TechNovaKorisnik -Upn $bgUpn -Prikaz 'TechNova Break-Glass Admin' -Lozinka $bgLozinka -Odjel 'IT' -Titula 'Emergency Access Account'

# Break-glass racun BEZ administratorske uloge je beskoristan - u nuzdi ne bi
# mogao ni ukloniti politiku koja je zakljucala ostale korisnike. Zato mu
# dodjeljujemo Global Administrator.
if ($bgKorisnik -and $bgKorisnik.id) {
    Write-Korak 'Dodjela uloge Global Administrator break-glass računu'
    try {
        $ulogaId = '62e90394-69f5-4237-9190-012177145e10'  # Global Administrator (template ID)

        # Uloga mora biti "aktivirana" u direktoriju prije nego joj se dodaju clanovi
        $aktivne = Invoke-GraphRest -Metoda GET -Url 'https://graph.microsoft.com/v1.0/directoryRoles' -Tiho
        $ga = $null
        if ($aktivne -and $aktivne.value) {
            $ga = $aktivne.value | Where-Object { $_.roleTemplateId -eq $ulogaId } | Select-Object -First 1
        }
        if (-not $ga) {
            $ga = Invoke-GraphRest -Metoda POST -Url 'https://graph.microsoft.com/v1.0/directoryRoles' -Tijelo @{ roleTemplateId = $ulogaId } -Tiho
        }

        if ($ga -and $ga.id) {
            $clanovi = Invoke-GraphRest -Metoda GET -Url "https://graph.microsoft.com/v1.0/directoryRoles/$($ga.id)/members" -Tiho
            $vec = $false
            if ($clanovi -and $clanovi.value) {
                $vec = @($clanovi.value | Where-Object { $_.id -eq $bgKorisnik.id }).Count -gt 0
            }

            if ($vec) {
                Write-Info 'Break-glass račun već ima ulogu Global Administrator.'
            } else {
                Invoke-GraphRest -Metoda POST -Url "https://graph.microsoft.com/v1.0/directoryRoles/$($ga.id)/members/`$ref" -Tijelo @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($bgKorisnik.id)"
                } -Tiho | Out-Null
                Write-Ok 'Break-glass računu dodijeljena uloga Global Administrator.'
            }
        }
    } catch {
        Write-Upozorenje "Uloga nije dodijeljena: $($_.Exception.Message)"
        Write-Info 'Dodijelite ručno: Entra portal > Roles and administrators > Global Administrator > Add assignments.'
    }
}

$bgDatoteka = Join-Path (Get-ProjektKorijen) 'BREAK-GLASS-LOZINKA.txt'
@"
TechNova Solutions - račun za nužni pristup (break-glass)
=========================================================
UPN:     $bgUpn
Lozinka: $bgLozinka
Uloga:   Global Administrator

Ovaj račun je NAMJERNO izuzet iz svih Conditional Access politika kako biste
zadržali pristup tenantu i ako geo-blokada ili MFA politika krivo zaključa
sve ostale korisnike.

Buduci da je cloud-only (nije vezan uz Microsoft account), koristan je i kad
neka operacija zahtijeva "pravi" radni racun - primjerice aktivacija probne
Entra ID P2 licence, koja s MSA racunom (#EXT# u UPN-u) zna zapeti.

VAZNO:
 - Ova datoteka je u .gitignore i NE SMIJE zavrsiti u repozitoriju.
 - Za predaju projekta lozinku prekrijte (zacrnite) na screenshotovima.
 - Preporuka struke: dva break-glass racuna, iskljucivo cloud-only,
   s FIDO2 kljucem i alarmom na svaku prijavu.
"@ | Set-Content -Path $bgDatoteka -Encoding UTF8 -Force
Write-Ok 'Podaci break-glass računa spremljeni u BREAK-GLASS-LOZINKA.txt'

# ---------------------------------------------------------------------
# Testni korisnici po odjelima
# ---------------------------------------------------------------------
if (-not $BezKorisnika) {
    Write-Korak 'Kreiranje testnih korisnika'
    # Lozinka se pamti u konfiguraciji. Bez toga bi ponovno pokretanje skripte
    # (npr. nakon brisanja jednog korisnika) tom korisniku dodijelilo novu lozinku
    # koja se vise ne bi podudarala s vec zapisanom u TESTNI-KORISNICI.txt.
    if ($konfig.PSObject.Properties.Name -contains 'testnaLozinka' -and -not [string]::IsNullOrWhiteSpace([string]$konfig.testnaLozinka)) {
        $zajednickaLozinka = $konfig.testnaLozinka
    } else {
        $zajednickaLozinka = New-JakaLozinka -Duljina 18
        Set-TechNovaVrijednost -Kljuc 'testnaLozinka' -Vrijednost $zajednickaLozinka | Out-Null
    }

    $uDev     = New-TechNovaKorisnik -Upn "ivan.horvat@$domena"  -Prikaz 'Ivan Horvat'  -Lozinka $zajednickaLozinka -Odjel 'Development' -Titula 'Software Engineer'
    $uSales   = New-TechNovaKorisnik -Upn "ana.maric@$domena"    -Prikaz 'Ana Marić'    -Lozinka $zajednickaLozinka -Odjel 'Sales'       -Titula 'Account Manager'
    $uSupport = New-TechNovaKorisnik -Upn "marko.ivic@$domena"   -Prikaz 'Marko Ivić'   -Lozinka $zajednickaLozinka -Odjel 'Support'     -Titula 'Support Specialist'

    Write-Korak 'Dodavanje korisnika u grupe'
    Add-ClanGrupe -Grupa $grpDev     -Korisnik $uDev
    Add-ClanGrupe -Grupa $grpSales   -Korisnik $uSales
    Add-ClanGrupe -Grupa $grpSupport -Korisnik $uSupport

    $korisniciDatoteka = Join-Path (Get-ProjektKorijen) 'TESTNI-KORISNICI.txt'
@"
TechNova Solutions - testni korisnici
=====================================
Zajednicka pocetna lozinka: $zajednickaLozinka

ivan.horvat@$domena   -> TechNova-Dev     (Virtual Machine Contributor)
ana.maric@$domena     -> TechNova-Sales   (Reader)
marko.ivic@$domena    -> TechNova-Support (Reader + Monitoring Reader)

Ova datoteka je u .gitignore. Lozinke prekrijte na screenshotovima.
"@ | Set-Content -Path $korisniciDatoteka -Encoding UTF8 -Force
    Write-Ok 'Podaci testnih korisnika spremljeni u TESTNI-KORISNICI.txt'
}

# ---------------------------------------------------------------------
# Spremanje ID-ova u konfiguraciju
# ---------------------------------------------------------------------
Write-Korak 'Spremanje Object ID-ova u konfiguraciju'
Set-TechNovaVrijednost -Kljuc 'domena'              -Vrijednost $domena              | Out-Null
Set-TechNovaVrijednost -Kljuc 'devGroupObjectId'    -Vrijednost $grpDev.id           | Out-Null
Set-TechNovaVrijednost -Kljuc 'salesGroupObjectId'  -Vrijednost $grpSales.id         | Out-Null
Set-TechNovaVrijednost -Kljuc 'supportGroupObjectId'-Vrijednost $grpSupport.id       | Out-Null
Set-TechNovaVrijednost -Kljuc 'breakGlassUpn'       -Vrijednost $bgUpn               | Out-Null
Set-TechNovaVrijednost -Kljuc 'breakGlassObjectId'  -Vrijednost $bgKorisnik.id       | Out-Null

Write-Ok "TechNova-Dev     : $($grpDev.id)"
Write-Ok "TechNova-Sales   : $($grpSales.id)"
Write-Ok "TechNova-Support : $($grpSupport.id)"

# ---------------------------------------------------------------------
# Dokaz za dokumentaciju
# ---------------------------------------------------------------------
$grupePregled = Invoke-AzCli -Argumenti @('ad', 'group', 'list', '--filter', "startswith(displayName,'TechNova')", '--query', '[].{Naziv:displayName, ObjectId:id, Opis:description}', '--output', 'table') -Tekstualno

Save-Dokaz -Naziv 'ishod1-identiteti' -Sadrzaj @"
# Ishod 1 - dokaz: Entra ID grupe i korisnici

Tenant: $($konfig.tenantId)
Domena: $domena
Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

## Kreirane grupe

``````
$grupePregled
``````

## Object ID-ovi (koriste se za RBAC dodjele u Bicep predlošku)

| Grupa | Object ID | Dodijeljene uloge |
|---|---|---|
| TechNova-Dev | $($grpDev.id) | Virtual Machine Contributor, Storage Blob Data Contributor, Key Vault Secrets Officer |
| TechNova-Sales | $($grpSales.id) | Reader, Storage Blob Data Reader, Storage File Data SMB Share Contributor |
| TechNova-Support | $($grpSupport.id) | Reader, Monitoring Reader, Storage Blob Data Reader |

## Break-glass račun

UPN: $bgUpn (izuzet iz svih Conditional Access politika)
"@ | Out-Null

Write-Naslov 'KORAK 1 ZAVRŠEN'
Write-Info 'Sljedeći korak:  .\scripts\02-conditional-access.ps1'
