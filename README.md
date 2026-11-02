# Setup_Lab_AD

Framework PowerShell de déploiement automatisé d'un Active Directory de laboratoire, conçu pour tester des outils d'audit et de détection AD.

Sur une **VM vierge**, le script promeut le serveur en contrôleur de domaine. Sur un **DC existant**, il s'adapte au domaine en place et crée ce qui manque. Dans les deux cas, il construit un environnement réaliste comprenant :

- une arborescence d'OU, des groupes, des comptes privilégiés, standard et de service ;
- une protection Tier 0 (PSO et silos d'authentification) ;
- des partages SMB classiques, un namespace DFS de domaine, des données de test et des lecteurs réseau mappés par GPO ;
- des services Windows et des tâches planifiées liés à des comptes du domaine ;
- un jeu de **GPO de sécurité** importées depuis des backups selon le niveau fonctionnel et liées par tiers (catalogue complet dans [`gpo.md`](gpo.md)) ;
- une journalisation avancée (audit, SACL, PowerShell, NTLM, Sysmon) ;
- des **points de risque volontaires** pour valider les capacités de détection d'un outil d'audit.

---

## Prérequis

- Windows Server 2016 / 2019 / 2022 / 2025, **autonome** (VM vierge) ou **déjà contrôleur de domaine**
- PowerShell 5.1
- Droits Administrateur
- Environ 5 Go d'espace disque libre en plus des données de test (4 Go par défaut)
- Pour voir les lecteurs réseau : un poste client membre du domaine

---

## Structure du projet

```
Setup_Lab_V3\
├── Setup_Lab_AD.ps1          # Orchestrateur (détection du mode, phases, résumé)
├── AGDLP.ps1                 # Script autonome : modèle AGDLP sur les partages existants
├── README.md
├── gpo.md                    # Catalogue des GPO de sécurité (paramètres détaillés)
├── Modules\
│   ├── Common.psm1           # Logs, lecture des configs, jetons {ROOT}/{DOMAIN}, résolution SID, statistiques
│   ├── ADStructure.psm1      # OUs et groupes
│   ├── Users.psm1            # Comptes Tier 0, standard et de service
│   ├── Tier0.psm1            # PSO (mots de passe affinés) et silos d'authentification
│   ├── Shares.psm1           # Dossiers NTFS, partages SMB classiques et cibles DFS cachées
│   ├── Data.psm1             # Génération de données de test dans les partages
│   ├── Dfs.psm1              # Namespace DFS de domaine, dossiers, visibilité ABE
│   ├── Services.psm1         # Services Windows et tâches planifiées
│   ├── GPO.psm1              # Niveau fonctionnel, import des GPO de sécurité, liaison par tiers
│   ├── Drives.psm1           # Lecteurs réseau par GPO (Group Policy Preferences)
│   ├── Logging.psm1          # Journalisation non native (auditpol, SACL, PowerShell, NTLM, Sysmon...)
│   └── Sysmon\               # (optionnel) Sysmon64.exe + sysmonconfig.xml
├── Configs\
│   ├── ous.json              # Arborescence des OUs ({ROOT} = OU racine) + tier GPO
│   ├── groups.json           # Groupes de sécurité
│   ├── users_t0.json         # Comptes Tier 0
│   ├── users_standard.json   # Utilisateurs standard
│   ├── users_service.json    # Comptes de service
│   ├── tier0.json            # PSO et silos d'authentification
│   ├── shares.json           # Partages NTFS / SMB / dossiers DFS
│   ├── data.json             # Données de test
│   ├── dfs.json              # Namespace DFS
│   ├── services.json         # Services Windows
│   ├── tasks.json            # Tâches planifiées
│   ├── drives.json           # Lecteurs réseau
│   ├── GPO_config.json       # GPO par niveau fonctionnel, mapping par tiers, structure GPO du lab
│   ├── audit_logging.json    # Journalisation avancée
│   └── GPO\                  # Backups GPO (Backup-GPO) : manifest.xml + dossiers {GUID}
└── Logs\                     # Transcripts copiés en fin d'exécution
```

Tous les objets sont définis dans `Configs\`. Aucune modification du code n'est nécessaire pour adapter le lab.

---

## Utilisation

```powershell
.\Setup_Lab_AD.ps1
```

### Modes de fonctionnement

Le script lit `DomainRole` et choisit son mode tout seul :

| DomainRole | Situation | Comportement |
|---|---|---|
| 2 | Serveur autonome (VM vierge) | **Nouveau domaine** : Phase 1 + Phase 2 avec redémarrages |
| 4 / 5 | Contrôleur de domaine existant | **Adaptatif** : lit le domaine, installe les rôles manquants, crée ce qui manque, sans redémarrage |
| 3 | Serveur membre d'un domaine | Arrêt sans rien modifier (le script doit tourner sur un DC) |
| 0 / 1 | Poste de travail | Arrêt sans rien modifier |

### Mode nouveau domaine (VM vierge)

**Phase 1** — Installation des rôles AD DS, DNS, DHCP, GPMC, RSAT-AD, serveur de fichiers et DFS (Namespaces + Réplication), puis promotion en DC. Une tâche planifiée `SetupLabAD_Phase2` est enregistrée pour relancer le script au prochain logon, et les paramètres (`-RootOU`, `-DefaultUserPass`, `-SkipData`) sont mémorisés pour la Phase 2.

**Phase 2** — Déclenchée automatiquement après le redémarrage. Construit tout le lab (voir l'ordre ci-dessous). Un second redémarrage permet ensuite à la tâche planifiée de se supprimer proprement.

### Mode adaptatif (DC existant)

Même commande. Le script :

- lit le FQDN, le NetBIOS et le DN depuis l'AD (`Get-ADDomain`) — les paramètres `-DomainName` / `-DomainNetbios` sont ignorés ;
- installe uniquement les rôles manquants parmi GPMC, RSAT-AD, serveur de fichiers et DFS (DNS et DHCP ne sont pas touchés) ;
- crée les objets absents et signale en jaune ceux qui existent déjà **ailleurs** que prévu (ex : un `p.durand` dans une autre OU) ;
- ne modifie jamais un partage SMB ou un namespace DFS existant, et ne réduit jamais la taille d'un journal ;
- ajoute les comptes de service au droit « Ouvrir une session en tant que service » **sans retirer** les titulaires existants ;
- se termine sans tâche planifiée ni redémarrage.

> Les comptes déjà présents gardent leur mot de passe : si un compte de service existait avec un autre mot de passe, le service ou la tâche associée échouera (signalé dans les logs).

### Ordre d'exécution (Phase 2)

1. OUs, groupes, comptes Tier 0, utilisateurs standard, comptes de service
2. Protection Tier 0 : PSO et silos d'authentification
3. Dossiers NTFS et partages SMB (classiques + cibles DFS cachées)
4. Données de test (sauf `-SkipData`)
5. Namespace DFS et dossiers DFS
6. Services Windows et tâches planifiées
7. GPO : structure du lab, import des GPO de sécurité selon le niveau fonctionnel, liaison par tiers
8. Lecteurs réseau (GPO `GPO_Lecteurs_Reseau`)
9. Journalisation avancée (en dernier : les SACL portent sur les objets créés)
10. Résumé : objets créés / existants / alertes par catégorie et points de risque injectés

Le script est **idempotent** : il peut être relancé sans risque, il complète ce qui manque.

### Paramètres

```powershell
.\Setup_Lab_AD.ps1 `
    -DomainName      "netoptima.lab" `   # FQDN (mode nouveau domaine uniquement)
    -DomainNetbios   "NETOPTIMA"     `   # NetBIOS (mode nouveau domaine uniquement)
    -SafeModePass    "P@ssw0rd123!"  `   # Mot de passe DSRM
    -DefaultUserPass "Azerty123!"    `   # Mot de passe des comptes de test
    -RootOU          "LAB"           `   # OU racine du lab (défaut : NetBIOS du domaine)
    -SkipData                            # Ne pas générer les données de test
```

```powershell
.\Setup_Lab_AD.ps1 -CleanupOnly   # Supprime tâche planifiée, flags et paramètres mémorisés
```

### Contrôles au démarrage

| Contrôle | Comportement |
|---|---|
| Version des modules | Chaque module doit contenir `# SetupLab-Version: X.Y` égal à `$ModuleVersion` de l'orchestrateur (actuellement **2.2**). Un module absent ou d'une autre version arrête le script avant toute modification |
| Format de `ous.json` | Si `ous.json` n'utilise pas le jeton `{ROOT}` (ancien format) et que `-RootOU` n'est pas fourni, le script s'arrête pour éviter de créer une arborescence en double |
| Configs optionnelles | `dfs.json` ou `audit_logging.json` absent : avertissement, la fonctionnalité est ignorée |

> En cas de mise à jour, recopier **tout** le dossier `Modules\` (et `Configs\`) : le contrôle de version empêche de mélanger anciens et nouveaux modules.

---

## Configuration

### OUs — `ous.json`

```json
[
  { "Name": "{ROOT}",   "Parent": "",       "Description": "Racine entreprise",          "GPOTier": null },
  { "Name": "Tier0",    "Parent": "{ROOT}", "Description": "Comptes privilegies Tier 0", "GPOTier": "Tier0" },
  { "Name": "Serveurs", "Parent": "{ROOT}", "Description": "Comptes machines serveurs",  "GPOTier": "Tier1" },
  { "Name": "Postes",   "Parent": "{ROOT}", "Description": "Comptes machines postes",    "GPOTier": "Tier2" }
]
```

Le jeton `{ROOT}` est remplacé par l'OU racine (`-RootOU`, ou le NetBIOS du domaine par défaut). `Parent` est une chaîne d'OU séparées par des virgules, de la plus proche à la plus haute (`"Utilisateurs,{ROOT}"`).

`GPOTier` (optionnel) lie les GPO de sécurité à l'OU selon les `TierMappings` de `GPO_config.json` (`Tier0`, `Tier1`, `Tier2`, `Tier1_Legacy`). Plusieurs OUs peuvent porter le même tier.

Arborescence par défaut :

```
{ROOT}
├── Tier0          (GPOTier = Tier0)
├── Utilisateurs
│   ├── Direction / IT / RH / Comptabilite / Commercial
├── Groupes
├── Serveurs       (GPOTier = Tier1)
│   ├── HyperV
│   └── VMs
├── Postes         (GPOTier = Tier2)
└── Services
```

### Groupes — `groups.json`

```json
{ "Name": "GRP_IT", "Scope": "Global", "Category": "Security", "Description": "Equipe IT" }
```

Les groupes sont créés dans `OU=Groupes,OU={ROOT}`.

### Comptes — `users_t0.json`, `users_standard.json`, `users_service.json`

```json
{ "SamAccountName": "adm_dupont", "GivenName": "Admin", "Surname": "Dupont",
  "Enabled": true, "PasswordNeverExpires": true,
  "PrivilegedGroups": [ "Domain Admins", "Schema Admins", "GRP_Admins_SI" ] }
```

```json
{ "SamAccountName": "p.durand", "GivenName": "Pierre", "Surname": "Durand", "OU": "Direction",
  "Groups": [ "GRP_Direction", "GRP_VPN" ], "Enabled": true,
  "ForcePasswordExpired": false, "NeverConnected": false }
```

| Champ | Description |
|---|---|
| `PrivilegedGroups` / `Groups` | Groupes à rejoindre. Les groupes intégrés sont résolus par SID : `Domain Admins` fonctionne sur un Windows français comme anglais |
| `OU` | OU de destination sous `OU=Utilisateurs,OU={ROOT}` |
| `ForcePasswordExpired` | Force `pwdLastSet = 0` (mot de passe expiré) |
| `NeverConnected` | Documentaire : le compte n'a jamais ouvert de session |

Les comptes Tier 0 vont dans `OU=Tier0`, les comptes de service dans `OU=Services` (mot de passe sans expiration, non modifiable).

### Protection Tier 0 — `tier0.json`

Deux mécanismes de protection des comptes à privilèges, indépendants des GPO :

**PSO (Password Settings Objects)** — politiques de mot de passe affinées, appliquées à un groupe ou un compte, prioritaires sur la politique de domaine. La PSO d'`Precedence` la plus basse l'emporte en cas de conflit.

```json
{ "Name": "PSO_Tier0_Admins", "Precedence": 10, "MinPasswordLength": 16,
  "ComplexityEnabled": true, "PasswordHistoryCount": 24, "MaxPasswordAge": "60.00:00:00",
  "LockoutThreshold": 5, "AppliesTo": [ "GRP_Admins_SI", "Domain Admins" ] }
```

| Champ | Description |
|---|---|
| `Precedence` | Priorité (plus bas = prioritaire) |
| `MinPasswordAge` / `MaxPasswordAge` / `Lockout*` | Durées au format TimeSpan `jours.heures:minutes:secondes` (`60.00:00:00` = 60 jours, `0.00:00:00` = jamais) |
| `AppliesTo` | Groupes ou comptes ciblés (builtin résolus par SID) |
| `Apply` | `false` pour ignorer cette PSO |

**Silos d'authentification** — un silo restreint où les comptes membres peuvent s'authentifier (ex : les admins ne peuvent ouvrir de session que depuis des machines d'administration) et raccourcit la durée de vie de leur TGT Kerberos. Nécessite un niveau fonctionnel de forêt ≥ 2012 R2.

```json
{ "Name": "Silo_Tier0", "Enforce": false, "UserTGTLifetimeMins": 240,
  "AllowedToAuthenticateFromGroup": "GRP_Admins_SI",
  "Members": [ "adm_dupont", "adm_martin", "adm_backup" ] }
```

| Champ | Description |
|---|---|
| `Enforce` | `true` = restriction appliquée ; `false` = mode **audit** (journalisé, non bloquant) |
| `UserTGTLifetimeMins` | Durée de vie du TGT des comptes du silo (240 = 4 h) |
| `AllowedToAuthenticateFromGroup` | Seuls les membres de ce groupe peuvent authentifier les comptes du silo |
| `Members` | Comptes rattachés au silo (doivent déjà exister) |

Le silo est livré en mode **audit** : il n'impose rien mais génère les événements, ce qui évite de se verrouiller hors du lab. Passer `Enforce` à `true` pour l'appliquer réellement.

### Partages — `shares.json`

Chaque entrée crée un dossier NTFS, un **partage SMB classique** (`\\SERVEUR\RH`) et, si `Dfs` est présent, un **partage caché** (`RH$`) qui sert de cible au dossier DFS (`\\domaine\Partages\RH`). Les deux accès coexistent, comme souvent en production.

```json
{
  "Path": "C:\\Partages\\RH",
  "ShareName": "RH",
  "Description": "Ressources humaines",
  "SubFolders": [ "Archives", "Documents", "Contrats" ],
  "DisableRootInheritance": true,
  "ACLs": [
    { "Group": "GRP_Partage_RH", "Rights": "Modify" },
    { "Group": "Domain Admins",  "Rights": "FullControl" }
  ],
  "BrokenInheritance": null,
  "SharePermissions": null,
  "ABE": true,
  "Dfs": { "Folder": "RH", "VisibleTo": [ "GRP_Partage_RH", "GRP_Direction" ] }
}
```

| Champ | Description |
|---|---|
| `DisableRootInheritance` | `true` (défaut) : coupe l'héritage de `C:\` (SYSTEM + Administrators ajoutés). `false` : `BUILTIN\Users` hérite du droit de créer des dossiers |
| `ACLs` | Droits NTFS du dossier racine (`FullControl`, `Modify`, `ReadAndExecute`...) |
| `BrokenInheritance` | Sous-dossier dont l'héritage est coupé, avec ses propres ACL |
| `SharePermissions` | Permissions du partage classique : `[{ "Account": "...", "Access": "Full\|Change\|Read" }]`. `null` = Domain Admins Full + Authenticated Users Change (le NTFS gouverne) |
| `ABE` | Access-Based Enumeration sur le partage classique |
| `Dfs.Folder` | Nom du dossier dans le namespace (défaut : `ShareName`) |
| `Dfs.TargetShare` | Nom du partage cible (défaut : `ShareName$`) |
| `Dfs.TargetSharePermissions` / `Dfs.TargetABE` | Permissions et ABE du partage cible (défaut : comme ci-dessus, ABE actif) |
| `Dfs.VisibleTo` | Comptes qui **voient** le dossier DFS quand l'ABE du namespace est actif. Absent = visible par tous |
| `Dfs.ExtraTargets` | Cibles supplémentaires `[{ "Path": "\\\\SRV\\Partage$", "State": "Online\|Offline" }]` |

Les noms de comptes acceptent les groupes du domaine, les groupes intégrés en anglais (`Domain Admins`, `Administrators`...) et les principaux bien connus (`Everyone`, `Authenticated Users`).

> La visibilité DFS (`VisibleTo`) est indépendante des droits NTFS de la cible. C'est volontaire : ça permet de créer des incohérences « visible mais accès refusé ».

### Données de test — `data.json`

Remplit les partages avec des fichiers pour donner de la volumétrie au lab (sauvegarde, chiffrement massif / ransomware, DLP, données dormantes).

```json
{ "Share": "Comptabilite", "SizeMB": 1024, "YearFolders": true,
  "Names": [ "Facture", "Bilan", "Note_de_frais" ], "Extensions": [ ".xlsx", ".pdf", ".csv" ] }
```

| Champ | Description |
|---|---|
| `SizeMB` | Taille cible du partage. Le script **complète** jusqu'à cette taille : relancer ne regénère pas l'existant |
| `Names` / `Extensions` | Noms métier tirés au hasard → `Facture_2024-03_0417.xlsx` |
| `YearFolders` | Range les fichiers par année (`Factures\2024\...`) |
| `Apply` | `false` pour ignorer ce partage |
| `MinFileSizeMB` / `MaxFileSizeMB` | Taille des fichiers (global, 1 à 5 Mo par défaut) |
| `MaxAgeDays` | Dates de création/modification étalées sur cette période (3 ans par défaut) |
| `MinFreeSpaceGB` | Marge disque : la génération s'arrête avant de descendre sous ce seuil (5 Go par défaut) |

Le contenu est aléatoire (incompressible, non dédupliquable) : les fichiers ne s'ouvrent pas, seuls les noms et extensions sont réalistes. Ils sont répartis entre la racine et les `SubFolders` de chaque partage et héritent des ACL NTFS. Volume par défaut : environ 4 Go, quelques minutes de génération. Pour sauter l'étape : `-SkipData`.

### Namespace DFS — `dfs.json`

```json
{
  "Enabled": true,
  "NamespaceName": "Partages",
  "RootFolder": "C:\\DFSRoots\\Partages",
  "Description": "Espace de noms DFS des partages du lab",
  "EnableABE": true
}
```

Crée un namespace de domaine (DomainV2) `\\<domaine>\Partages` dont les dossiers sont définis par le bloc `Dfs` de `shares.json`. La réplication DFS-R n'est pas configurée : elle nécessite un second serveur, déclarable via `ExtraTargets`.

### Services et tâches — `services.json`, `tasks.json`

```json
{ "Name": "AuditLab_SQL", "DisplayName": "Audit Lab - Service SQL", "Description": "...", "Account": "svc_sql" }
{ "Name": "Audit_Deploy_Packages", "Description": "...", "Account": "adm_dupont", "TriggerTime": "02:00" }
```

Les services exécutent un script PowerShell en boucle sous le compte indiqué. `powershell.exe` ne répondant pas au gestionnaire de services, ils apparaissent **« Not started »** : c'est attendu, seule leur configuration (compte, binaire) sert aux tests d'audit.

---

## GPO

Le framework gère trois familles de GPO, toutes pilotées par `GPO_config.json` (sauf les lecteurs réseau) :

| Famille | Source | Section de config |
|---|---|---|
| **GPO de sécurité** | Backups `{GUID}` de `Configs\GPO\` | `GPOs` + `TierMappings` |
| Structure GPO du lab | Créées par le script (backup du même nom importé s'il existe) | `LabGPOs` |
| Lecteurs réseau | Générée à chaque lancement | `drives.json` |

### GPO de sécurité — sections `GPOs` et `TierMappings`

Ce sont les GPO effectivement déployées par le framework. Leur paramétrage détaillé (valeurs vérifiées depuis les `gpreport.xml`) est documenté dans **[`gpo.md`](gpo.md)**.

**1. Sélection selon le niveau fonctionnel de la forêt**

| Niveau fonctionnel de forêt | GPO importées |
|---|---|
| ≤ 2016 (Server 2016, 2019, 2022) | `Common` + `Level2016` (41 GPO) |
| ≥ 2025 (Server 2025) | `Common` + `Level2025` (42 GPO) |

> Windows Server 2019 et 2022 n'introduisent pas de nouveau niveau fonctionnel : un domaine créé sur ces OS est au niveau 2016 et reçoit donc les GPO `Level2016`.

**2. Import** — chaque backup est identifié par le nom de GPO contenu dans son `gpreport.xml`, puis importé avec `Import-GPO -CreateIfNeeded`. Une GPO déjà présente dans le domaine n'est pas réimportée. Une GPO sans backup est signalée en jaune et ignorée.

**3. Liaison par tiers** — chaque OU portant un `GPOTier` dans `ous.json` reçoit les GPO du tier correspondant dans `TierMappings` :

| Tier | OU par défaut | GPO liées |
|---|---|---|
| `Tier0` | `Tier0` | Toutes les GPO `Common` sauf `Logs-Advanced-Workstation-Enabled` |
| `Tier1` | `Serveurs` | Toutes les GPO `Common` sauf `Logs-Advanced-Workstation-Enabled` |
| `Tier2` | `Postes` | Toutes les GPO `Common` sauf `Logs-Advanced-Server-Enabled` |
| `Tier1_Legacy` | — (aucune OU par défaut) | Identique à `Tier1` |

> Les GPO `Level2016` / `Level2025` sont importées mais ne figurent dans aucun `TierMappings` : elles restent **non liées** tant qu'elles n'y sont pas ajoutées.

#### Catalogue des GPO de sécurité

**Common** (tous niveaux) — 39 GPO

| Domaine | GPO | Effet principal |
|---|---|---|
| Authentification Kerberos | `Kerberos-AES-Enabled` | AES128/AES256 uniquement, RC4 et DES désactivés |
| | `Kerberos-Armoring-Enabled` | Kerberos FAST (armoring) côté KDC et client |
| Authentification NTLM | `NTLM-Audit-Enabled` | Audit NTLM entrant et dans le domaine |
| | `NTLM-Disabled` | Restrict NTLM dans le domaine : **Deny all** |
| | `NTLM1-LM-Disabled` | `LmCompatibilityLevel = 5` (NTLMv2 uniquement), pas de session nulle |
| | `NTLMv2-128bits-Required` | Sécurité de session NTLMv2 + 128 bits (client et serveur) |
| | `Wdigest-Disabled` | `UseLogonCredential = 0` |
| | `MSCache-Disabled` | `CachedLogonsCount = 1` |
| LDAP | `LDAP-Client-Signing-Required` | Signature LDAP exigée côté client |
| | `LDAP-Server-Signing-Required` | Signature LDAP exigée sur les DC |
| | `LDAP-CBT-Enabled` | Channel Binding Token LDAP : Always |
| SMB | `SMB-Client-Signing-Enabled` | Signature SMB client toujours, pas de mot de passe en clair |
| | `SMB-Server-Signing-Enabled` | Signature SMB serveur toujours |
| | `SMBv1-Disabled` | `SMB1 = 0` |
| Netlogon / RPC | `Secure-NetLogon` | Signature/scellement du canal sécurisé, clé forte, rotation 30 j |
| | `RPC-Hardened` | Authentification Endpoint Mapper, clients RPC non authentifiés refusés |
| | `UNC-Paths-Hardened` | Authentification mutuelle + intégrité sur `\\*\SYSVOL` et `\\*\NETLOGON` |
| Résolution de noms / réseau | `LLMNR-Disabled` | LLMNR désactivé |
| | `mDNS-Disabled` | `EnableMDNS = 0` |
| | `SSDP-Disabled` | Service SSDPSRV désactivé |
| | `IPv6-Disabled` | `DisabledComponents = 0xFF` |
| | `WPAD-Computer-Disabled` | `DisableWpad = 1` (contexte machine) |
| | `WPAD-User-Disabled` | `AutoDetect = 0` (contexte utilisateur) |
| | `WebProxyAutoDiscovery-Disabled` | Service WinHttpAutoProxySvc désactivé |
| | `Proxy-Change-Disabled` | Modification du proxy interdite aux utilisateurs |
| | `TLS-Hardened` | SSL 3.0, TLS 1.0 et 1.1 désactivés (client et serveur) |
| RDP | `RDP-NLA-Enabled` | NLA obligatoire |
| | `RDP-hijacking-Mitigation` | Pas de mot de passe enregistré, sessions déconnectées fermées après 1 min |
| Poste / exécution | `Applocker-Enabled` | Règles AppLocker (éditeur / chemin / hash) |
| | `ASR-Exploit-Guard` | 19 règles ASR Defender en mode blocage (LSASS, macros Office, PsExec/WMI, ransomware...) |
| | `Powershell-Hardened` | Module logging `*`, Script Block logging, transcription, RemoteSigned |
| | `WScript-Disabled` | Windows Script Host désactivé |
| | `UAC-Hardened` | UAC renforcé, bureau sécurisé, filtrage du token administrateur |
| | `ScreenLock-enabled` | Écran de veille protégé par mot de passe après 600 s |
| | `Bitlocker-Enabled` | XTS-AES 256, TPM requis, recouvrement stocké dans AD DS |
| | `LAPS-Enabled` | Windows LAPS : sauvegarde AD chiffrée, 14 caractères, rotation 1 j |
| | `Bloodhound-Mitigation` | ACL `SrvsvcSessionInfo` restreinte (énumération des sessions) |
| Journalisation | `Logs-Advanced-Server-Enabled` | Stratégie d'audit avancée serveurs (logon, Kerberos, DS, process...) |
| | `Logs-Advanced-Workstation-Enabled` | Stratégie d'audit avancée postes |

**Level2016** (niveau ≤ 2016) — 2 GPO

| GPO | Effet principal |
|---|---|
| `LMHASH-Disabled` | `NoLMHash = 1` |
| `NBT-NS-Disabled` | Script de démarrage `NBT-NS-Disabled.ps1` désactivant NetBIOS over TCP/IP |

**Level2025** (niveau ≥ 2025) — 3 GPO

| GPO | Effet principal |
|---|---|
| `NBT-NS-New-Disabled` | Paramètre natif « Configure NetBIOS settings » : résolution NetBIOS désactivée |
| `SMB-NTLM-Disabled` | Le client SMB n'utilise plus NTLM |
| `SMB-Client-Encrypt-Required` | Chiffrement SMB exigé côté client |

> **Précautions en lab :** `NTLM-Disabled` (Deny all), `Applocker-Enabled`, `Bitlocker-Enabled` (TPM requis) et `IPv6-Disabled` peuvent casser des usages légitimes sur les machines placées dans les OUs liées. Retirer la GPO du `TierMappings` concerné pour l'exclure. Pour `LAPS-Enabled`, renseigner les lecteurs autorisés dans « Configure authorized password decryptors ».

> **Git :** si le projet est versionné, vérifier que `Configs/GPO` n'est pas exclu par `.gitignore`, et ajouter un `.gitattributes` contenant `Configs/GPO/** binary` pour éviter que la conversion des fins de ligne n'abîme les `Registry.pol` / `GptTmpl.inf`.

**Ajouter une GPO de sécurité :** la configurer dans GPMC, l'exporter (`Backup-GPO -Name ... -Path .\Configs\GPO`), l'ajouter à la bonne liste de `GPOs` (`Common`, `Level2016` ou `Level2025`) puis aux `TierMappings` voulus, et la documenter dans `gpo.md`. Garder des paramètres génériques (sans SID ni chemin UNC du domaine) pour que le backup reste utilisable sur n'importe quel domaine.

### Structure GPO du lab — section `LabGPOs`

Cette section ne sert pas à durcir le domaine mais à reproduire une **topologie GPO réaliste** (liaisons multiples, liaison appliquée, GPO désactivée, héritage bloqué) que l'outil d'audit doit savoir analyser. Une GPO de cette liste est importée depuis `Configs\GPO\` si un backup du même nom existe ; sinon elle est **créée vide** (signalé en jaune).

```json
"LabGPOs": {
    "gpos": [
        { "Name": "GPO_Serveurs_Hardening", "Comment": "Durcissement des serveurs",
          "LinkTo": [ "OU=Serveurs,OU={ROOT},{DOMAIN}" ], "Enforced": true, "Status": "UserSettingsDisabled" },
        { "Name": "GPO_Desactivee_Test", "LinkTo": [], "Disabled": true }
    ],
    "BlockInheritance": [ "OU=Tier0,OU={ROOT},{DOMAIN}", "OU=Serveurs,OU={ROOT},{DOMAIN}" ]
}
```

| Champ | Description |
|---|---|
| `LinkTo` | Emplacements liés (DN avec jetons `{ROOT}` / `{DOMAIN}`). Vide = non liée |
| `Enforced` | Liaison « Appliquée » |
| `Status` | `UserSettingsDisabled`, `ComputerSettingsDisabled` ou `AllSettingsEnabled` |
| `Disabled` | `true` = GPO entièrement désactivée |
| `BlockInheritance` | OUs dont l'héritage GPO est bloqué |

Les liaisons, l'état et le blocage d'héritage sont gérés par le script car un backup GPO ne les contient pas. Une GPO déjà présente mais vide reçoit son backup au lancement suivant si celui-ci a été ajouté entre-temps.

> Le blocage d'héritage sur `Tier0` et `Serveurs` n'empêche pas les GPO de sécurité de s'y appliquer : elles sont liées **directement** à ces OUs par `TierMappings`.

### Lecteurs réseau — `drives.json`

Les lecteurs sont mappés comme en production : une GPO utilisateur `GPO_Lecteurs_Reseau` contenant des préférences « Mappages de lecteurs » (`User\Preferences\Drives\Drives.xml` dans SYSVOL), liée à l'OU `Utilisateurs`, avec un ciblage par groupe.

```json
{ "Letter": "R", "Label": "RH", "Share": "RH", "Via": "Dfs", "Groups": [ "GRP_Partage_RH", "GRP_Direction" ] }
```

| Champ | Description |
|---|---|
| `Share` | `ShareName` d'une entrée de `shares.json` |
| `Via` | `Dfs` (défaut) : `\\domaine\Partages\RH` — `Smb` : `\\serveur\RH` |
| `Path` | Chemin libre à la place de `Share`/`Via`, jetons `{SERVER}` et `{DOMAIN}` |
| `Groups` | Mappé uniquement pour les membres d'au moins un de ces groupes (imbrication comprise). Absent = tous |

| Lettre | Cible | Pour |
|---|---|---|
| S: | `\\domaine\Partages\Commun` | Tous |
| R: | `\\domaine\Partages\RH` | GRP_Partage_RH, GRP_Direction |
| T: | `\\domaine\Partages\Comptabilite` | GRP_Partage_Compta, GRP_Direction |
| I: | `\\domaine\Partages\IT` | GRP_IT |
| P: | `\\serveur\Direction` (accès direct, **risque**) | GRP_Direction |
| Z: | `\\serveur\C$` (partage administratif, **risque**) | GRP_IT |

Cette GPO est **générée** à chaque lancement (pas de backup) car son contenu dépend du domaine (chemins, SID des groupes). Le fichier n'est réécrit, et la version de la GPO incrémentée, que si la configuration a changé. Les lecteurs apparaissent à la prochaine ouverture de session **sur un poste membre** : les utilisateurs standard ne peuvent pas ouvrir de session sur un DC.

---

## Journalisation — `audit_logging.json`

Active ce que Windows Server ne journalise pas nativement. Chaque section est optionnelle et chaque entrée peut être désactivée avec `"Apply": false` (les options très verbeuses sont livrées désactivées).

| Section | Contenu |
|---|---|
| `Registry` | PowerShell (Script Block 4104, Module 4103, transcription dans `C:\Logs\PSTranscripts`), ligne de commande dans 4688, audit NTLM entrant/sortant/domaine (8001-8004, **audit seul**), binds LDAP non signés (2889), mode audit LSA Protection (3065/3066). Désactivés : Field Engineering (1644), Kerberos LogLevel, Schannel |
| `AdvancedAudit` | 36 sous-catégories `auditpol` (Kerberos, gestion des comptes, 5136, 4688, 5140/5145, 4698, 4697...) identifiées **par GUID** (indépendant de la langue), avec `SCENoApplyLegacyAuditPolicy = 1` |
| `EventLogs` | Active les journaux désactivés par défaut (TaskScheduler, NTLM, Kerberos, DNS-Client, CAPI2, USB...) et agrandit Security (1 Go), PowerShell, Directory Service, Sysmon. Désactivé : DNS Server Analytical |
| `FileSystemSacl` | SACL sur `C:\Partages` et `SYSVOL\Policies` (sans SACL, l'audit File System ne produit rien) |
| `DirectorySacl` | SACL AD : modifications dans l'OU racine (5136), droits étendus sur le domaine (4662, détection DCSync), AdminSDHolder |
| `Smb` | `AuditSmb1Access` et, sur Server 2025, audit des clients sans signature/chiffrement (paramètres non supportés ignorés) |
| `Firewall` | Journal des paquets bloqués du pare-feu Windows |
| `Netlogon` | Journal debug `netlogon.log` (désactivé par défaut) |
| `Sysmon` | Installation non interactive si le binaire est présent (voir ci-dessous) |

> La configuration est appliquée en local sur le DC. Si une GPO liée à l'OU Domain Controllers définit une stratégie d'audit avancée, elle prendra le dessus au prochain `gpupdate`.

### Sysmon

1. Télécharger Sysmon : https://learn.microsoft.com/sysinternals/downloads/sysmon
2. Déposer `Sysmon64.exe` dans `Modules\Sysmon\`, avec une configuration nommée `sysmonconfig.xml` (ex : SwiftOnSecurity ou olafhartong/sysmon-modular). Sans fichier XML, Sysmon utilise sa configuration par défaut, très minimale.
3. Lancer le script, qui exécute l'équivalent de :

```powershell
Modules\Sysmon\Sysmon64.exe -accepteula -i Modules\Sysmon\sysmonconfig.xml   # première installation
Modules\Sysmon\Sysmon64.exe -accepteula -c Modules\Sysmon\sysmonconfig.xml   # déjà installé : mise à jour de la config
```

La signature Authenticode du binaire est vérifiée (Microsoft) avant exécution. Si le binaire est absent, l'étape est ignorée.

---

## Script complémentaire — `AGDLP.ps1`

Script **autonome** (non appelé par l'orchestrateur) qui met en place le modèle AGDLP sur les partages SMB existants du serveur, par découverte : aucune ressource n'est codée en dur.

Pour chaque partage non administratif (hors `NETLOGON`, `SYSVOL` et partages `$`) :

1. crée le groupe global `GG_<Partage>` ;
2. le peuple avec les utilisateurs d'une OU du même nom si elle existe (sinon groupe vide) ;
3. crée cinq groupes domaine local par niveau d'accès :

| Groupe | Type | Droits |
|---|---|---|
| `DL_<Partage>_RO` | Allow | ReadAndExecute |
| `DL_<Partage>_RW` | Allow | Modify |
| `DL_<Partage>_CT` | Allow | FullControl |
| `DL_<Partage>_DEL` | Allow | Delete + DeleteSubdirectoriesAndFiles |
| `DL_<Partage>_DENY` | Deny | Delete + DeleteSubdirectoriesAndFiles |

4. imbrique `GG_<Partage>` dans `DL_<Partage>_RW` ;
5. applique une ACL **exclusive** sur le dossier : héritage cassé, seuls SYSTEM, Administrateurs et les groupes DL sont conservés, propriétaire = Administrateurs ;
6. signale les comptes présents à la fois dans `_DENY` et dans un groupe autorisé à supprimer (le refus l'emporte).

```powershell
.\AGDLP.ps1                       # groupes + ACL
.\AGDLP.ps1 -NoAcl                # groupes uniquement
.\AGDLP.ps1 -WhatIfAcl            # affiche les ACL cibles sans les écrire
.\AGDLP.ps1 -GroupsOU "OU=Groupes,OU=LAB,DC=lab,DC=ap" -UsersParentOU "OU=Utilisateurs,OU=LAB,DC=lab,DC=ap"
```

| Paramètre | Défaut |
|---|---|
| `-GroupsOU` | `CN=Users,<domaine>` |
| `-UsersParentOU` | Tout le domaine |
| `-GlobalPrefix` / `-DomainLocalPrefix` | `GG_` / `DL_` |
| `-ExcludeShares` | `NETLOGON`, `SYSVOL` |

> ⚠️ L'ACL exclusive **remplace** les ACL posées par `Setup_Lab_AD.ps1` : elle supprime les points de risque NTFS injectés (héritage cassé, héritage de `C:\` sur `Commun`, ACL `GRP_*`). La lancer d'abord avec `-WhatIfAcl`, ou avec `-NoAcl` pour garder le lab intact.

---

## Points de risque injectés

| Catégorie | Risque | Détail |
|---|---|---|
| Comptes | Compte de service dans Domain Admins | `svc_deploy` |
| Comptes | Compte T0 dans une tâche planifiée | `adm_dupont` (Domain Admins + Schema Admins) dans `Audit_Deploy_Packages` |
| Comptes | Comptes désactivés avec groupes résiduels | `x.ancien`, `d.renard` (dont `GRP_Admins_Domaine`), `adm_old_svc` (Domain Admins) |
| Comptes | Mots de passe expirés | `b.dupuis`, `t.nguyen` |
| Comptes | Comptes jamais connectés | `m.lebon`, `k.stein` |
| Comptes | Mots de passe sans expiration | Comptes Tier 0 et comptes de service |
| PSO | Politique de mot de passe faible | `PSO_VPN_Faible` : 6 caractères, sans complexité, chiffrement réversible |
| PSO | PSO à privilèges trop permissive | `PSO_Comptes_Service` : mot de passe jamais expiré, pas de verrouillage |
| Silo | Silo T0 en mode audit | `Silo_Tier0` non appliqué (`Enforce=false`) |
| Silo | Compte T0 hors silo | `svc_deploy` (Domain Admins) non rattaché à `Silo_Tier0` |
| Groupes | Imbrication donnant des privilèges indirects | `GRP_IT` → `GRP_Admins_SI`, et `Domain Users` → `GRP_IT` |
| Groupes | Compte machine dans un groupe de sécurité | `<DC>$` → `GRP_Admins_SI` |
| NTFS | Héritage cassé | `IT\Logs`, `Direction\Strategies` |
| NTFS | Héritage de `C:\` conservé | `Commun` (`BUILTIN\Users` peut créer des dossiers) |
| Partages | Permissions de partage trop larges | Partage classique `Direction` : `Everyone` Full |
| Partages | Partages hébergés sur le DC | Partages SMB et namespace DFS sur le contrôleur de domaine |
| DFS | Incohérence ABE / NTFS | `Comptabilite` visible par `GRP_Commercial` sans droit NTFS |
| DFS | Dossier non restreint + cible obsolète | `Direction` visible par tous, cible `\\FS-OLD01\Direction$` hors ligne |
| Lecteurs | Lecteur contournant le DFS | `P:` → `\\serveur\Direction` (partage Everyone Full) |
| Lecteurs | Lecteur vers partage administratif | `Z:` → `\\serveur\C$` pour GRP_IT |
| GPO | Héritage bloqué | OUs `Tier0` et `Serveurs` |
| GPO | GPO liée à plusieurs OUs | `GPO_Proxy_Navigation` sur `Commercial` et `Direction` |
| GPO | GPO désactivée et non liée | `GPO_Desactivee_Test` |
| GPO | GPO de sécurité non liées | GPO `Level2016` / `Level2025` importées mais absentes des `TierMappings` |

---

## Vérifications utiles

```powershell
# Partages SMB (classiques + cibles cachées) et ABE
Get-SmbShare | Where-Object { -not $_.Special } | Format-Table Name, Path, FolderEnumerationMode

# Namespace DFS, dossiers et cibles
Get-DfsnRoot -Domain (Get-ADDomain).DNSRoot
Get-DfsnFolder -Path "\\$((Get-ADDomain).DNSRoot)\Partages\*" | ForEach-Object { Get-DfsnFolderTarget -Path $_.Path } |
    Format-Table Path, TargetPath, State

# Volume de données par partage
Get-ChildItem C:\Partages -Directory | ForEach-Object {
    "{0,-14} {1,8:N0} Mo" -f $_.Name, ((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB) }

# PSO et silos
Get-ADFineGrainedPasswordPolicy -Filter * | Format-Table Name, Precedence, MinPasswordLength, MaxPasswordAge
Get-ADAuthenticationPolicySilo -Filter * | Format-Table Name, Enforce
Get-ADUser adm_dupont -Properties AuthenticationPolicySilo | Select-Object Name, AuthenticationPolicySilo

# Niveau fonctionnel et GPO de sécurité présentes
(Get-ADForest).ForestMode
Get-GPO -All | Sort-Object DisplayName | Format-Table DisplayName, GpoStatus, ModificationTime

# GPO liées à une OU de tier
(Get-GPInheritance -Target "OU=Serveurs,OU=$((Get-ADDomain).NetBIOSName),$((Get-ADDomain).DistinguishedName)").GpoLinks |
    Format-Table DisplayName, Enabled, Enforced, Order

# Stratégie d'audit appliquée
auditpol /get /category:*

# Lecteurs réseau (sur un poste client, session d'un utilisateur du lab)
gpresult /r /scope user
```

Dans GPMC, `GPO_Lecteurs_Reseau` → Paramètres → Configuration utilisateur → Préférences → Mappages de lecteurs doit lister les 6 lecteurs.

---

## Logs

Toutes les sorties sont capturées via `Start-Transcript` dès le démarrage du script.

| Fichier | Emplacement |
|---|---|
| Transcript complet | `%USERPROFILE%\Setup_Lab\Setup_Lab_AD_transcript.log` |
| Copie après nettoyage | `<dossier_origine>\Logs\Setup_Lab_AD_transcript.log` |

Le script se copie (avec `Modules\` et `Configs\`) dans `%USERPROFILE%\Setup_Lab` à chaque lancement : c'est cette copie qui est exécutée.

---

## Compatibilité

| OS | Statut |
|---|---|
| Windows Server 2025 | ✅ Testé (mode adaptatif) |
| Windows Server 2022 | ✅ Testé |
| Windows Server 2019 | ✅ Compatible |
| Windows Server 2016 | ✅ Compatible |

---

## Crédits et remerciements

Ce framework est largement inspiré du projet **[Sec_AD](https://github.com/GuyGuy-59/Sec_AD)** de [GuyGuy-59](https://github.com/GuyGuy-59), notamment pour le catalogue de GPO de sécurité, leur gestion par backups `{GUID}`, la détection du niveau fonctionnel et le mapping par tiers.

Un grand merci à **GuyGuy-59** pour avoir autorisé l'utilisation de son travail et pour la qualité de son framework.

---

## Licence

MIT
