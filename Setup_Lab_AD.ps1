# ==============================================================================
# Setup_Lab_AD.ps1 - Orchestrateur
#
# PREMIERE EXECUTION : .\Setup_Lab_AD.ps1
#   -> Copie le script + Configs\ + Modules\ dans USERPROFILE\Setup_Lab
#   -> Installe AD DS, enregistre la tache de relance, redemarre
#   -> Au redemarrage la tache relance le script automatiquement (Phase 2)
#   -> La tache et le flag se nettoient seuls a la fin
#
# CONFIGURATION : editer uniquement les fichiers dans Configs\
# MODULES      : Modules\Common.psm1 / ADStructure.psm1 / Users.psm1
#                        Shares.psm1 / Services.psm1 / GPO.psm1
# ==============================================================================

#Requires -RunAsAdministrator

param(
    [string]$DomainName      = "netoptima.lab",
    [string]$DomainNetbios   = "NETOPTIMA",
    [string]$SafeModePass    = "P@ssw0rd123!",
    [string]$DefaultUserPass = "Azerty123!"
)

$ErrorActionPreference = "Stop"
$SetupRoot      = "$env:USERPROFILE\Setup_Lab"
$ScriptPath     = "$SetupRoot\Setup_Lab_AD.ps1"
$ModulesDir     = "$SetupRoot\Modules"
$ConfigDir      = "$SetupRoot\Configs"
$GPOConfigFile  = "$ConfigDir\GPO_config.json"
$GPOBackupPath  = "$ConfigDir\GPO"
$TranscriptFile = "$SetupRoot\Setup_Lab_AD_transcript.log"
$FlagPhase2     = "$SetupRoot\phase2_done"
$OriginFile     = "$SetupRoot\origin_path.txt"
$TaskName       = "SetupLabAD_Phase2"
$SecurePass     = ConvertTo-SecureString $DefaultUserPass -AsPlainText -Force
$script:DomainDN = $null

# Transcript immediat
Start-Transcript -Path $TranscriptFile -Append -Force
Write-Host "[$(Get-Date -Format HH:mm:ss)] =============================" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] Script demarre" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] DomainRole  : $((Get-CimInstance Win32_ComputerSystem).DomainRole)" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] Flag phase2 : $(Test-Path $FlagPhase2)" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] SetupRoot   : $SetupRoot" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] ConfigDir   : $ConfigDir" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] Config OK   : $(Test-Path $ConfigDir)" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] GPO Backup  : $(Test-Path $GPOBackupPath)" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format HH:mm:ss)] =============================" -ForegroundColor Cyan

# ==============================================================================
# CHARGEMENT DES MODULES
# ==============================================================================

function Import-SetupModules {
    $modules = @("Common","ADStructure","Users","Shares","Services","GPO")
    foreach ($mod in $modules) {
        $path = Join-Path $ModulesDir "$mod.psm1"
        if (-not (Test-Path $path)) { throw "Module introuvable : $path" }
        if (Get-Module -Name $mod) { Remove-Module -Name $mod -Force }
        Import-Module $path -Force -DisableNameChecking
    }
}

# ==============================================================================
# GESTION DE LA TACHE PLANIFIEE
# ==============================================================================

