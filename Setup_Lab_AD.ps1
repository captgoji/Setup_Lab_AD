# ==============================================================================
# Setup_Lab_AD.ps1 - Orchestrateur
#
# Le script detecte l'etat du serveur (DomainRole) et choisit son mode :
#
#   Serveur autonome (VM vierge)  -> MODE NOUVEAU DOMAINE
#       Phase 1 : roles + promotion DC + tache de relance + reboot
#       Phase 2 : population AD (relancee automatiquement au logon) + reboot
#       Nettoyage : tache/flags supprimes au logon suivant
#
#   Controleur de domaine existant -> MODE ADAPTATIF
#       Lecture du domaine (FQDN, NetBIOS, DN), installation des roles
#       manquants (serveur de fichiers, DFS), creation de ce qui manque.
#       Pas de tache planifiee, pas de reboot.
#
#   Serveur/poste membre ou poste de travail -> arret (rien n'est modifie)
#
# CONFIGURATION : editer uniquement les fichiers dans Configs\
# NETTOYAGE     : .\Setup_Lab_AD.ps1 -CleanupOnly
# ==============================================================================

#Requires -RunAsAdministrator

param(
    [string]$DomainName      = "netoptima.lab",   # utilise uniquement en mode nouveau domaine
    [string]$DomainNetbios   = "NETOPTIMA",       # idem
    [string]$SafeModePass    = "P@ssw0rd123!",
    [string]$DefaultUserPass = "Azerty123!",
    [string]$RootOU          = "",                # vide = nom NetBIOS du domaine
    [switch]$SkipData,                            # ne pas generer les donnees de test (Configs\data.json)
    [switch]$CleanupOnly
)

$ErrorActionPreference = "Stop"
$SetupRoot      = "$env:USERPROFILE\Setup_Lab"
$ScriptPath     = "$SetupRoot\Setup_Lab_AD.ps1"
$ModulesDir     = "$SetupRoot\Modules"
$ConfigDir      = "$SetupRoot\Configs"
$GPOConfigFile  = "$ConfigDir\GPO_config.json"
$GPOBackupPath  = "$ConfigDir\GPO"
$TranscriptFile = "$SetupRoot\Setup_Lab_AD_transcript.log"
$FlagPhase1     = "$SetupRoot\phase1_done"
$FlagPhase2     = "$SetupRoot\phase2_done"
$OriginFile     = "$SetupRoot\origin_path.txt"
$ParamsFile     = "$SetupRoot\run_params.json"
$TaskName       = "SetupLabAD_Phase2"
$ModuleVersion  = "2.2"   # doit correspondre a "# SetupLab-Version:" dans chaque module
$BoundParams    = $PSBoundParameters
$script:DomainDN = $null
$script:Mode     = $null

# Roles installes en Phase 1 (VM vierge)
$FeaturesNewDomain = @("AD-Domain-Services","GPMC","RSAT-AD-PowerShell","DNS","DHCP",
                       "FS-FileServer","FS-DFS-Namespace","FS-DFS-Replication","RSAT-DFS-Mgmt-Con")
# Roles ajoutes si manquants sur un DC existant (on ne touche pas a DNS/DHCP)
$FeaturesAdaptive  = @("GPMC","RSAT-AD-PowerShell",
                       "FS-FileServer","FS-DFS-Namespace","FS-DFS-Replication","RSAT-DFS-Mgmt-Con")

# Transcript immediat
if (-not (Test-Path $SetupRoot)) { New-Item -ItemType Directory -Path $SetupRoot | Out-Null }
Start-Transcript -Path $TranscriptFile -Append -Force
$DomainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
Write-Host "[$(Get-Date -Format HH:mm:ss)] =============================" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] Script demarre" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] DomainRole  : $DomainRole" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] Flag phase1 : $(Test-Path $FlagPhase1)" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] Flag phase2 : $(Test-Path $FlagPhase2)" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] SetupRoot   : $SetupRoot" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] =============================" -ForegroundColor Cyan

