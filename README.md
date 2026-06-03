# Setup_Lab_AD

Framework PowerShell de déploiement automatisé d'un Active Directory de laboratoire, conçu pour tester des outils d'audit AD. Le script promeut un Windows Server en contrôleur de domaine, puis peuple l'AD avec une structure réaliste incluant des points de risque intentionnels pour valider les capacités de détection d'un framework d'audit.

---

## Prérequis

- Windows Server 2016 / 2019 / 2022 (non promu)
- PowerShell 5.1+
- Droits Administrateur local

---

## Structure du projet

```
Setup_Lab/
├── Setup_Lab_AD.ps1          # Orchestrateur principal
├── Modules/
│   ├── Common.psm1           # Write-Log, Read-Config, Get-BuiltinGroup, Get-GroupSID
│   ├── ADStructure.psm1      # Création des OUs et groupes
│   ├── Users.psm1            # Comptes T0, standard, service
│   ├── Shares.psm1           # Partages NTFS et ACL
│   ├── Services.psm1         # Services Windows et tâches planifiées
│   └── GPO.psm1              # Niveau fonctionnel, import backups, liaison tiers
└── Configs/
    ├── ous.json              # Arborescence des OUs
    ├── groups.json           # Groupes de sécurité
    ├── users_t0.json         # Comptes Tier 0 (privilégiés)
    ├── users_standard.json   # Utilisateurs standard
    ├── users_service.json    # Comptes de service
    ├── shares.json           # Partages NTFS
    ├── services.json         # Services Windows
    ├── tasks.json            # Tâches planifiées
    ├── GPO_config.json       # (optionnel) Config GPOs de sécurité
    └── GPO/                  # (optionnel) Backups GPOs au format {GUID}
```

---

## Utilisation

### Premier lancement

```powershell
.\Setup_Lab_AD.ps1
```

Le script s'exécute en deux phases séparées par un redémarrage automatique.

**Phase 1** — Installation des rôles AD DS, DNS, DHCP, GPMC puis promotion en DC. Une tâche planifiée est enregistrée pour relancer le script au prochain logon.

**Phase 2** — Déclenchée automatiquement après le reboot. Crée toute la structure AD (OUs, groupes, comptes, partages, services, GPOs). Un second redémarrage est effectué à la fin pour que la tâche planifiée se supprime proprement.

### Paramètres

```powershell
.\Setup_Lab_AD.ps1 `
    -DomainName      "netoptima.lab" `   # Nom FQDN du domaine
    -DomainNetbios   "NETOPTIMA"     `   # Nom NetBIOS
    -SafeModePass    "P@ssw0rd123!"  `   # Mot de passe DSRM
    -DefaultUserPass "Azerty123!"        # Mot de passe des comptes de test
```

### Nettoyage manuel (optionnel)

```powershell
# Charger les fonctions
. .\Setup_Lab_AD.ps1

# Supprimer la tâche planifiée et le flag
Invoke-Cleanup
```

---

## Configuration

