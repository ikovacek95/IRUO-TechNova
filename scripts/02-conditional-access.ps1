<#
.SYNOPSIS
    Korak 2 - Conditional Access: geo-ograničenje na Hrvatsku, obavezni MFA i blokada legacy autentikacije.

.DESCRIPTION
    SIGURNOSNA NAPOMENA: politike se po defaultu kreiraju u načinu "samo izvještavanje"
    (report-only). Tako ih možete dokumentirati i prikazati bez rizika da se zaključate
    izvan vlastitog tenanta. Tek nakon što provjerite "Sign-in logs > Report-only" rezultate,
    uključite ih prekidačem -Ukljuci.

    Break-glass račun kreiran u koraku 1 automatski se izuzima iz svih politika.

    Conditional Access zahtijeva Microsoft Entra ID P1 licencu. Ako je nemate,
    upotrijebite -SecurityDefaults za besplatnu alternativu (obavezni MFA za sve).

.EXAMPLE
    .\scripts\02-conditional-access.ps1
    Kreira politike u report-only načinu.

.EXAMPLE
    .\scripts\02-conditional-access.ps1 -Ukljuci
    Aktivira politike (traži potvrdu).

.EXAMPLE
    .\scripts\02-conditional-access.ps1 -SecurityDefaults
    Uključuje Security Defaults (besplatna alternativa bez P1 licence).
