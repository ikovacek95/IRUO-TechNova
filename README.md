# TechNova Solutions — Azure migracija

Rješenje projektnog zadatka iz kolegija **Implementacija računarstva u oblaku**
(Sveučilište Algebra Bernays).

Cjelokupna infrastruktura definirana je **Bicep** predlošcima (Infrastructure as Code),
a automatizirana **PowerShell + Azure CLI** skriptama.

---

## Brzi start

```powershell
git clone <ovaj-repozitorij>
cd technova-azure

# Sve odjednom (25-40 min)
.\scripts\deploy-all.ps1

# Ili korak po korak
.\scripts\00-preduvjeti.ps1
.\scripts\01-identiteti.ps1
.\scripts\02-conditional-access.ps1
.\scripts\03-deploy-infra.ps1
.\scripts\04-post-deploy.ps1
.\scripts\05-testovi.ps1

# Nakon prikupljanja dokaza - obavezno!
.\scripts\99-cleanup.ps1
```

> **Napomena:** dokumentacija implementacije (PDF sa snimkama zaslona iz Azure
> portala) nije dio repozitorija jer sadrži identifikatore konkretnog okruženja —
> predaje se zasebno.

---

## Što se deploya

| Sloj | Resurs | Naziv |
|---|---|---|
| Identiteti | Entra ID grupe, korisnici, Conditional Access | `TechNova-Dev/Sales/Support` |
| Mreža | VNet s tri segmenta + 3 NSG-a | `technova-vnet-prod` |
| Balansiranje | Standard Load Balancer (HTTPS + HTTP redirect) | `technova-lb-prod` |
| Compute | 2× Ubuntu 22.04 u Availability Setu | `technova-vm1-prod`, `technova-vm2-prod` |
| Kontejneri | AKS s cluster autoscalerom | `technova-aks-prod` |
| PaaS | App Service (S1) s autoscaleom | `technova-app-prod-*` |
| Pohrana | Blob + Files, bez pristupa ključem, Hot/Cool | `technovastprod*` |
| Tajne | Key Vault (RBAC) | `technova-kv-prod-*` |
| Baza | Azure SQL, samo Entra ID autentikacija | `technova-sql-prod-*` |
| Nadzor | Log Analytics, App Insights, DCR, 5 alarma, dashboard | `technova-law-prod` |
| Oporavak | Recovery Services Vault + dnevni backup | `technova-rsv-prod` |

Sve unutar jedne Resource Grupe **`TechNova-RG`** i jedne Azure regije.

---

## Struktura repozitorija

```
technova-azure/
├─ infra/
│  ├─ main.bicep                 Ulazna točka (subscription scope)
│  ├─ probe-region.json          Provjera dostupnosti regije i veličine VM-a
│  └─ modules/                   17 modula po funkcionalnim cjelinama
├─ scripts/
│  ├─ lib/Common.ps1             Zajedničke funkcije
│  ├─ 00-preduvjeti.ps1          Alati, prijava, kvote, konfiguracija
│  ├─ 01-identiteti.ps1          Entra ID grupe, korisnici, break-glass
│  ├─ 02-conditional-access.ps1  Geo-ograničenje HR, MFA, legacy blokada
│  ├─ 03-deploy-infra.ps1        Bicep deployment
│  ├─ 04-post-deploy.ps1         Flow logs, backup, Entra logovi, proračun
│  ├─ 05-testovi.ps1             Testovi mreže, sigurnosti i performansi
│  ├─ 06-jit-pristup.ps1         Simulacija Just-in-Time pristupa
│  ├─ 99-cleanup.ps1             Potpuno uklanjanje okruženja
│  └─ deploy-all.ps1             Orkestrator svih koraka
├─ app/                          Sadržaj interne web aplikacije
└─ k8s/                          Kubernetes manifesti (Deployment, HPA, NetworkPolicy)
```

---

## Preduvjeti

- **Azure CLI** 2.60+ — `winget install -e --id Microsoft.AzureCLI`
- **PowerShell 5.1** (dio Windowsa) ili PowerShell 7+
- Azure studentska ili besplatna pretplata s vlastitim Entra ID tenantom

Nisu potrebni PowerShell moduli `Az` ni `Microsoft.Graph` — sve ide preko `az` CLI-a.

---

## Trošak

Zadana konfiguracija troši **oko 5 EUR dnevno**. Skupe komponente
(Application Gateway + WAF, Azure Bastion, Azure Firewall) isključene su po defaultu
i uključuju se prekidačima `-SAppGateway`, `-SBastion` odnosno `-SVmss`.

**Uvijek pokrenite `.\scripts\99-cleanup.ps1` nakon što prikupite dokaze.**
