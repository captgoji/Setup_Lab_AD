# ==============================================================================
# SetupLab-Version: 2.2
# Users.psm1 - Creation des comptes utilisateurs
# ==============================================================================

function Register-ExistingUser {
    # Log + stats pour un compte deja present (verifie aussi son emplacement)
    param($User, [string]$ExpectedOU, [string]$Category)
    if (Test-ExpectedLocation -DistinguishedName $User.DistinguishedName -ExpectedParentDN $ExpectedOU -Label $User.SamAccountName) {
        Write-Log "  = $($User.SamAccountName) (existe)" "DarkGray"
        Add-SetupStat $Category "Existing"
    } else {
        Add-SetupStat $Category "Warning"
    }
}

function New-UsersT0 {
    param([string]$ConfigDir, [string]$DomainDN, [string]$DomainName, [securestring]$SecurePass, [string]$RootOU)
    Write-Log "--- Comptes Tier 0 ---" "Cyan"
    $T0OU = "OU=Tier0,OU=$RootOU,$DomainDN"
    foreach ($u in (Read-Config "users_t0.json" -ConfigDir $ConfigDir)) {
        if (-not $u.SamAccountName) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        $sam      = $u.SamAccountName
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-ADUser `
                -SamAccountName       $sam `
                -UserPrincipalName    "$sam@$DomainName" `
                -GivenName            $u.GivenName `
                -Surname              $u.Surname `
                -Name                 "$($u.GivenName) $($u.Surname)" `
                -Description          $u.Description `
                -Path                 $T0OU `
                -AccountPassword      $SecurePass `
                -Enabled              $u.Enabled `
                -PasswordNeverExpires $u.PasswordNeverExpires
            Write-Log "  + $sam" "Green"
            Add-SetupStat "Comptes T0" "Created"
        } else { Register-ExistingUser -User $existing -ExpectedOU $T0OU -Category "Comptes T0" }
        foreach ($grp in $u.PrivilegedGroups) {
            $resolvedGrp = Get-BuiltinGroup -GroupName $grp
            Add-ADGroupMember -Identity $resolvedGrp -Members $sam -ErrorAction SilentlyContinue
        }
    }
}

function New-UsersStandard {
    param([string]$ConfigDir, [string]$DomainDN, [string]$DomainName, [securestring]$SecurePass, [string]$RootOU)
    Write-Log "--- Utilisateurs standard ---" "Cyan"
    foreach ($u in (Read-Config "users_standard.json" -ConfigDir $ConfigDir)) {
        if (-not $u.SamAccountName) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        $ouPath   = "OU=$($u.OU),OU=Utilisateurs,OU=$RootOU,$DomainDN"
        $sam      = $u.SamAccountName
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-ADUser `
                -SamAccountName    $sam `
                -UserPrincipalName "$sam@$DomainName" `
                -GivenName         $u.GivenName `
                -Surname           $u.Surname `
                -Name              "$($u.GivenName) $($u.Surname)" `
                -Description       $u.Description `
                -Path              $ouPath `
                -AccountPassword   $SecurePass `
                -Enabled           $u.Enabled
            Write-Log "  + $sam" "Green"
            Add-SetupStat "Utilisateurs" "Created"
        } else { Register-ExistingUser -User $existing -ExpectedOU $ouPath -Category "Utilisateurs" }
        foreach ($grp in $u.Groups) {
            Add-ADGroupMember -Identity $grp -Members $sam -ErrorAction SilentlyContinue
        }
        if ($u.ForcePasswordExpired) {
            Set-ADUser -Identity $sam -Replace @{ pwdLastSet = 0 } -ErrorAction SilentlyContinue
            Write-Log "    [MDP EXPIRE] $sam" "DarkYellow"
        }
        if ($u.NeverConnected) { Write-Log "    [JAMAIS CONNECTE] $sam" "DarkYellow" }
    }

    Write-Log "--- Compte machine dans groupe securite ---" "Cyan"
    try {
        Add-ADGroupMember -Identity "GRP_Admins_SI" -Members "$($env:COMPUTERNAME)$" -ErrorAction Stop
        Write-Log "  + $($env:COMPUTERNAME)$ -> GRP_Admins_SI [risque : compte machine]" "DarkYellow"
    } catch { Write-Log "  ! $($_.Exception.Message)" "Yellow" }

    Write-Log "--- Domain Users dans GRP_IT ---" "Cyan"
    try {
        $domUsers = Get-BuiltinGroup -GroupName "Domain Users"
        Add-ADGroupMember -Identity "GRP_IT" -Members $domUsers -ErrorAction SilentlyContinue
        Write-Log "  + $domUsers -> GRP_IT" "DarkYellow"
    } catch { Write-Log "  ! $($_.Exception.Message)" "Yellow" }
}

function New-ServiceAccounts {
    param([string]$ConfigDir, [string]$DomainDN, [string]$DomainName, [securestring]$SecurePass, [string]$RootOU)
    Write-Log "--- Comptes de service ---" "Cyan"
    $SvcOU = "OU=Services,OU=$RootOU,$DomainDN"
    foreach ($u in (Read-Config "users_service.json" -ConfigDir $ConfigDir)) {
        if (-not $u.SamAccountName) { Write-Log "  ! Entree invalide ignoree" "Yellow"; continue }
        $sam      = $u.SamAccountName
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-ADUser `
                -SamAccountName       $sam `
                -UserPrincipalName    "$sam@$DomainName" `
                -GivenName            "Service" `
                -Surname              $sam `
                -Name                 $sam `
                -Description          $u.Description `
                -Path                 $SvcOU `
                -AccountPassword      $SecurePass `
                -Enabled              $true `
                -PasswordNeverExpires $true `
                -CannotChangePassword $true
            Write-Log "  + $sam" "Green"
            Add-SetupStat "Comptes service" "Created"
        } else { Register-ExistingUser -User $existing -ExpectedOU $SvcOU -Category "Comptes service" }
    }
}

Export-ModuleMember -Function New-UsersT0, New-UsersStandard, New-ServiceAccounts