# ==============================================================================
# CHARGEMENT DES MODULES
# ==============================================================================

function Import-SetupModules {
    $modules = @("Common","ADStructure","Users","Shares","Data","Dfs","Services","GPO","Drives","Tier0","Logging")

    # Controle de coherence AVANT import : evite de melanger anciens et nouveaux modules
    $problems = @()
    foreach ($mod in $modules) {
        $path = Join-Path $ModulesDir "$mod.psm1"
        if (-not (Test-Path $path)) { $problems += "absent    : $mod.psm1"; continue }
        if (-not (Select-String -Path $path -Pattern "SetupLab-Version: $ModuleVersion" -SimpleMatch -Quiet)) {
            $problems += "obsolete  : $mod.psm1 (version $ModuleVersion attendue)"
        }
    }
    if ($problems.Count -gt 0) {
        $problems | ForEach-Object { Write-Host "  [MODULE] $_" -ForegroundColor Red }
        throw "Modules incoherents dans $ModulesDir - recopier TOUT le dossier Modules\ (et Configs\) de l'archive"
    }

    foreach ($mod in $modules) {
        $path = Join-Path $ModulesDir "$mod.psm1"
        if (Get-Module -Name $mod) { Remove-Module -Name $mod -Force }
        Import-Module $path -Force -DisableNameChecking
    }
}

# ==============================================================================
# COPIE, PARAMETRES, TACHE PLANIFIEE
# ==============================================================================

function CopyScript {
    foreach ($d in @($SetupRoot, $ConfigDir, $ModulesDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    $src = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\')
    $dst = (Resolve-Path $SetupRoot).Path.TrimEnd('\')
    if ($src -ieq $dst) {
        Write-Host "[$(Get-Date -Format HH:mm:ss)] Script lance depuis $SetupRoot - copie ignoree" -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path "$src\Configs") -or -not (Test-Path "$src\Modules")) {
        throw "Dossiers Configs\ et/ou Modules\ introuvables a cote du script ($src)"
    }

    Copy-Item "$src\Setup_Lab_AD.ps1" -Destination $SetupRoot -Force
    Get-ChildItem "$src\Configs\*" | Copy-Item -Destination $ConfigDir  -Recurse -Force
    Get-ChildItem "$src\Modules\*" | Copy-Item -Destination $ModulesDir -Recurse -Force

    $src | Out-File $OriginFile -Encoding UTF8 -Force
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Script, Configs et Modules copies dans $SetupRoot" -ForegroundColor Green
}

function Save-RunParams {
    # La Phase 2 est relancee par une tache SANS parametres : on memorise ceux de la Phase 1
    @{ RootOU = $RootOU; DefaultUserPass = $DefaultUserPass; SkipData = [bool]$SkipData } |
        ConvertTo-Json | Out-File $ParamsFile -Encoding UTF8 -Force
}

function Restore-RunParams {
    if (-not (Test-Path $ParamsFile)) { return }
    $p = Get-Content $ParamsFile -Raw | ConvertFrom-Json
    if ($p.RootOU)          { $script:RootOU          = $p.RootOU }
    if ($p.DefaultUserPass) { $script:DefaultUserPass = $p.DefaultUserPass }
    if ($p.SkipData)        { $script:SkipData        = [switch]$true }
}

function Register-Phase2Task {
    Write-Host "[$(Get-Date -Format HH:mm:ss)] === Creation de la tache planifiee ===" -ForegroundColor Cyan
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 30)
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Compatibility Win8
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Tache '$TaskName' enregistree" -ForegroundColor Green
}

function Remove-Phase2Task {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Tache '$TaskName' supprimee" "Green"
    }
}

# ==============================================================================
# PHASE 1 : Installation AD DS + promotion DC (VM vierge)
# ==============================================================================

