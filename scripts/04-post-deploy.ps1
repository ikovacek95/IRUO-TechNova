<#
.SYNOPSIS
    Korak 4 - konfiguracija koju nije moguće (ili nije praktično) izvesti Bicepom.

.DESCRIPTION
    - NSG Flow Logs + Traffic Analytics (praćenje mrežnog prometa)
    - Slanje Entra ID sign-in i audit logova u Log Analytics (revizija pristupa)
    - Uključivanje backupa oba virtualna stroja
    - Objava sadržaja interne web aplikacije na App Service
    - Proračun (budget) s upozorenjima na trošak
    - Microsoft Defender for Cloud - pregled sigurnosnog rezultata
    - Opcionalno: povezivanje na AKS i objava demo aplikacije s HPA autoscalingom

.EXAMPLE
    .\scripts\04-post-deploy.ps1

.EXAMPLE
    .\scripts\04-post-deploy.ps1 -Proracun 40 -PostaviAks
#>
[CmdletBinding()]
param(
    [int]$Proracun = 25,
    [switch]$PostaviAks,
    [switch]$PreskociFlowLogs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$konfig = Assert-TechNovaKonfig -ObavezniKljucevi @('subscriptionId', 'regija', 'resourceGroup', 'izlazi')
$izlazi = $konfig.izlazi
$rg     = $konfig.resourceGroup
$sub    = $konfig.subscriptionId
$korijen = Get-ProjektKorijen

Write-Naslov 'KORAK 4 - KONFIGURACIJA NAKON DEPLOYMENTA'

$lawId = Invoke-AzCli -Argumenti @('monitor', 'log-analytics', 'workspace', 'show',
    '--resource-group', $rg, '--workspace-name', $izlazi.logAnalyticsWorkspace, '--query', 'id', '--output', 'tsv') -Tekstualno

# =====================================================================
# 1. NSG FLOW LOGS + TRAFFIC ANALYTICS
# =====================================================================
if (-not $PreskociFlowLogs) {
    Write-Korak 'VNet Flow Logs i Traffic Analytics (praćenje mrežnog prometa)'
    # NAPOMENA: NSG flow logovi su povuceni - Azure blokira kreiranje novih
    # od 30.6.2025., a servis se gasi 30.9.2027. Nasljednik su VNet flow logovi,
    # koji pokrivaju cijelu virtualnu mrezu (sve tri podmreze odjednom) i
    # uklanjaju ogranicenja starog rjesenja.
    try {
        $nw = Invoke-AzCli -Argumenti @('network', 'watcher', 'list', '--query', "[?location=='$($konfig.regija)']") -Tiho
        if (-not $nw -or @($nw).Count -eq 0) {
            Write-Info 'Network Watcher ne postoji u ovoj regiji - kreiram ga.'
            Invoke-AzCli -Argumenti @('group', 'create', '--name', 'NetworkWatcherRG', '--location', $konfig.regija, '--output', 'none') -Tiho | Out-Null
            Invoke-AzCli -Argumenti @(
                'network', 'watcher', 'configure',
                '--resource-group', 'NetworkWatcherRG',
                '--locations', $konfig.regija,
                '--enabled', 'true'
            ) -Tiho | Out-Null
        }

        $flowStorageId = Invoke-AzCli -Argumenti @('storage', 'account', 'show',
            '--name', $izlazi.flowLogStorage, '--resource-group', $rg, '--query', 'id', '--output', 'tsv') -Tekstualno
        $vnetId = Invoke-AzCli -Argumenti @('network', 'vnet', 'show',
            '--name', "$($konfig.tvrtka)-vnet-$($konfig.okruzenje)", '--resource-group', $rg, '--query', 'id', '--output', 'tsv') -Tekstualno

        Invoke-AzCli -Argumenti @(
            'network', 'watcher', 'flow-log', 'create',
            '--location', $konfig.regija,
            '--resource-group', $rg,
            '--name', "$($konfig.tvrtka)-vnet-flowlog",
            '--vnet', $vnetId,
            '--storage-account', $flowStorageId,
            '--enabled', 'true',
            '--retention', '7',
            '--workspace', $lawId,
            '--interval', '10',
            '--traffic-analytics', 'true',
            '--output', 'none'
        ) -Tiho | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'VNet flow log uključen za cijelu mrežu (Frontend, Backend i Management).'
            Write-Ok 'Traffic Analytics aktiviran - podaci se pojavljuju za 20-30 minuta.'
        } else {
            Write-Upozorenje 'Flow log nije uključen.'
            Write-Info 'Konfigurirajte ručno: Network Watcher > Flow logs > Create > Virtual network.'
        }
    } catch {
        Write-Upozorenje "Flow logs nisu konfigurirani: $($_.Exception.Message)"
        Write-Info 'Nije kritično - konfigurirajte ručno: Network Watcher > Flow logs.'
    }
}

