# ==============================================================================
# SetupLab-Version: 2.2
# Common.psm1 - Utilitaires partages
# ==============================================================================

# Compteurs crees / existants / alertes (affiches dans le resume final)
$script:SetupStats = [ordered]@{}

# Principaux bien connus (SID fixes, independants de la langue de l'OS)
$script:WellKnownSIDs = @{
    "Everyone"            = "S-1-1-0"
    "Authenticated Users" = "S-1-5-11"
    "SYSTEM"              = "S-1-5-18"
    "Local Service"       = "S-1-5-19"
    "Network Service"     = "S-1-5-20"
    "CREATOR OWNER"       = "S-1-3-0"
}

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $Message" -ForegroundColor $Color
}

function Read-Config {
    param([string]$FileName, [string]$ConfigDir)
    $path = Join-Path $ConfigDir $FileName
    if (-not (Test-Path $path)) { throw "Config introuvable : $path" }
    $raw = (Get-Content $path -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
    $raw | ConvertFrom-Json | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Count -gt 0 }
}

# ------------------------------------------------------------------------------
# Statistiques
# ------------------------------------------------------------------------------

function Add-SetupStat {
    param(
        [string]$Category,
        [ValidateSet("Created","Existing","Warning")][string]$Result
    )
    if (-not $script:SetupStats.Contains($Category)) {
        $script:SetupStats[$Category] = [ordered]@{ Created = 0; Existing = 0; Warning = 0 }
    }
    $script:SetupStats[$Category][$Result]++
}

function Get-SetupStats { return $script:SetupStats }

# ------------------------------------------------------------------------------
# Jetons et DN
# ------------------------------------------------------------------------------

function Resolve-LabToken {
    # {ROOT}   -> nom de l'OU racine du lab
    # {DOMAIN} -> DN du domaine (DC=...,DC=...)
    param([string]$Value, [string]$RootOU, [string]$DomainDN)
    if (-not $Value) { return $Value }
    if ($RootOU)   { $Value = $Value.Replace('{ROOT}',   $RootOU) }
    if ($DomainDN) { $Value = $Value.Replace('{DOMAIN}', $DomainDN) }
    return $Value
}

function Resolve-OUDN {
    param([string]$ParentChain, [string]$DomainDN, [string]$RootOU)
    if (-not $ParentChain -or $ParentChain -eq "") { return $DomainDN }
    $chain = Resolve-LabToken -Value $ParentChain -RootOU $RootOU
    $parts = $chain -split "," | ForEach-Object { "OU=$($_.Trim())" }
    return ($parts -join ",") + ",$DomainDN"
}

function Test-ExpectedLocation {
    # Signale un objet qui existe deja mais ailleurs que prevu (cas du domaine existant)
    param([string]$DistinguishedName, [string]$ExpectedParentDN, [string]$Label)
    $parent = ($DistinguishedName -split '(?<!\\),', 2)[1]
    if ($parent -ne $ExpectedParentDN) {
        Write-Log "  ~ $Label existe deja hors emplacement attendu : $DistinguishedName" "Yellow"
        return $false
    }
    return $true
}

# ------------------------------------------------------------------------------
# Resolution des groupes / comptes (independante de la langue)
# ------------------------------------------------------------------------------

function Get-BuiltinGroup {
    param([string]$GroupName)

    $domainRIDs = @{
        "Domain Admins"               = "512"
        "Domain Users"                = "513"
        "Domain Computers"            = "515"
        "Domain Controllers"          = "516"
        "Schema Admins"               = "518"
        "Enterprise Admins"           = "519"
        "Group Policy Creator Owners" = "520"
    }

    $builtinSIDs = @{
        "Administrators"       = "S-1-5-32-544"
        "Users"                = "S-1-5-32-545"
        "Guests"               = "S-1-5-32-546"
        "Backup Operators"     = "S-1-5-32-551"
        "Account Operators"    = "S-1-5-32-548"
        "Server Operators"     = "S-1-5-32-549"
        "Print Operators"      = "S-1-5-32-550"
        "Remote Desktop Users" = "S-1-5-32-555"
    }

    if ($domainRIDs.ContainsKey($GroupName)) {
        $domainSID = (Get-ADDomain).DomainSID.Value
        $rid       = $domainRIDs[$GroupName]
        $group     = Get-ADGroup -Filter "SID -eq '$domainSID-$rid'" -ErrorAction SilentlyContinue
        if ($group) { return $group.SamAccountName }
    }

    if ($builtinSIDs.ContainsKey($GroupName)) {
        $sid   = $builtinSIDs[$GroupName]
        $group = Get-ADGroup -Filter "SID -eq '$sid'" -ErrorAction SilentlyContinue
        if ($group) { return $group.SamAccountName }
    }

    return $GroupName
}

function Get-GroupSID {
    # Accepte : principal bien connu (Everyone, Authenticated Users...), groupe
    # builtin/domaine (nom anglais), groupe ou compte du domaine
    param([string]$GroupName, [string]$DomainNetbios)

    if ($script:WellKnownSIDs.ContainsKey($GroupName)) {
        return New-Object System.Security.Principal.SecurityIdentifier($script:WellKnownSIDs[$GroupName])
    }

    $resolvedName = Get-BuiltinGroup -GroupName $GroupName
    $group = Get-ADGroup -Filter "SamAccountName -eq '$resolvedName'" -ErrorAction SilentlyContinue
    if ($group) { return [System.Security.Principal.SecurityIdentifier]$group.SID }

    try {
        $ntAccount = New-Object System.Security.Principal.NTAccount("$DomainNetbios\$resolvedName")
        return $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
    } catch {
        Write-Log "  ! Impossible de resoudre le SID pour : $GroupName" "Yellow"
        return $null
    }
}

function Resolve-AccountName {
    # Retourne le nom NT localise (ex : "NETOPTIMA\Admins du domaine", "Tout le monde")
    param([string]$Name, [string]$DomainNetbios)
    $sid = Get-GroupSID -GroupName $Name -DomainNetbios $DomainNetbios
    if (-not $sid) { return $null }
    try   { return $sid.Translate([System.Security.Principal.NTAccount]).Value }
    catch { Write-Log "  ! Traduction SID -> nom impossible : $Name" "Yellow"; return $null }
}

Export-ModuleMember -Function Write-Log, Read-Config, Add-SetupStat, Get-SetupStats, `
    Resolve-LabToken, Resolve-OUDN, Test-ExpectedLocation, `
    Get-BuiltinGroup, Get-GroupSID, Resolve-AccountName