function Invoke-Phase1 {
    Write-Host "[$(Get-Date -Format HH:mm:ss)] === PHASE 1 : INSTALLATION AD DS ===" -ForegroundColor Cyan
    CopyScript
    Save-RunParams

    Write-Host "[$(Get-Date -Format HH:mm:ss)] Installation des roles..." -ForegroundColor Yellow
    Install-WindowsFeature -Name $FeaturesNewDomain -IncludeManagementTools

    Register-Phase2Task
    New-Item -Path $FlagPhase1 -ItemType File -Force | Out-Null

    Write-Host "[$(Get-Date -Format HH:mm:ss)] Promotion DC pour $DomainName..." -ForegroundColor Yellow
    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName                    $DomainName `
        -DomainNetbiosName             $DomainNetbios `
        -SafeModeAdministratorPassword (ConvertTo-SecureString $SafeModePass -AsPlainText -Force) `
        -InstallDns -Force
    Write-Host "[$(Get-Date -Format HH:mm:ss)] === REBOOT ===" -ForegroundColor Cyan
}

# ==============================================================================
# MODE ADAPTATIF : roles manquants sur un DC existant
# ==============================================================================

function Install-AdaptiveFeatures {
    Write-Log "--- Roles et fonctionnalites ---" "Cyan"
    $missing = @($FeaturesAdaptive | Where-Object { -not (Get-WindowsFeature -Name $_).Installed })
    if ($missing.Count -eq 0) { Write-Log "  = Tous les roles requis sont deja installes" "DarkGray"; return }
    Write-Log "  Installation : $($missing -join ', ')" "Yellow"
    $res = Install-WindowsFeature -Name $missing -IncludeManagementTools
    if ($res.Success) { Write-Log "  + Roles installes" "Green" }
    if ("$($res.RestartNeeded)" -eq "Yes") {
        Write-Log "  ! Un redemarrage est demande par Windows - a faire apres le script" "Yellow"
    }
}

# ==============================================================================
# PHASE 2 : Population AD (commune aux deux modes)
# ==============================================================================

function Wait-ADReady {
    Write-Log "Attente demarrage services AD..." "Yellow"
    $timeout = 120; $elapsed = 0
    while ($elapsed -lt $timeout) {
        try { Get-ADDomain -ErrorAction Stop | Out-Null; Write-Log "AD operationnel." "Green"; return }
        catch { Start-Sleep 5; $elapsed += 5; Write-Log "  Attente... ($elapsed s)" "DarkGray" }
    }
    throw "AD non disponible apres $timeout secondes."
}

function Initialize-DomainContext {
    # Les variables du domaine viennent TOUJOURS de l'AD reel, jamais des parametres
    $dom = Get-ADDomain
    if ($BoundParams.ContainsKey('DomainName') -and $BoundParams['DomainName'] -ne $dom.DNSRoot) {
        Write-Log "  ! -DomainName '$($BoundParams['DomainName'])' ignore : domaine reel = $($dom.DNSRoot)" "Yellow"
    }
    $script:DomainName    = $dom.DNSRoot
    $script:DomainNetbios = $dom.NetBIOSName
    $script:DomainDN      = $dom.DistinguishedName
    if (-not $script:RootOU) { $script:RootOU = $dom.NetBIOSName }
    $script:SecurePass    = ConvertTo-SecureString $script:DefaultUserPass -AsPlainText -Force

    Write-Log "--- Contexte du domaine ---" "Cyan"
    Write-Log "  Mode     : $script:Mode" "White"
    Write-Log "  FQDN     : $script:DomainName" "White"
    Write-Log "  NetBIOS  : $script:DomainNetbios" "White"
    Write-Log "  DN       : $script:DomainDN" "White"
    Write-Log "  OU racine: OU=$script:RootOU,$script:DomainDN" "White"
}

function Invoke-Phase2 {
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy     -ErrorAction Stop
    Initialize-DomainContext

    $functionalLevels = Get-FunctionalLevel -DomainName $DomainName

    # Structure AD
    New-OUs             -ConfigDir $ConfigDir -DomainDN $DomainDN -RootOU $RootOU
    New-Groups          -ConfigDir $ConfigDir -DomainDN $DomainDN -RootOU $RootOU
    New-UsersT0         -ConfigDir $ConfigDir -DomainDN $DomainDN -DomainName $DomainName -SecurePass $SecurePass -RootOU $RootOU
    New-UsersStandard   -ConfigDir $ConfigDir -DomainDN $DomainDN -DomainName $DomainName -SecurePass $SecurePass -RootOU $RootOU
    New-ServiceAccounts -ConfigDir $ConfigDir -DomainDN $DomainDN -DomainName $DomainName -SecurePass $SecurePass -RootOU $RootOU

    # Protection Tier 0 : PSO + silos d'authentification (apres la creation des comptes)
    New-LabTier0Protection -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios

    # Fichiers : SMB classique + cibles cachees, puis namespace DFS
    New-NTFSShares      -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios
    if ($SkipData) { Write-Log "--- Donnees de test : ignorees (-SkipData) ---" "DarkGray" }
    else           { New-LabShareData -ConfigDir $ConfigDir }
    New-LabDfs          -ConfigDir $ConfigDir -DomainName $DomainName -DomainNetbios $DomainNetbios

    # Services et taches
    New-WindowsServices -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios -DefaultUserPass $DefaultUserPass
    New-ScheduledTasks  -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios -DefaultUserPass $DefaultUserPass

    # GPOs : base du lab + import securite selon niveau fonctionnel
    New-LabGPOs         -GPOConfigFile $GPOConfigFile -DomainDN $DomainDN -DomainName $DomainName -BackupPath $GPOBackupPath -RootOU $RootOU
    Import-SecurityGPOs -GPOConfigFile $GPOConfigFile -BackupPath $GPOBackupPath -DomainName $DomainName -FunctionalLevels $functionalLevels
    Set-GPOsToTiers     -GPOConfigFile $GPOConfigFile -ConfigDir $ConfigDir -DomainName $DomainName -DomainDN $DomainDN -RootOU $RootOU

    # Lecteurs reseau (GPP Drive Maps) - apres les partages et le DFS
    New-LabDriveMaps    -ConfigDir $ConfigDir -DomainName $DomainName -DomainNetbios $DomainNetbios -DomainDN $DomainDN -RootOU $RootOU

    # Journalisation (en dernier : les SACL portent sur les objets crees)
    Enable-LabAuditLogging -ConfigDir $ConfigDir -DomainDN $DomainDN -RootOU $RootOU -DomainNetbios $DomainNetbios -ModulesDir $ModulesDir

    Show-Resume
}

function Show-Resume {
    $shares  = @(Get-SmbShare | Where-Object { -not $_.Special })
    $visible = @($shares | Where-Object { $_.Name -notlike '*$' }).Count
    $hidden  = @($shares | Where-Object { $_.Name -like '*$' }).Count
    $nsPath  = "-"
    if (Test-Path "$ConfigDir\dfs.json") {
        $dfsCfg = Read-Config "dfs.json" -ConfigDir $ConfigDir
        if ($dfsCfg.Enabled) { $nsPath = "\\$DomainName\$($dfsCfg.NamespaceName)" }
    }

    Write-Log "" "White"
    Write-Log "============================================" "Cyan"
    Write-Log "  CONFIGURATION AD DE TEST TERMINEE" "Cyan"
    Write-Log "============================================" "Cyan"
    Write-Log "  Mode             : $script:Mode" "White"
    Write-Log "  Domaine          : $DomainName ($DomainNetbios)" "White"
    Write-Log "  OU racine        : OU=$RootOU" "White"
    Write-Log "  Namespace DFS    : $nsPath" "White"
    Write-Log "  Partages SMB     : $visible visibles | $hidden caches (cibles DFS)" "White"
    Write-Log "" "White"
    Write-Log "  Objets du lab (crees | existants | alertes) :" "Cyan"
    $stats = Get-SetupStats
    foreach ($k in $stats.Keys) {
        $s     = $stats[$k]
        $color = if ($s.Warning -gt 0) { "Yellow" } else { "Green" }
        Write-Log ("    {0,-18}: {1,3} | {2,3} | {3,3}" -f $k, $s.Created, $s.Existing, $s.Warning) $color
    }
    Write-Log "" "White"
    Write-Log "  Points de risque injectes :" "Yellow"
    Write-Log "    - svc_deploy membre de Domain Admins" "Yellow"
    Write-Log "    - adm_dupont utilise dans une tache planifiee" "Yellow"
    Write-Log "    - GRP_IT imbrique dans GRP_Admins_SI" "Yellow"
    Write-Log "    - Compte machine $($env:COMPUTERNAME)$ dans GRP_Admins_SI" "Yellow"
    Write-Log "    - Heritage NTFS casse : IT\Logs, Direction\Strategies" "Yellow"
    Write-Log "    - Heritage NTFS de C:\ conserve : Commun" "Yellow"
    Write-Log "    - Partage Direction : Everyone Full (permissions de partage)" "Yellow"
    Write-Log "    - DFS Comptabilite visible par GRP_Commercial sans droit NTFS" "Yellow"
    Write-Log "    - DFS Direction visible par tous + cible obsolete \\FS-OLD01" "Yellow"
    Write-Log "    - Partages et namespace DFS heberges sur le DC" "Yellow"
    Write-Log "    - Lecteur P: vers le partage Direction en acces direct (Everyone Full)" "Yellow"
    Write-Log "    - Lecteur Z: vers C$ du DC pour GRP_IT" "Yellow"
    Write-Log "    - Comptes desactives avec groupes residuels : x.ancien, d.renard" "Yellow"
    Write-Log "    - Heritage GPO bloque : OU Tier0, OU Serveurs" "Yellow"
    Write-Log "    - GPO_Proxy_Navigation liee a 2 OUs" "Yellow"
    Write-Log "    - PSO_VPN_Faible : 6 car., sans complexite, chiffrement reversible" "Yellow"
    Write-Log "    - PSO_Comptes_Service : mdp jamais expire, pas de verrouillage" "Yellow"
    Write-Log "    - Silo_Tier0 en mode AUDIT ; svc_deploy (Domain Admins) hors silo" "Yellow"
    Write-Log "" "White"
    Write-Log "  Mot de passe comptes de test : $DefaultUserPass" "Magenta"
    Write-Log "  Transcript : $TranscriptFile" "White"
    Write-Log "============================================" "Cyan"
    Write-Log "  Lance maintenant : .\main.ps1" "Green"
    Write-Log "============================================" "Cyan"
}

function Invoke-Cleanup {
    Write-Log "=== NETTOYAGE ===" "Cyan"
    Remove-Phase2Task
    foreach ($f in @($FlagPhase1, $FlagPhase2, $ParamsFile)) {
        if (Test-Path $f) { Remove-Item $f -Force; Write-Log "Supprime : $(Split-Path $f -Leaf)" "Green" }
    }
    if (Test-Path $OriginFile) {
        $origin  = (Get-Content $OriginFile -Raw).Trim()
        $logDest = Join-Path $origin "Logs"
        if (-not (Test-Path $logDest)) { New-Item -ItemType Directory -Path $logDest | Out-Null }
        Stop-Transcript
        Copy-Item $TranscriptFile -Destination $logDest -Force
        Write-Host "Transcript copie dans $logDest" -ForegroundColor Green
    } else {
        Stop-Transcript
    }
    Write-Host "Nettoyage termine." -ForegroundColor Green
}

function Stop-WithError {
    param([string]$Message, [string]$Hint)
    Write-Host "[ERREUR] $Message" -ForegroundColor Red
    if ($Hint) { Write-Host "  $Hint" -ForegroundColor Yellow }
    Stop-Transcript
    exit 1
}

# ==============================================================================
# POINT D'ENTREE
# ==============================================================================

if ($CleanupOnly) {
    if (Test-Path "$ModulesDir\Common.psm1") { Import-Module "$ModulesDir\Common.psm1" -Force -DisableNameChecking }
    else { function Write-Log { param($Message, $Color = "White") Write-Host $Message -ForegroundColor $Color } }
    Invoke-Cleanup
    exit 0
}

# DomainRole : 0 poste autonome | 1 poste membre | 2 serveur autonome
#              3 serveur membre | 4 DC secondaire | 5 DC principal
if ($DomainRole -eq 0 -or $DomainRole -eq 1) {
    Stop-WithError "Poste de travail detecte : ce script necessite Windows Server."
}
if ($DomainRole -eq 3) {
    Stop-WithError "Serveur membre d'un domaine detecte : le script doit tourner sur un controleur de domaine." `
                   "Promouvoir ce serveur en DC du domaine existant, ou lancer le script sur un DC."
}
if ($DomainRole -eq 2) {
    $script:Mode = "Nouveau domaine"
    Invoke-Phase1
    Stop-Transcript
    exit 0
}