# =====================================================================
# 1b. DATA-PLANE PRAVA ZA VAS RACUN
# Uloga Owner NE daje pristup podacima u pohrani ni tajnama u Key Vaultu -
# to su odvojene data-plane uloge. Bez njih ne mozete pregledati spremnike
# u portalu ni snimiti screenshot sadrzaja pohrane.
# =====================================================================
Write-Korak 'Dodjela data-plane prava vašem računu'
try {
    $jaId = Invoke-AzCli -Argumenti @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv') -Tekstualno
    $storageScope = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$($izlazi.storageAccount)"
    $kvScope      = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.KeyVault/vaults/$($izlazi.keyVault)"

    $dodjele = @(
        @{ Uloga = 'Storage Blob Data Contributor';            Opseg = $storageScope }
        @{ Uloga = 'Storage File Data SMB Share Contributor';  Opseg = $storageScope }
        @{ Uloga = 'Key Vault Secrets Officer';                Opseg = $kvScope }
    )

    foreach ($d in $dodjele) {
        Invoke-AzCli -Argumenti @('role', 'assignment', 'create',
            '--assignee-object-id', $jaId,
            '--assignee-principal-type', 'User',
            '--role', $d.Uloga,
            '--scope', $d.Opseg) -Tiho | Out-Null
        Write-Ok "Dodijeljena uloga: $($d.Uloga)"
    }
} catch {
    Write-Upozorenje "Data-plane uloge nisu dodijeljene: $($_.Exception.Message)"
}

# AKS: Azure RBAC autorizacija zahtijeva zasebnu data-plane ulogu. Bez nje
# su "Workloads" i "Namespaces" u portalu prazni, a kubectl javlja
# "the server has asked for the client to provide credentials" - iako ste
# Owner pretplate. Uloga Owner pokriva samo upravljanje samim klasterom,
# ne i objektima unutar njega.
if ($izlazi.aksKlaster -and $izlazi.aksKlaster -ne 'nije deployano') {
    Write-Korak 'Dodjela prava na Kubernetes klasteru'
    try {
        $aksId = Invoke-AzCli -Argumenti @('aks', 'show', '--resource-group', $rg, '--name', $izlazi.aksKlaster, '--query', 'id', '--output', 'tsv') -Tekstualno

        foreach ($uloga in @('Azure Kubernetes Service RBAC Cluster Admin', 'Azure Kubernetes Service Cluster User Role')) {
            Invoke-AzCli -Argumenti @(
                'role', 'assignment', 'create',
                '--assignee-object-id', $jaId,
                '--assignee-principal-type', 'User',
                '--role', $uloga,
                '--scope', $aksId,
                '--output', 'none'
            ) -Tiho | Out-Null
            Write-Ok "Dodijeljena uloga: $uloga"
        }

        # Administratorska grupa klastera (za pristup preko Entra ID prijave)
        $adminGrupe = Invoke-AzCli -Argumenti @('aks', 'show', '--resource-group', $rg, '--name', $izlazi.aksKlaster, '--query', 'aadProfile.adminGroupObjectIDs', '--output', 'json') -Tiho
        foreach ($gid in @($adminGrupe)) {
            if (-not $gid) { continue }
            $clan = Invoke-AzCli -Argumenti @('ad', 'group', 'member', 'check', '--group', $gid, '--member-id', $jaId) -Tiho
            if (-not ($clan -and $clan.value -eq $true)) {
                Invoke-AzCli -Argumenti @('ad', 'group', 'member', 'add', '--group', $gid, '--member-id', $jaId) -Tiho | Out-Null
                Write-Ok 'Dodani ste u administratorsku grupu klastera.'
            }
        }
    } catch {
        Write-Upozorenje 'Prava na klasteru nisu dodijeljena. Dodijelite ulogu rucno: az role assignment create --role "Azure Kubernetes Service RBAC Cluster Admin"'
    }
}