function CopyScript {
    if (-not (Test-Path $SetupRoot))  { New-Item -ItemType Directory -Path $SetupRoot  | Out-Null }
    if (-not (Test-Path $ConfigDir))  { New-Item -ItemType Directory -Path $ConfigDir  | Out-Null }
    if (-not (Test-Path $ModulesDir)) { New-Item -ItemType Directory -Path $ModulesDir | Out-Null }

    Get-ChildItem "$PSScriptRoot\Setup_Lab_AD.ps1" | Copy-Item -Destination $SetupRoot -Force
    Get-ChildItem "$PSScriptRoot\Configs\*"         | Copy-Item -Destination $ConfigDir  -Recurse -Force
    Get-ChildItem "$PSScriptRoot\Modules\*"         | Copy-Item -Destination $ModulesDir -Recurse -Force

    $PSScriptRoot | Out-File $OriginFile -Encoding UTF8 -Force
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Script, Configs et Modules copies dans $SetupRoot" -ForegroundColor Green
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Chemin d'origine sauvegarde : $PSScriptRoot" -ForegroundColor Green
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
# PHASE 1 : Installation AD DS + promotion DC
# ==============================================================================

function Invoke-Phase1 {
    Write-Host "[$(Get-Date -Format HH:mm:ss)] === PHASE 1 : INSTALLATION AD DS ===" -ForegroundColor Cyan
    CopyScript

    Write-Host "[$(Get-Date -Format HH:mm:ss)] Installation des roles..." -ForegroundColor Yellow
    Install-WindowsFeature -Name AD-Domain-Services, GPMC, RSAT-AD-PowerShell, DNS, DHCP -IncludeManagementTools

    Register-Phase2Task

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
# PHASE 2 : Population AD
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

function Show-Resume {
    $gpoCount  = (Get-GPO -All).Count
    $svcCount  = (Get-Service | Where-Object { $_.Name -like 'AuditLab_*' }).Count
    $shareCount = (Get-SmbShare | Where-Object { $_.Name -notlike '*$' }).Count

    Write-Log "" "White"
    Write-Log "============================================" "Cyan"
    Write-Log "  CONFIGURATION AD DE TEST TERMINEE" "Cyan"
    Write-Log "============================================" "Cyan"
    Write-Log "  Domaine          : $DomainName" "White"
    Write-Log "  OUs              : $((Get-ADOrganizationalUnit -Filter *).Count)" "Green"
    Write-Log "  Users            : $((Get-ADUser -Filter *).Count)" "Green"
    Write-Log "  Groupes          : $((Get-ADGroup -Filter *).Count)" "Green"
    Write-Log "  GPOs             : $gpoCount" "Green"
    Write-Log "  Partages         : $shareCount" "Green"
    Write-Log "  Services         : $svcCount" "Green"
    Write-Log "" "White"
    Write-Log "  Points de risque injectes :" "Yellow"
    Write-Log "    - svc_deploy membre de Domain Admins" "Yellow"
    Write-Log "    - adm_dupont utilise dans une tache planifiee" "Yellow"
    Write-Log "    - GRP_IT imbrique dans GRP_Admins_SI" "Yellow"
    Write-Log "    - Compte machine $($env:COMPUTERNAME)$ dans GRP_Admins_SI" "Yellow"
    Write-Log "    - Heritage NTFS casse : IT\Logs, Direction\Strategies" "Yellow"
    Write-Log "    - Comptes desactives avec groupes residuels : x.ancien, d.renard" "Yellow"
    Write-Log "    - Heritage GPO bloque : OU Tier0, OU Serveurs" "Yellow"
    Write-Log "    - GPO_Proxy_Navigation liee a 2 OUs" "Yellow"
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
    if (Test-Path $FlagPhase2) {
        Remove-Item $FlagPhase2 -Force
        Write-Log "Flag phase2_done supprime" "Green"
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

# ==============================================================================
# POINT D'ENTREE
# ==============================================================================

$IsPromo = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4

if (-not $IsPromo) {
    Invoke-Phase1
    Stop-Transcript
    exit 0
}

$CheckP2 = Test-Path $FlagPhase2
if ($CheckP2) {
    Write-Host "Phase 2 deja effectuee. Nettoyage de la tache residuelle." "DarkGray"
    # Charger Write-Log avant le nettoyage
    if (Test-Path "$ModulesDir\Common.psm1") { Import-Module "$ModulesDir\Common.psm1" -Force -DisableNameChecking }
    Invoke-Cleanup
    Read-Host "`nNettoyage termine - Appuie sur Entree pour fermer"
    exit 0
} else {
    if (-not (Test-Path $ConfigDir)) {
        Write-Host "[ERREUR] Dossier Configs introuvable : $ConfigDir" -ForegroundColor Red
        Write-Host "  Copy-Item '<chemin_source>\Configs' '$ConfigDir' -Recurse -Force" -ForegroundColor Yellow
        Stop-Transcript
        Read-Host "`nAppuie sur Entree pour fermer"
        exit 1
    }

    # Charger les modules
    Import-SetupModules

    Wait-ADReady
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy     -ErrorAction Stop
    $script:DomainDN = (Get-ADDomain).DistinguishedName

    # Detection du niveau fonctionnel (inspire de sec_ad)
    $functionalLevels = Get-FunctionalLevel -DomainName $DomainName

    # Population AD
    New-OUs            -ConfigDir $ConfigDir -DomainDN $script:DomainDN
    New-Groups         -ConfigDir $ConfigDir -DomainDN $script:DomainDN
    New-UsersT0        -ConfigDir $ConfigDir -DomainDN $script:DomainDN -DomainName $DomainName -SecurePass $SecurePass
    New-UsersStandard  -ConfigDir $ConfigDir -DomainDN $script:DomainDN -DomainName $DomainName -SecurePass $SecurePass
    New-ServiceAccounts -ConfigDir $ConfigDir -DomainDN $script:DomainDN -DomainName $DomainName -SecurePass $SecurePass
    New-NTFSShares     -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios
    New-WindowsServices -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios -DefaultUserPass $DefaultUserPass
    New-ScheduledTasks  -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios -DefaultUserPass $DefaultUserPass

    # GPOs : base du lab + import securite selon niveau fonctionnel
    New-LabGPOs         -DomainDN $script:DomainDN -DomainName $DomainName -BackupPath $GPOBackupPath
    Import-SecurityGPOs -GPOConfigFile $GPOConfigFile -BackupPath $GPOBackupPath -DomainName $DomainName -FunctionalLevels $functionalLevels
    Set-GPOsToTiers     -GPOConfigFile $GPOConfigFile -ConfigDir $ConfigDir -DomainName $DomainName -DomainDN $script:DomainDN

    Show-Resume

    New-Item -Path $FlagPhase2 -ItemType File -Force | Out-Null
    Write-Log "Phase 2 terminee - Reboot dans 10 secondes..." "Green"
    Stop-Transcript
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}