Tous les objets créés sont définis dans des fichiers JSON dans `Configs\`. Aucune modification du code n'est nécessaire pour adapter le lab.

### OUs — `ous.json`

```json
[
  { "Name": "Tier0", "Parent": "NETOPTIMA", "Description": "Comptes T0", "GPOTier": "Tier0" },
  { "Name": "Serveurs", "Parent": "NETOPTIMA", "Description": "Serveurs", "GPOTier": "Tier1" }
]
```

Le champ `GPOTier` est optionnel. Il permet de lier les GPOs de sécurité (si `GPO_config.json` est présent) à une OU sans avoir à connaître sa structure à l'avance. Les valeurs possibles correspondent aux clés de `TierMappings` dans `GPO_config.json` (`Tier0`, `Tier1`, `Tier2`, `Tier1_Legacy`).

### Utilisateurs Tier 0 — `users_t0.json`

```json
[
  {
    "SamAccountName": "adm_dupont",
    "GivenName": "Admin", "Surname": "Dupont",
    "Description": "Compte admin SI",
    "Enabled": true,
    "PasswordNeverExpires": true,
    "PrivilegedGroups": [ "Domain Admins", "Schema Admins" ]
  }
]
```

Les noms de groupes dans `PrivilegedGroups` sont résolus par SID — indépendant de la langue du système (`Domain Admins` fonctionne aussi bien sur un Windows FR qu'EN).

### Utilisateurs standard — `users_standard.json`

```json
[
  {
    "SamAccountName": "p.durand",
    "GivenName": "Pierre", "Surname": "Durand",
    "OU": "Direction",
    "Groups": [ "GRP_Direction", "GRP_VPN" ],
    "Description": "DG",
    "Enabled": true,
    "ForcePasswordExpired": false,
    "NeverConnected": false
  }
]
```

| Champ | Description |
|---|---|
| `OU` | Nom de l'OU de destination (doit exister dans `ous.json`) |
| `Groups` | Groupes AD à rejoindre |
| `ForcePasswordExpired` | Force `pwdLastSet = 0` pour simuler un mot de passe expiré |
| `NeverConnected` | Documentaire — le compte est créé sans jamais s'être connecté |

### Partages NTFS — `shares.json`

```json
{
  "Path": "C:\\Partages\\RH",
  "ShareName": "RH",
  "SubFolders": [ "Archives", "Documents" ],
  "ACLs": [
    { "Group": "GRP_Partage_RH", "Rights": "Modify" },
    { "Group": "Domain Admins",  "Rights": "FullControl" }
  ],
  "BrokenInheritance": {
    "SubFolder": "Archives",
    "ACLs": [
      { "Group": "GRP_Admins_SI", "Rights": "FullControl" }
    ]
  }
}
```

`BrokenInheritance` est optionnel. Quand il est présent, le sous-dossier spécifié hérite de ses propres ACL explicites (héritage bloqué), simulant une mauvaise configuration NTFS.

---

## Points de risque injectés

Le lab crée intentionnellement des situations à risque pour tester la détection par un framework d'audit :

| Risque | Détail |
|---|---|
| Compte de service dans Domain Admins | `svc_deploy` membre de `Domain Admins` |
| Compte T0 dans une tâche planifiée | `adm_dupont` utilisé dans `Audit_Deploy_Packages` |
| Groupe imbriqué | `GRP_IT` → `GRP_Admins_SI` (escalade de privilèges indirecte) |
| Compte machine dans groupe de sécurité | `DC$` → `GRP_Admins_SI` |
| Héritage NTFS cassé | `IT\Logs`, `Direction\Strategies` |
| Comptes désactivés avec groupes résiduels | `x.ancien`, `d.renard` conservent leurs appartenances |
| Héritage GPO bloqué | OUs `Tier0` et `Serveurs` |
| Mots de passe expirés | `b.dupuis`, `t.nguyen` |
| Comptes jamais connectés | `m.lebon`, `k.stein` |
| GPO désactivée liée | `GPO_Desactivee_Test` |
| GPO liée à plusieurs OUs | `GPO_Proxy_Navigation` sur `Commercial` et `Direction` |

---

## GPOs de sécurité (optionnel)

Si tu disposes de backups GPO au format `{GUID}` (compatibles avec `Import-GPO`), place-les dans `Configs\GPO\` et ajoute un `GPO_config.json` dans `Configs\`.

Le script détecte automatiquement le **niveau fonctionnel** du domaine et importe les GPOs adaptées (`Common` pour tous, `Level2016` ou `Level2025` selon le niveau).

```
Configs/
├── GPO_config.json
└── GPO/
    ├── {D40FCAEA-A277-40F6-9B6E-A2BF18E0843D}/   ← Bitlocker-Enabled
    ├── {18DDEDE5-8AC7-4F68-BD53-0F4FE82CFF6A}/   ← IPv6-Disabled
    └── ...
```

---

## Logs

Toutes les sorties sont capturées via `Start-Transcript` dès le démarrage du script, avant même le chargement des fonctions.

| Fichier | Emplacement |
|---|---|
| Transcript complet | `%USERPROFILE%\Setup_Lab\Setup_Lab_AD_transcript.log` |
| Copie après nettoyage | `<dossier_origine>\Logs\Setup_Lab_AD_transcript.log` |

---

## Compatibilité

| OS | Statut |
|---|---|
| Windows Server 2022 | ✅ Testé |
| Windows Server 2019 | ✅ Compatible |
| Windows Server 2016 | ✅ Compatible |

---

## Crédits et remerciements

Ce framework est largement inspiré du projet **[Sec_AD](https://github.com/GuyGuy-59/Sec_AD)** de [GuyGuy-59](https://github.com/GuyGuy-59), notamment pour la gestion des GPOs de sécurité par backups `{GUID}`, la détection du niveau fonctionnel et le mapping par tiers.

Un grand merci à **GuyGuy-59** pour avoir autorisé l'utilisation de son travail et pour la qualité de son framework.


---

## Licence

MIT