# =====================================================================
# 2. ENTRA ID LOGOVI -> LOG ANALYTICS (revizija pristupa i aktivnosti)
# =====================================================================
Write-Korak 'Slanje Entra ID logova u Log Analytics (revizija pristupa)'
$entraUrl = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/technova-entra-to-law?api-version=2017-04-01-preview"

$puniSet = @(
    @{ category = 'AuditLogs';                     enabled = $true }
    @{ category = 'SignInLogs';                    enabled = $true }
    @{ category = 'NonInteractiveUserSignInLogs';  enabled = $true }
    @{ category = 'ServicePrincipalSignInLogs';    enabled = $true }
    @{ category = 'ManagedIdentitySignInLogs';     enabled = $true }
    @{ category = 'ProvisioningLogs';              enabled = $true }
)

$uspjeh = Invoke-ArmRest -Metoda PUT -Url $entraUrl -Tijelo @{
    properties = @{ workspaceId = $lawId; logs = $puniSet }
} -Tiho

if ($uspjeh) {
    Write-Ok 'Entra ID sign-in i audit logovi se sada šalju u Log Analytics.'
} else {
    Write-Upozorenje 'Puni set kategorija odbijen (sign-in logovi traže Entra ID P1). Pokušavam samo AuditLogs...'
    $uspjeh = Invoke-ArmRest -Metoda PUT -Url $entraUrl -Tijelo @{
        properties = @{ workspaceId = $lawId; logs = @(@{ category = 'AuditLogs'; enabled = $true }) }
    } -Tiho
    if ($uspjeh) { Write-Ok 'Audit logovi se šalju u Log Analytics.' }
    else { Write-Upozorenje 'Dijagnostika Entra ID-a nije konfigurirana - dokumentirajte kao ograničenje pretplate.' }
}

# =====================================================================
# 3. BACKUP VIRTUALNIH STROJEVA
# =====================================================================
if ($izlazi.backupVault -and $izlazi.backupVault -ne 'nije deployano') {
    Write-Korak 'Uključivanje backupa virtualnih strojeva'
    # Gen2 / Trusted Launch VM-ovi zahtijevaju Enhanced politiku. Ako standardna
    # politika ne prode, pokusavamo ugradenu 'EnhancedPolicy'.
    $politike = @("$($konfig.tvrtka)-backup-daily-$($konfig.okruzenje)", 'EnhancedPolicy', 'DefaultPolicy')

    foreach ($vm in @($izlazi.virtualniStrojevi)) {
        # Ako je VM vec zasticen, ne pokusavamo ponovno
        $vecZasticen = Invoke-AzCli -Argumenti @(
            'backup', 'item', 'list', '--resource-group', $rg,
            '--vault-name', $izlazi.backupVault,
            '--query', "[?properties.friendlyName=='$vm']"
        ) -Tiho

        if ($vecZasticen -and @($vecZasticen).Count -gt 0) {
            Write-Ok "Backup je već uključen za $vm (politika: $(@($vecZasticen)[0].properties.policyName))"
            continue
        }

        $ukljucen = $false
        foreach ($pol in $politike) {
            Invoke-AzCli -Argumenti @(
                'backup', 'protection', 'enable-for-vm',
                '--resource-group', $rg,
                '--vault-name', $izlazi.backupVault,
                '--vm', $vm,
                '--policy-name', $pol,
                '--output', 'none'
            ) -Tiho | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Backup uključen za $vm (politika: $pol)"
                $ukljucen = $true
                break
            }
        }
        if (-not $ukljucen) {
            Write-Upozorenje "Backup za $vm nije uključen - konfigurirajte ručno u portalu (Recovery Services Vault > Backup)."
        }
    }
}