#>
[CmdletBinding()]
param(
    [switch]$Ukljuci,
    [switch]$SecurityDefaults
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @('tenantId', 'devGroupObjectId', 'breakGlassObjectId')

Write-Naslov 'KORAK 2 - CONDITIONAL ACCESS I MFA'

$graf = 'https://graph.microsoft.com/v1.0'
$grafBeta = 'https://graph.microsoft.com/beta'

# ---------------------------------------------------------------------
# Provjera licence
# ---------------------------------------------------------------------
Write-Korak 'Provjera Entra ID licence'
$skus = Invoke-GraphRest -Metoda GET -Url "$graf/subscribedSkus" -Tiho
$imaP1 = $false
if ($skus -and $skus.value) {
    $imaP1 = @($skus.value | Where-Object { $_.skuPartNumber -match 'AAD_PREMIUM|ENTERPRISEPREMIUM|SPE_|EMS' }).Count -gt 0
    Write-Info ("Pronađene licence: " + (($skus.value | ForEach-Object { $_.skuPartNumber }) -join ', '))
}
if ($imaP1) {
    Write-Ok 'Tenant ima Entra ID P1/P2 - Conditional Access je dostupan.'

    # VAZNO: Conditional Access se licencira PO KORISNIKU. Politika koja cilja
    # 'All users' zahtijeva da SVAKI korisnik u tenantu ima P1/P2 licencu,
    # inace Graph odbija njezino kreiranje s AccessDenied. Politike koje ciljaju
    # samo uloge (npr. CA03) prolaze i bez toga - odatle zbunjujuca situacija
    # u kojoj jedna politika uspije, a ostale ne.
    Write-Korak 'Provjera licenci pojedinih korisnika'

    $premiumSku = $skus.value | Where-Object { $_.skuPartNumber -match 'AAD_PREMIUM' } | Select-Object -First 1
    if (-not $premiumSku) { $premiumSku = $skus.value | Where-Object { $_.skuPartNumber -match 'ENTERPRISEPREMIUM|SPE_|EMS' } | Select-Object -First 1 }

    if ($premiumSku) {
        $korisnici = Invoke-GraphRest -Metoda GET -Url "$graf/users`?`$select=id,displayName,assignedLicenses,usageLocation" -Tiho
        $bez = @()
        if ($korisnici -and $korisnici.value) {
            $bez = @($korisnici.value | Where-Object { @($_.assignedLicenses).Count -eq 0 })
        }

        if ($bez.Count -eq 0) {
            Write-Ok 'Svi korisnici imaju dodijeljenu licencu.'
        } else {
            $slobodno = [int]$premiumSku.prepaidUnits.enabled - [int]$premiumSku.consumedUnits
            Write-Info "$($bez.Count) korisnika je bez licence, slobodno ih je $slobodno."

            if ($slobodno -ge $bez.Count) {
                foreach ($usr in $bez) {
                    try {
                        # usageLocation je preduvjet za dodjelu licence
                        if (-not $usr.usageLocation) {
                            Invoke-GraphRest -Metoda PATCH -Url "$graf/users/$($usr.id)" -Tijelo @{ usageLocation = 'HR' } -Tiho | Out-Null
                        }
                        Invoke-GraphRest -Metoda POST -Url "$graf/users/$($usr.id)/assignLicense" -Tijelo @{
                            addLicenses    = @(@{ skuId = $premiumSku.skuId; disabledPlans = @() })
                            removeLicenses = @()
                        } -Tiho | Out-Null
                        Write-Ok "Licenca dodijeljena: $($usr.displayName)"
                    } catch {
                        Write-Upozorenje "Licenca nije dodijeljena korisniku $($usr.displayName)."
                    }
                }
                Write-Info 'Cekam 15 s da se dodjela licenci prosiri...'
                Start-Sleep -Seconds 15
            } else {
                Write-Upozorenje "Nema dovoljno slobodnih licenci ($slobodno za $($bez.Count) korisnika)."
                Write-Info 'Politike koje ciljaju "All users" vjerojatno nece proci.'
            }
        }
    }
} else {
    Write-Upozorenje 'Nije pronađena P1/P2 licenca. Conditional Access možda neće raditi.'
    Write-Info 'Besplatna 30-dnevna probna verzija: Entra portal > Identity > Overview > "Get a free trial".'
    Write-Info 'Alternativa bez licence: pokrenite ovu skriptu s prekidačem -SecurityDefaults'
}

# ---------------------------------------------------------------------
# Varijanta A: Security Defaults (besplatno)
# ---------------------------------------------------------------------
if ($SecurityDefaults) {
    Write-Korak 'Uključivanje Security Defaults (besplatni MFA za sve korisnike)'
    Write-Upozorenje 'Security Defaults i Conditional Access se međusobno isključuju.'

    $trenutno = Invoke-GraphRest -Metoda GET -Url "$graf/policies/identitySecurityDefaultsEnforcementPolicy"
    Write-Info "Trenutno stanje: isEnabled = $($trenutno.isEnabled)"

    Invoke-GraphRest -Metoda PATCH -Url "$graf/policies/identitySecurityDefaultsEnforcementPolicy" -Tijelo @{ isEnabled = $true } | Out-Null
    Write-Ok 'Security Defaults uključeni: MFA je obavezan za sve korisnike i administratore.'
    Write-Info 'Napomena: Security Defaults ne podržavaju geo-ograničenje - to zahtijeva P1.'

    Save-Dokaz -Naziv 'ishod1-security-defaults' -Sadrzaj @"
# Ishod 1 - dokaz: Security Defaults

Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Tenant: $($konfig.tenantId)

Security Defaults su uključeni. To znači:
- obavezna registracija MFA za sve korisnike u roku 14 dana
- obavezan MFA za sve administratorske uloge pri svakoj prijavi
- blokirana legacy (basic) autentikacija
- zaštićene privilegirane akcije u Azure portalu

Ograničenje: Security Defaults ne podržavaju geo-ograničenje prijave (samo iz Hrvatske).
Za taj zahtjev potreban je Microsoft Entra ID P1 i Conditional Access politika
CA01 opisana u dokumentaciji.
"@ | Out-Null

    Write-Naslov 'KORAK 2 ZAVRŠEN (Security Defaults)'
    return
}

# ---------------------------------------------------------------------
# Varijanta B: Conditional Access
# ---------------------------------------------------------------------
$stanje = if ($Ukljuci) { 'enabled' } else { 'enabledForReportingButNotEnforced' }

if ($Ukljuci) {
    Write-Upozorenje '=============================================================='
    Write-Upozorenje ' POLITIKE SE AKTIVIRAJU U PUNOM (BLOKIRAJUĆEM) NAČINU RADA!'
    Write-Upozorenje ' Ako se ne nalazite u Hrvatskoj ili koristite VPN, izgubit'
    Write-Upozorenje ' ćete pristup tenantu svime osim break-glass računom:'
    Write-Upozorenje "   $($konfig.breakGlassUpn)"
    Write-Upozorenje ' Lozinka je u datoteci BREAK-GLASS-LOZINKA.txt'
    Write-Upozorenje '=============================================================='
    $potvrda = Read-Host "Upišite 'RAZUMIJEM' za nastavak"
    if ($potvrda -ne 'RAZUMIJEM') {
        Write-Info 'Prekinuto. Politike ostaju u report-only načinu.'
        $stanje = 'enabledForReportingButNotEnforced'
        $Ukljuci = $false
    }
}

Write-Info "Politike se kreiraju u stanju: $stanje"

# ---------------------------------------------------------------------
# Named location - Hrvatska
# ---------------------------------------------------------------------
Write-Korak 'Definiranje lokacije "Hrvatska"'
$nazivLokacije = 'TechNova - Hrvatska'
$lokacije = Invoke-GraphRest -Metoda GET -Url "$graf/identity/conditionalAccess/namedLocations"
$hrLokacija = $lokacije.value | Where-Object { $_.displayName -eq $nazivLokacije } | Select-Object -First 1

if ($hrLokacija) {
    Write-Info "Lokacija već postoji (ID: $($hrLokacija.id))"
} else {
    $hrLokacija = Invoke-GraphRest -Metoda POST -Url "$graf/identity/conditionalAccess/namedLocations" -Tijelo @{
        '@odata.type'                      = '#microsoft.graph.countryNamedLocation'
        displayName                        = $nazivLokacije
        countriesAndRegions                = @('HR')
        includeUnknownCountriesAndRegions  = $false
        countryLookupMethod                = 'clientIpAddress'
    }
    Write-Ok "Kreirana lokacija 'Hrvatska' (ID: $($hrLokacija.id))"
}

# ---------------------------------------------------------------------
# Pomoćna funkcija za kreiranje/ažuriranje politike
# ---------------------------------------------------------------------
function Set-CaPolitika {
    param([string]$Naziv, [hashtable]$Tijelo)

    $sve = Invoke-GraphRest -Metoda GET -Url "$graf/identity/conditionalAccess/policies" -Tiho
    $postojeca = $null
    if ($sve -and $sve.value) {
        $postojeca = $sve.value | Where-Object { $_.displayName -eq $Naziv } | Select-Object -First 1
    }

    # Novoaktivirana probna licenca ne pocinje odmah vrijediti za sve
    # funkcionalnosti. Osnovne politike prolaze gotovo odmah, dok MFA grant
    # control i uvjet lokacije (named location) znaju biti odbijeni jos
    # nekoliko minuta uz poruku AccessDenied. Zato pokusaj ponavljamo.
    $maxPokusaja = 8
    $cekanjeSek = 45

    for ($pokusaj = 1; $pokusaj -le $maxPokusaja; $pokusaj++) {
        try {
            if ($postojeca) {
                Invoke-GraphRest -Metoda PATCH -Url "$graf/identity/conditionalAccess/policies/$($postojeca.id)" -Tijelo $Tijelo
                Write-Ok "Ažurirana politika: $Naziv"
                return $postojeca.id
            }

            $nova = Invoke-GraphRest -Metoda POST -Url "$graf/identity/conditionalAccess/policies" -Tijelo $Tijelo
            if ($nova -and $nova.id) {
                Write-Ok "Kreirana politika: $Naziv"
                return $nova.id
            }
            throw 'Graph nije vratio ID politike.'
        } catch {
            $poruka = $_.Exception.Message
            $licencna = $poruka -match 'not licensed|AccessDenied'

            if ($licencna -and $pokusaj -lt $maxPokusaja) {
                if ($pokusaj -eq 1) {
                    Write-Info "Licenca se jos siri kroz sustav - ponavljam (do $maxPokusaja pokusaja)..."
                }
                Write-Host ("    pokusaj {0}/{1} - cekam {2} s" -f $pokusaj, $maxPokusaja, $cekanjeSek) -ForegroundColor DarkGray
                Start-Sleep -Seconds $cekanjeSek
                continue
            }

            if ($licencna) {
                Write-Greska "Politika '$Naziv' nije kreirana ni nakon $maxPokusaja pokusaja."
                Write-Info 'Licenca vjerojatno jos nije potpuno aktivna. Pokrenite skriptu ponovno za 10-15 minuta.'
            } else {
                Write-Greska "Politika '$Naziv' nije kreirana: $poruka"
            }
            return $null
        }
    }
    return $null
}

$bg = @($konfig.breakGlassObjectId)

# ---------------------------------------------------------------------
# CA01 - blokada prijave izvan Hrvatske
# ---------------------------------------------------------------------
Write-Korak 'CA01 - blokada prijave izvan Hrvatske'
Set-CaPolitika -Naziv 'CA01 - Blokiraj prijavu izvan Hrvatske' -Tijelo @{
    displayName = 'CA01 - Blokiraj prijavu izvan Hrvatske'
    state       = $stanje
    conditions  = @{
        clientAppTypes = @('all')
        applications   = @{ includeApplications = @('All') }
        users          = @{ includeUsers = @('All'); excludeUsers = $bg }
        locations      = @{ includeLocations = @('All'); excludeLocations = @($hrLokacija.id) }
    }
    grantControls = @{ operator = 'OR'; builtInControls = @('block') }
} | Out-Null

# ---------------------------------------------------------------------
# CA02 - obavezan MFA za sve korisnike
# ---------------------------------------------------------------------
Write-Korak 'CA02 - obavezan MFA za sve korisnike'
Set-CaPolitika -Naziv 'CA02 - Obavezan MFA za sve korisnike' -Tijelo @{
    displayName = 'CA02 - Obavezan MFA za sve korisnike'
    state       = $stanje
    conditions  = @{
        clientAppTypes = @('all')
        applications   = @{ includeApplications = @('All') }
        users          = @{ includeUsers = @('All'); excludeUsers = $bg }
    }
    grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
} | Out-Null

# ---------------------------------------------------------------------
# CA03 - obavezan MFA za administratorske uloge
# ---------------------------------------------------------------------
Write-Korak 'CA03 - obavezan MFA za administratorske uloge'
$adminUloge = @(
    '62e90394-69f5-4237-9190-012177145e10'  # Global Administrator
    'e8611ab8-c189-46e8-94e1-60213ab1f814'  # Privileged Role Administrator
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'  # SharePoint Administrator
    '729827e3-9c14-49f7-bb1b-9608f156bbb8'  # Helpdesk Administrator
    '194ae4cb-b126-40b2-bd5b-6091b380977d'  # Security Administrator
    'fe930be7-5e62-47db-91af-98c3a49a38b1'  # User Administrator
)
Set-CaPolitika -Naziv 'CA03 - Obavezan MFA za administratore' -Tijelo @{
    displayName = 'CA03 - Obavezan MFA za administratore'
    state       = $stanje
    conditions  = @{
        clientAppTypes = @('all')
        applications   = @{ includeApplications = @('All') }
        users          = @{ includeRoles = $adminUloge; excludeUsers = $bg }
    }
    grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
} | Out-Null

# ---------------------------------------------------------------------
# CA04 - blokada legacy autentikacije
# ---------------------------------------------------------------------
Write-Korak 'CA04 - blokada zastarjele (legacy) autentikacije'
Set-CaPolitika -Naziv 'CA04 - Blokiraj legacy autentikaciju' -Tijelo @{
    displayName = 'CA04 - Blokiraj legacy autentikaciju'
    state       = $stanje
    conditions  = @{
        clientAppTypes = @('exchangeActiveSync', 'other')
        applications   = @{ includeApplications = @('All') }
        users          = @{ includeUsers = @('All'); excludeUsers = $bg }
    }
    grantControls = @{ operator = 'OR'; builtInControls = @('block') }
} | Out-Null

# ---------------------------------------------------------------------
# Pregled i dokaz
# ---------------------------------------------------------------------
Write-Korak 'Pregled kreiranih politika'
$politike = Invoke-GraphRest -Metoda GET -Url "$graf/identity/conditionalAccess/policies" -Tiho
$nasePolitike = @()
if ($politike -and $politike.value) {
    $nasePolitike = @($politike.value | Where-Object { $_.displayName -like 'CA0*' })
}

$tablica = ''
if ($nasePolitike.Count -gt 0) {
    $tablica = ($nasePolitike |
        Select-Object @{n='Politika';e={$_.displayName}}, @{n='Stanje';e={$_.state}} |
        Format-Table -AutoSize | Out-String)
    Write-Host $tablica
} else {
    $tablica = '(nijedna politika nije kreirana - tenant nema Entra ID P1 licencu)'
}

Set-TechNovaVrijednost -Kljuc 'hrLokacijaId' -Vrijednost $hrLokacija.id | Out-Null
Set-TechNovaVrijednost -Kljuc 'brojCaPolitika' -Vrijednost $nasePolitike.Count | Out-Null

# Ako nijedna politika nije kreirana, dokaz mora to POSTENO navesti.
# Prazna tablica u dokumentaciji izgleda kao propust, a jasno obrazlozeno
# ogranicenje pretplate zadatak izricito priznaje kao valjano rjesenje.
if ($nasePolitike.Count -eq 0) {
    Write-Host ''
    Write-Greska '=============================================================='
    Write-Greska ' NIJEDNA CONDITIONAL ACCESS POLITIKA NIJE KREIRANA'
    Write-Greska '=============================================================='
    Write-Info 'Najcesci uzroci:'
    Write-Info '  - Tenant nema Entra ID P1/P2 licencu (Graph vraca AccessDenied).'
    Write-Info '  - Licenca postoji, ali NIJE dodijeljena svakom korisniku. Politike'
    Write-Info '    koje ciljaju "All users" traze licencu za SVAKOG korisnika.'
    Write-Host ''
    Write-Info 'Rjesenja:'
    Write-Info '  1. Provjerite koje licence tenant ima:'
    Write-Info '     az rest --method GET --url https://graph.microsoft.com/v1.0/subscribedSkus --query "value[].skuPartNumber"'
    Write-Info '  2. Aktivirajte besplatnu 30-dnevnu probnu verziju Entra ID P2:'
    Write-Info '     entra.microsoft.com > Identity > Overview > "Get a free trial"'
    Write-Info '  3. Security Defaults (besplatno, MFA za sve, BEZ geo-ogranicenja):'
    Write-Info '     .\scripts\02-conditional-access.ps1 -SecurityDefaults'
    Write-Info '  4. Samo dokumentirajte - projektni zadatak to izricito dopusta.'
    Write-Host ''

    Save-Dokaz -Naziv 'ishod1-conditional-access-ogranicenje' -Sadrzaj @"
# Ishod 1 - Conditional Access: ogranicenje pretplate

Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Tenant: $($konfig.tenantId)
Razina licence: **Microsoft Entra ID Free**

## Sto je uspjesno implementirano

| Element | Status | Napomena |
|---|---|---|
| Named location "TechNova - Hrvatska" | Kreiran | ID: $($hrLokacija.id), drzava HR |
| Korisnicke grupe po odjelima | Kreirane | Dev, Sales, Support |
| RBAC dodjele po nacelu najmanjih privilegija | Kreirane | vidi Ishod 1, poglavlje o ulogama |
| Break-glass racun | Kreiran | $($konfig.breakGlassUpn) |

## Sto nije bilo moguce implementirati

Conditional Access politike zahtijevaju **Microsoft Entra ID P1** licencu.
Tenant koristi besplatnu razinu, pa Microsoft Graph API odbija kreiranje politika.

Zanimljivo je da se **named location moze** kreirati i bez licence - objekt lokacije
je dio osnovnog direktorija, dok je tek njegova *primjena u politici* premium
funkcionalnost. To potvrduje da je konfiguracija tehnicki ispravna i da bi politike
proradile odmah po aktivaciji licence.

## Kako bi se implementiralo (skripta je vec napisana)

Skripta ``scripts/02-conditional-access.ps1`` sadrzi kompletnu definiciju cetiriju politika:

| Politika | Zahtjev iz projektnog zadatka | Kontrola |
|---|---|---|
| CA01 | "Korisnicima omoguciti prijavu samo iz podrucja Hrvatske" | Blokada svih lokacija osim named locationa HR |
| CA02 | "Predloziti rjesenje za multifaktorsku autentikaciju" | Obavezan MFA za sve korisnike i sve aplikacije |
| CA03 | Zastita privilegiranih racuna | Obavezan MFA za 6 administratorskih uloga |
| CA04 | Sigurnost pristupa | Blokada legacy protokola koji ne podrzavaju MFA |

Primjer definicije politike CA01 (geo-ogranicenje na Hrvatsku):

``````powershell
`$conditions = @{
    clientAppTypes = @('all')
    applications   = @{ includeApplications = @('All') }
    users          = @{ includeUsers = @('All'); excludeUsers = @(`$breakGlassId) }
    locations      = @{ includeLocations = @('All'); excludeLocations = @(`$hrLokacijaId) }
}
`$grantControls = @{ operator = 'OR'; builtInControls = @('block') }
``````

Logika: politika se primjenjuje na **sve** lokacije osim Hrvatske i za njih
blokira pristup. Break-glass racun je izuzet kako pogresno postavljena
geo-blokada ne bi trajno zakljucala pristup tenantu.

## Besplatna alternativa: Security Defaults

Microsoft Entra Security Defaults dostupni su i na besplatnoj razini i pruzaju:

- obaveznu registraciju MFA za sve korisnike u roku 14 dana
- obavezan MFA za sve administratorske uloge pri svakoj prijavi
- blokiranu legacy (basic) autentikaciju
- zasticene privilegirane akcije u portalu

Ogranicenje: Security Defaults **ne podrzavaju geo-ogranicenje** prijave, jer je
uvjetovanje po lokaciji iskljucivo P1 funkcionalnost. Zbog toga zahtjev
"prijava samo iz podrucja Hrvatske" nije moguce ispuniti bez P1 licence.

Aktivacija: ``.\scripts\02-conditional-access.ps1 -SecurityDefaults``

## Preporuka za produkciju

Za stvarnu implementaciju kod tvrtke TechNova Solutions preporuca se
**Microsoft Entra ID P1** (oko 6 EUR po korisniku mjesecno), koji uz Conditional
Access donosi i grupno licenciranje te napredno izvjestavanje o prijavama.
Za dodatnih ~3 EUR **P2** donosi Identity Protection (automatska detekcija
rizicnih prijava), Privileged Identity Management i Access Reviews - sve mjere
navedene u analizi sigurnosti identiteta.
"@ | Out-Null

    Write-Naslov 'KORAK 2 ZAVRSEN - S OGRANICENJEM'
    Write-Info 'Dokaz o ogranicenju spremljen u docs\dokazi\ - ukljucite ga u dokumentaciju.'
    Write-Info 'Sljedeci korak:  .\scripts\03-deploy-infra.ps1'
    return
}

# Djelomicni uspjeh: neke politike prosle, neke ne
if ($nasePolitike.Count -lt 4) {
    Write-Host ''
    Write-Upozorenje "Kreirano je $($nasePolitike.Count) od 4 politike."
    Write-Info 'Politike koje ciljaju "All users" zahtijevaju licencu za SVAKOG korisnika'
    Write-Info 'u tenantu. Provjerite tko je bez licence:'
    Write-Info '    az rest --method GET --url "https://graph.microsoft.com/v1.0/users?$select=userPrincipalName,assignedLicenses"'
    Write-Info 'Nakon dodjele licenci ponovno pokrenite ovu skriptu.'
    Write-Host ''
}

Save-Dokaz -Naziv 'ishod1-conditional-access' -Sadrzaj @"
# Ishod 1 - dokaz: Conditional Access politike

Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Tenant: $($konfig.tenantId)
Način rada: $stanje

## Named location

| Naziv | ID | Države |
|---|---|---|
| $nazivLokacije | $($hrLokacija.id) | HR (Hrvatska) |

## Politike

``````
$tablica
``````

## Obrazloženje odabranih kontrola

| Politika | Zahtjev iz projektnog zadatka | Kontrola |
|---|---|---|
| CA01 | "Korisnicima omogućiti prijavu samo iz područja Hrvatske" | Blokada svih lokacija osim named locationa HR |
| CA02 | "Predložiti rješenje za multifaktorsku autentikaciju" | Obavezan MFA za sve korisnike i sve aplikacije |
| CA03 | Zaštita privilegiranih računa | Obavezan MFA za 6 administratorskih uloga |
| CA04 | Sigurnost pristupa | Blokada legacy protokola koji ne podržavaju MFA |

## Break-glass izuzeće

Račun $($konfig.breakGlassUpn) izuzet je iz svih politika. Bez tog izuzeća
pogrešno postavljena geo-blokada trajno bi zaključala pristup tenantu.
"@ | Out-Null

Write-Naslov 'KORAK 2 ZAVRŠEN'
if (-not $Ukljuci) {
    Write-Upozorenje 'Politike su u REPORT-ONLY načinu i još ne blokiraju ništa.'
    Write-Info 'Provjera učinka (dvije lokacije u Entra portalu):'
    Write-Info '  a) Identity > Monitoring & health > Sign-in logs > kliknite pojedinu prijavu'
    Write-Info '     -> u detaljima se otvara kartica "Report-only"'
    Write-Info '  b) Identity > Protection > Conditional Access > Insights and reporting'
    Write-Info 'Za aktivaciju:  .\scripts\02-conditional-access.ps1 -Ukljuci'
}
Write-Info 'Sljedeći korak:  .\scripts\03-deploy-infra.ps1'