# --- Controleur de domaine (4 ou 5) ---
if (Test-Path $FlagPhase2) {
    Write-Host "Phase 2 deja effectuee. Nettoyage de la tache residuelle." -ForegroundColor DarkGray
    if (Test-Path "$ModulesDir\Common.psm1") { Import-Module "$ModulesDir\Common.psm1" -Force -DisableNameChecking }
    Invoke-Cleanup
    Read-Host "`nNettoyage termine - Appuie sur Entree pour fermer"
    exit 0
}

$PostPhase1 = Test-Path $FlagPhase1
if ($PostPhase1) {
    $script:Mode = "Nouveau domaine"
    Restore-RunParams
} else {
    $script:Mode = "Domaine existant (adaptatif)"
    Write-Host "[$(Get-Date -Format HH:mm:ss)] DC existant detecte -> mode adaptatif" -ForegroundColor Cyan
    CopyScript
}

if (-not (Test-Path $ConfigDir)) {
    Stop-WithError "Dossier Configs introuvable : $ConfigDir" "Copy-Item '<chemin_source>\Configs' '$ConfigDir' -Recurse -Force"
}

Import-SetupModules

# Ancien ous.json (OU racine en dur) + OU racine differente = arborescence incoherente
$ousRaw = Get-Content "$ConfigDir\ous.json" -Raw
if ($ousRaw -notmatch '\{ROOT\}' -and -not $BoundParams.ContainsKey('RootOU')) {
    Stop-WithError "ous.json n'utilise pas le jeton {ROOT} (ancien format)." `
                   "Remplacer Configs\ous.json par celui de l'archive, ou relancer avec -RootOU <nom de l'OU racine en dur>."
}
foreach ($cfg in @("dfs.json","audit_logging.json")) {
    if (-not (Test-Path "$ConfigDir\$cfg")) { Write-Log "  ! $cfg absent de Configs\ - fonctionnalite ignoree" "Yellow" }
}

if (-not $PostPhase1) { Install-AdaptiveFeatures }
Wait-ADReady
Invoke-Phase2

if ($PostPhase1) {
    New-Item -Path $FlagPhase2 -ItemType File -Force | Out-Null
    Write-Log "Phase 2 terminee - Reboot dans 10 secondes..." "Green"
    Stop-Transcript
    Start-Sleep -Seconds 10
    Restart-Computer -Force
} else {
    Write-Log "Mode adaptatif termine - aucun redemarrage necessaire." "Green"
    Invoke-Cleanup
}