# =====================================================================
# 4. OBJAVA SADRŽAJA INTERNE WEB APLIKACIJE
# =====================================================================
if ($izlazi.internaWebAplikacija -and $izlazi.internaWebAplikacija -ne 'nije deployano') {
    Write-Korak 'Objava sadržaja interne web aplikacije na App Service'
    try {
        $appMapa = Join-Path $korijen 'app'
        $zip = Join-Path $env:TEMP 'technova-app.zip'
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Compress-Archive -Path (Join-Path $appMapa '*') -DestinationPath $zip -Force

        $webAppNaziv = ([uri]$izlazi.internaWebAplikacija).Host.Split('.')[0]
        Invoke-AzCli -Argumenti @(
            'webapp', 'deploy',
            '--resource-group', $rg,
            '--name', $webAppNaziv,
            '--src-path', $zip,
            '--type', 'zip',
            '--output', 'none'
        ) -Tiho | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Aplikacija objavljena: $($izlazi.internaWebAplikacija)"
        } else {
            Write-Upozorenje 'Objava preko zip deploya nije uspjela - pokušavam postaviti početnu datoteku.'
            Invoke-AzCli -Argumenti @(
                'webapp', 'config', 'set',
                '--resource-group', $rg, '--name', $webAppNaziv,
                '--startup-file', 'php -S 0.0.0.0:8080 -t /home/site/wwwroot',
                '--output', 'none'
            ) -Tiho | Out-Null
        }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Upozorenje "Objava aplikacije nije uspjela: $($_.Exception.Message)"
    }
}

# =====================================================================
# 5. PRORAČUN (BUDGET) S UPOZORENJIMA
# =====================================================================
Write-Korak "Kreiranje proračuna od $Proracun EUR s upozorenjima"
try {
    $pocetak = (Get-Date -Day 1).ToString('yyyy-MM-01')
    $kraj    = (Get-Date -Day 1).AddYears(1).ToString('yyyy-MM-01')
    $budgetUrl = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Consumption/budgets/technova-budget-$($konfig.okruzenje)?api-version=2023-05-01"

    Invoke-ArmRest -Metoda PUT -Url $budgetUrl -Tijelo @{
        properties = @{
            category      = 'Cost'
            amount        = $Proracun
            timeGrain     = 'Monthly'
            timePeriod    = @{ startDate = $pocetak; endDate = $kraj }
            notifications = @{
                Upozorenje50 = @{ enabled = $true; operator = 'GreaterThan'; threshold = 50; contactEmails = @($konfig.alertEmail); thresholdType = 'Actual' }
                Upozorenje80 = @{ enabled = $true; operator = 'GreaterThan'; threshold = 80; contactEmails = @($konfig.alertEmail); thresholdType = 'Actual' }
                Upozorenje100 = @{ enabled = $true; operator = 'GreaterThan'; threshold = 100; contactEmails = @($konfig.alertEmail); thresholdType = 'Forecasted' }
            }
        }
    } | Out-Null
    Write-Ok "Proračun kreiran: upozorenja na 50%, 80% i prognozu od 100%."
} catch {
    Write-Upozorenje "Proračun nije kreiran: $($_.Exception.Message)"
}

# =====================================================================
# 6. MICROSOFT DEFENDER FOR CLOUD
# =====================================================================
Write-Korak 'Microsoft Defender for Cloud'
try {
    $rezultat = Invoke-AzCli -Argumenti @('security', 'secure-scores', 'show', '--name', 'ascScore') -Tiho
    if ($rezultat) {
        $postotak = [math]::Round(($rezultat.score.current / $rezultat.score.max) * 100, 1)
        Write-Ok "Secure Score: $($rezultat.score.current) / $($rezultat.score.max)  ($postotak %)"
        Set-TechNovaVrijednost -Kljuc 'secureScore' -Vrijednost $postotak | Out-Null
    } else {
        Write-Info 'Secure Score još nije izračunat (potrebno je do 24 h nakon prvog deploymenta).'
    }
} catch {
    Write-Info 'Defender for Cloud podaci još nisu dostupni.'
}
Write-Info 'Just-in-Time VM Access zahtijeva Defender for Servers Plan 2 (plaćeno).'
Write-Info 'Besplatna simulacija JIT-a je u skripti:  .\scripts\06-jit-pristup.ps1'

