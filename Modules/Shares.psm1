# ==============================================================================
# SetupLab-Version: 2.2
# Shares.psm1 - Dossiers NTFS + partages SMB (classiques et cibles DFS cachees)
# ==============================================================================

function Get-DefaultSharePermissions {
    # Permissions de partage "bonne pratique" : le NTFS gouverne l'acces
    return @(
        [pscustomobject]@{ Account = "Domain Admins";       Access = "Full"   },
        [pscustomobject]@{ Account = "Authenticated Users"; Access = "Change" }
    )
}

function New-LabFileRule {
    param($Sid, [string]$Rights)
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Sid, $Rights, "ContainerInherit,ObjectInherit", "None", "Allow")
}

function Set-ShareFolderAcl {
    # ACL NTFS du dossier racine + sous-dossier a heritage casse
    param($Share, [string]$DomainNetbios)

    $acl = Get-Acl -LiteralPath $Share.Path

    # Par defaut on coupe l'heritage de C:\ (sinon BUILTIN\Users peut creer des dossiers)
    $disableInheritance = $true
    if ($null -ne $Share.DisableRootInheritance) { $disableInheritance = [bool]$Share.DisableRootInheritance }
    if ($disableInheritance) {
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($baseSid in @("S-1-5-18", "S-1-5-32-544")) {   # SYSTEM, Administrators
            $acl.SetAccessRule((New-LabFileRule -Sid (New-Object System.Security.Principal.SecurityIdentifier($baseSid)) -Rights "FullControl"))
        }
        Write-Log "    NTFS : heritage depuis le parent desactive" "DarkGray"
    } else {
        Write-Log "    NTFS : heritage du parent conserve [RISQUE : droits herites de C:\]" "DarkYellow"
    }

    foreach ($entry in $Share.ACLs) {
        $sid = Get-GroupSID -GroupName $entry.Group -DomainNetbios $DomainNetbios
        if (-not $sid) { continue }
        $acl.SetAccessRule((New-LabFileRule -Sid $sid -Rights $entry.Rights))
        Write-Log "    NTFS : $($entry.Group) -> $($entry.Rights)" "DarkGray"
    }
    Set-Acl -LiteralPath $Share.Path -AclObject $acl

    if ($Share.BrokenInheritance -and $Share.BrokenInheritance.SubFolder) {
        $subPath = Join-Path $Share.Path $Share.BrokenInheritance.SubFolder
        if (Test-Path $subPath) {
            $subAcl = Get-Acl -LiteralPath $subPath
            $subAcl.SetAccessRuleProtection($true, $false)
            foreach ($entry in $Share.BrokenInheritance.ACLs) {
                $sid = Get-GroupSID -GroupName $entry.Group -DomainNetbios $DomainNetbios
                if (-not $sid) { continue }
                $subAcl.AddAccessRule((New-LabFileRule -Sid $sid -Rights $entry.Rights))
                Write-Log "      [Heritage casse] $($entry.Group) -> $($entry.Rights)" "DarkYellow"
            }
            Set-Acl -LiteralPath $subPath -AclObject $subAcl
            Write-Log "    Heritage casse sur : $subPath" "DarkYellow"
        }
    }
}

function New-LabSmbShare {
    param(
        [string]$Name,
        [string]$Path,
        [object[]]$Permissions,
        [bool]$ABE,
        [string]$Description,
        [string]$DomainNetbios,
        [string]$Label
    )

    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Path -ne $Path) {
            Write-Log "    ~ Partage $Name existe deja vers $($existing.Path) (attendu : $Path) - ignore" "Yellow"
            Add-SetupStat "Partages SMB" "Warning"
        } else {
            Write-Log "    = \\$env:COMPUTERNAME\$Name (existe, permissions non modifiees)" "DarkGray"
            Add-SetupStat "Partages SMB" "Existing"
        }
        return
    }

    if (-not $Permissions -or @($Permissions).Count -eq 0) { $Permissions = Get-DefaultSharePermissions }

    $full = @(); $change = @(); $read = @(); $summary = @()
    foreach ($p in $Permissions) {
        $acct = Resolve-AccountName -Name $p.Account -DomainNetbios $DomainNetbios
        if (-not $acct) { continue }
        if     ($p.Access -eq "Full")   { $full   += $acct }
        elseif ($p.Access -eq "Change") { $change += $acct }
        elseif ($p.Access -eq "Read")   { $read   += $acct }
        else { Write-Log "    ! Acces inconnu '$($p.Access)' pour $($p.Account) (Full|Change|Read)" "Yellow"; continue }
        $summary += "$($p.Account):$($p.Access)"
    }

    $params = @{
        Name                  = $Name
        Path                  = $Path
        FolderEnumerationMode = $(if ($ABE) { "AccessBased" } else { "Unrestricted" })
        ErrorAction           = "Stop"
    }
    if ($Description)  { $params.Description  = $Description }
    if ($full.Count)   { $params.FullAccess   = $full }
    if ($change.Count) { $params.ChangeAccess = $change }
    if ($read.Count)   { $params.ReadAccess   = $read }

    try {
        New-SmbShare @params | Out-Null
        $abeTxt = if ($ABE) { "ABE" } else { "sans ABE" }
        Write-Log "    + \\$env:COMPUTERNAME\$Name [$Label | $abeTxt] ($($summary -join ', '))" "Green"
        Add-SetupStat "Partages SMB" "Created"
    } catch {
        Write-Log "    ! Partage $Name : $($_.Exception.Message)" "Yellow"
        Add-SetupStat "Partages SMB" "Warning"
    }
}

function New-NTFSShares {
    param([string]$ConfigDir, [string]$DomainNetbios)
    Write-Log "--- Partages SMB / NTFS ---" "Cyan"
    foreach ($share in (Read-Config "shares.json" -ConfigDir $ConfigDir)) {
        if (-not $share.Path -or -not $share.ShareName) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        Write-Log "  [$($share.ShareName)] $($share.Path)" "White"

        $null = New-Item -ItemType Directory -Force -Path $share.Path
        foreach ($sub in $share.SubFolders) {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $share.Path $sub)
        }
        Set-ShareFolderAcl -Share $share -DomainNetbios $DomainNetbios

        # 1) Partage classique (acces direct \\SERVEUR\Partage)
        New-LabSmbShare -Name $share.ShareName -Path $share.Path `
            -Permissions $share.SharePermissions -ABE ([bool]$share.ABE) `
            -Description $share.Description -DomainNetbios $DomainNetbios -Label "classique"

        # 2) Partage cache servant de cible DFS
        if ($share.Dfs) {
            $target = if ($share.Dfs.TargetShare) { $share.Dfs.TargetShare } else { "$($share.ShareName)`$" }
            $abe    = $true
            if ($null -ne $share.Dfs.TargetABE) { $abe = [bool]$share.Dfs.TargetABE }
            New-LabSmbShare -Name $target -Path $share.Path `
                -Permissions $share.Dfs.TargetSharePermissions -ABE $abe `
                -Description "Cible DFS - $($share.ShareName)" -DomainNetbios $DomainNetbios -Label "cible DFS"
        }
    }
}

Export-ModuleMember -Function New-NTFSShares
