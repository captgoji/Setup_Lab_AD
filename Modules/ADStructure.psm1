# ==============================================================================
# ADStructure.psm1 - Creation des OUs et groupes
# ==============================================================================

function New-OUs {
    param([string]$ConfigDir, [string]$DomainDN)
    Write-Log "--- OUs ---" "Cyan"
    foreach ($ou in (Read-Config "ous.json" -ConfigDir $ConfigDir)) {
        $parentDN = Resolve-OUDN -ParentChain $ou.Parent -DomainDN $DomainDN
        $fullDN   = "OU=$($ou.Name),$parentDN"
        if (-not $ou.Name) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$fullDN'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou.Name -Path $parentDN -Description $ou.Description
            Write-Log "  + $($ou.Name)" "Green"
        } else { Write-Log "  = $($ou.Name) (existe)" "DarkGray" }
    }
}

function New-Groups {
    param([string]$ConfigDir, [string]$DomainDN)
    Write-Log "--- Groupes ---" "Cyan"
    $GroupsOU = "OU=Groupes,OU=NETOPTIMA,$DomainDN"
    foreach ($grp in (Read-Config "groups.json" -ConfigDir $ConfigDir)) {
        if (-not $grp.Name) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        $grpName = $grp.Name
        if (-not (Get-ADGroup -Filter "SamAccountName -eq '$grpName'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grpName -Path $GroupsOU `
                -GroupScope $grp.Scope -GroupCategory $grp.Category -Description $grp.Description
            Write-Log "  + $grpName" "Green"
        } else { Write-Log "  = $grpName (existe)" "DarkGray" }
    }

    Write-Log "--- Imbrication de groupes ---" "Cyan"
    Add-ADGroupMember -Identity "GRP_Admins_SI" -Members "GRP_IT" -ErrorAction SilentlyContinue
    Write-Log "  + GRP_IT -> GRP_Admins_SI [escalade privileges indirecte]" "DarkYellow"
    $domAdmins = Get-BuiltinGroup -GroupName "Domain Admins"
    Add-ADGroupMember -Identity "GRP_Admins_SI" -Members $domAdmins -ErrorAction SilentlyContinue
    Write-Log "  + $domAdmins -> GRP_Admins_SI" "DarkYellow"
}

Export-ModuleMember -Function New-OUs, New-Groups
