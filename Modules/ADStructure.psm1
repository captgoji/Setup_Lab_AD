# ==============================================================================
# SetupLab-Version: 2.2
# ADStructure.psm1 - Creation des OUs et groupes
# ==============================================================================

function New-OUs {
    param([string]$ConfigDir, [string]$DomainDN, [string]$RootOU)
    Write-Log "--- OUs ---" "Cyan"
    foreach ($ou in (Read-Config "ous.json" -ConfigDir $ConfigDir)) {
        if (-not $ou.Name) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        $name     = Resolve-LabToken -Value $ou.Name -RootOU $RootOU
        $parentDN = Resolve-OUDN -ParentChain $ou.Parent -DomainDN $DomainDN -RootOU $RootOU
        $fullDN   = "OU=$name,$parentDN"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$fullDN'" -ErrorAction SilentlyContinue)) {
            try {
                New-ADOrganizationalUnit -Name $name -Path $parentDN -Description $ou.Description -ErrorAction Stop
                Write-Log "  + $name" "Green"
                Add-SetupStat "OUs" "Created"
            } catch {
                Write-Log "  ! $name : $($_.Exception.Message)" "Yellow"
                Add-SetupStat "OUs" "Warning"
            }
        } else {
            Write-Log "  = $name (existe)" "DarkGray"
            Add-SetupStat "OUs" "Existing"
        }
    }
}

function New-Groups {
    param([string]$ConfigDir, [string]$DomainDN, [string]$RootOU)
    Write-Log "--- Groupes ---" "Cyan"
    $GroupsOU = "OU=Groupes,OU=$RootOU,$DomainDN"
    foreach ($grp in (Read-Config "groups.json" -ConfigDir $ConfigDir)) {
        if (-not $grp.Name) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        $grpName  = $grp.Name
        $existing = Get-ADGroup -Filter "SamAccountName -eq '$grpName'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-ADGroup -Name $grpName -Path $GroupsOU `
                -GroupScope $grp.Scope -GroupCategory $grp.Category -Description $grp.Description
            Write-Log "  + $grpName" "Green"
            Add-SetupStat "Groupes" "Created"
        } else {
            if (Test-ExpectedLocation -DistinguishedName $existing.DistinguishedName -ExpectedParentDN $GroupsOU -Label $grpName) {
                Write-Log "  = $grpName (existe)" "DarkGray"
                Add-SetupStat "Groupes" "Existing"
            } else { Add-SetupStat "Groupes" "Warning" }
        }
    }

    Write-Log "--- Imbrication de groupes ---" "Cyan"
    Add-ADGroupMember -Identity "GRP_Admins_SI" -Members "GRP_IT" -ErrorAction SilentlyContinue
    Write-Log "  + GRP_IT -> GRP_Admins_SI [escalade privileges indirecte]" "DarkYellow"
    $domAdmins = Get-BuiltinGroup -GroupName "Domain Admins"
    Add-ADGroupMember -Identity "GRP_Admins_SI" -Members $domAdmins -ErrorAction SilentlyContinue
    Write-Log "  + $domAdmins -> GRP_Admins_SI" "DarkYellow"
}

Export-ModuleMember -Function New-OUs, New-Groups
