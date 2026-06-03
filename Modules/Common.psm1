# ==============================================================================
# Common.psm1 - Utilitaires partages
# ==============================================================================

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

function Resolve-OUDN {
    param([string]$ParentChain, [string]$DomainDN)
    if (-not $ParentChain -or $ParentChain -eq "") { return $DomainDN }
    $parts = $ParentChain -split "," | ForEach-Object { "OU=$_" }
    return ($parts -join ",") + ",$DomainDN"
}

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
    param([string]$GroupName, [string]$DomainNetbios)
    $resolvedName = Get-BuiltinGroup -GroupName $GroupName
    try {
        $group = Get-ADGroup -Filter "SamAccountName -eq '$resolvedName'" -ErrorAction Stop
        return [System.Security.Principal.SecurityIdentifier]$group.SID
    } catch {
        try {
            $ntAccount = New-Object System.Security.Principal.NTAccount("$DomainNetbios\$resolvedName")
            return $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
        } catch {
            Write-Log "  ! Impossible de resoudre le SID pour : $GroupName" "Yellow"
            return $null
        }
    }
}

Export-ModuleMember -Function Write-Log, Read-Config, Resolve-OUDN, Get-BuiltinGroup, Get-GroupSID