# =====================================================================
# 7. KUBERNETES (opcionalno)
# =====================================================================
if ($PostaviAks -and $izlazi.aksKlaster -and $izlazi.aksKlaster -ne 'nije deployano') {
    Write-Korak 'Konfiguracija AKS klastera i objava demo aplikacije'
    try {
        if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            Write-Info 'kubectl nije pronađen, instaliram...'
            Invoke-AzCli -Argumenti @('aks', 'install-cli') -Tiho | Out-Null
        }

        Invoke-AzCli -Argumenti @(
            'aks', 'get-credentials',
            '--resource-group', $rg,
            '--name', $izlazi.aksKlaster,
            '--admin', '--overwrite-existing'
        ) -Tiho | Out-Null
        Write-Ok 'Preuzeti pristupni podaci za klaster.'

        & kubectl apply -f (Join-Path $korijen 'k8s')
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Demo aplikacija objavljena na AKS-u (Deployment + Service + HPA).'
            & kubectl get all -n technova
        } else {
            Write-Upozorenje 'kubectl apply nije uspio.'
        }
    } catch {
        Write-Upozorenje "AKS konfiguracija nije dovršena: $($_.Exception.Message)"
    }
}

# =====================================================================
# DOKAZ
# =====================================================================
Write-Korak 'Prikupljanje dokaza'

$flowLogs = Invoke-AzCli -Argumenti @('network', 'watcher', 'flow-log', 'list', '--location', $konfig.regija,
    '--query', '[].{Naziv:name, Ukljucen:enabled, TrafficAnalytics:flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration.enabled}', '--output', 'table') -Tekstualno -Tiho

$backupStavke = Invoke-AzCli -Argumenti @('backup', 'item', 'list', '--resource-group', $rg,
    '--vault-name', $izlazi.backupVault, '--query', '[].{VM:properties.friendlyName, Status:properties.protectionStatus, Politika:properties.policyName}', '--output', 'table') -Tekstualno -Tiho

Save-Dokaz -Naziv 'ishod4-5-post-deploy' -Sadrzaj @"
# Dokaz: konfiguracija nakon deploymenta

Vrijeme: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

## NSG Flow Logs i Traffic Analytics

``````
$flowLogs
``````

## Backup virtualnih strojeva

``````
$backupStavke
``````

## Entra ID logovi

Dijagnostičke postavke 'technova-entra-to-law' šalju audit i sign-in logove
u Log Analytics workspace ``$($izlazi.logAnalyticsWorkspace)``.

Primjeri KQL upita za reviziju pristupa:

``````kusto
// Neuspjele prijave u zadnja 24 sata
SigninLogs
| where TimeGenerated > ago(24h) and ResultType != 0
| summarize Pokusaji = count() by UserPrincipalName, ResultDescription, Location
| order by Pokusaji desc

// Prijave izvan Hrvatske (provjera geo-ogranicenja)
SigninLogs
| where TimeGenerated > ago(7d)
| where Location != "HR"
| project TimeGenerated, UserPrincipalName, Location, IPAddress, ResultType

// Sve promjene nad grupama i ulogama
AuditLogs
| where TimeGenerated > ago(7d)
| where Category in ("GroupManagement", "RoleManagement")
| project TimeGenerated, OperationName, InitiatedBy, TargetResources
``````

## Proračun

Mjesečni proračun: $Proracun EUR, upozorenja na 50 %, 80 % i prognozu 100 %.
"@ | Out-Null

Write-Naslov 'KORAK 4 ZAVRŠEN'
Write-Info 'Sljedeći korak:  .\scripts\05-testovi.ps1'
