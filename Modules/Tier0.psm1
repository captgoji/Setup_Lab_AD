# ==============================================================================
# SetupLab-Version: 2.2
# Tier0.psm1 - Strategies de mot de passe affinees (PSO) et silos d'authentification
# Pilote par Configs\tier0.json (chaque section optionnelle)
#
# PSO  : Password Settings Object - politique de mot de passe par groupe/utilisateur,
#        sans dependre de la GPO liee a la racine du domaine.
# Silo : Authentication Policy + Authentication Policy Silo - restreint ou peuvent
#        s'authentifier les comptes T0 (protection contre le vol d'identifiants).
#        Necessite un niveau fonctionnel de foret >= 2012 R2 et Kerberos armoring.
# ==============================================================================

function New-LabPSOs {
    param([string]$ConfigDir, [string]$DomainNetbios)
    $cfg = Read-Config "tier0.json" -ConfigDir $ConfigDir
    if (-not $cfg.PSOs) { return }
    Write-Log "--- Strategies de mot de passe affinees (PSO) ---" "Cyan"

    foreach ($pso in $cfg.PSOs) {
        if ($pso.Apply -eq $false) { continue }
        if (-not $pso.Name) { Write-Log "  ! PSO sans nom ignoree" "Yellow"; continue }

        $params = @{
            Name                        = $pso.Name
            Precedence                  = $pso.Precedence
            ComplexityEnabled           = [bool]$pso.ComplexityEnabled
            MinPasswordLength           = $pso.MinPasswordLength
            PasswordHistoryCount        = $pso.PasswordHistoryCount
            ReversibleEncryptionEnabled = [bool]$pso.ReversibleEncryptionEnabled
            MinPasswordAge              = [TimeSpan]$pso.MinPasswordAge
            MaxPasswordAge              = [TimeSpan]$pso.MaxPasswordAge
            LockoutThreshold            = $pso.LockoutThreshold
            LockoutObservationWindow    = [TimeSpan]$pso.LockoutObservationWindow
            LockoutDuration             = [TimeSpan]$pso.LockoutDuration
        }
        if ($pso.Description) { $params.Description = $pso.Description }

        $existing = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($pso.Name)'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            try {
                New-ADFineGrainedPasswordPolicy @params -ErrorAction Stop
                Write-Log "  + $($pso.Name) (precedence $($pso.Precedence), longueur $($pso.MinPasswordLength))" "Green"
                Add-SetupStat "PSO" "Created"
            } catch {
                Write-Log "  ! $($pso.Name) : $($_.Exception.Message)" "Yellow"
                Add-SetupStat "PSO" "Warning"; continue
            }
        } else {
            Write-Log "  = $($pso.Name) (existe)" "DarkGray"
            Add-SetupStat "PSO" "Existing"
        }

        # Application aux groupes / utilisateurs (les noms builtin sont resolus par SID)
        foreach ($subject in $pso.AppliesTo) {
            $resolved = Get-BuiltinGroup -GroupName $subject
            try {
                Add-ADFineGrainedPasswordPolicySubject -Identity $pso.Name -Subjects $resolved -ErrorAction Stop
                Write-Log "    -> applique a $subject" "DarkGray"
            } catch {
                if ("$($_.Exception.Message)" -match 'already|deja') { Write-Log "    = deja applique a $subject" "DarkGray" }
                else { Write-Log "    ! application a $subject : $($_.Exception.Message)" "Yellow" }
            }
        }
        if ($pso._risk) { Write-Log "    [RISQUE : $($pso._risk)]" "DarkYellow" }
    }
}

function New-LabAuthSilos {
    param([string]$ConfigDir, [string]$DomainNetbios)
    $cfg = Read-Config "tier0.json" -ConfigDir $ConfigDir
    if (-not $cfg.Silos) { return }
    Write-Log "--- Silos d'authentification ---" "Cyan"

    # Prerequis : niveau fonctionnel de foret >= 2012 R2 (Windows2012R2Forest)
    try {
        $forest = Get-ADForest
        $levelOk = $forest.ForestMode -notin @('Windows2000Forest','Windows2003Forest','Windows2008Forest','Windows2008R2Forest','Windows2012Forest')
        if (-not $levelOk) {
            Write-Log "  ! Niveau fonctionnel de foret trop bas ($($forest.ForestMode)) - silos ignores" "Yellow"
            return
        }
    } catch { Write-Log "  ! Impossible de verifier le niveau fonctionnel : $_" "Yellow" }

    foreach ($silo in $cfg.Silos) {
        if ($silo.Apply -eq $false) { continue }
        if (-not $silo.Name) { Write-Log "  ! Silo sans nom ignore" "Yellow"; continue }

        $enforce   = [bool]$silo.Enforce
        $modeLabel = if ($enforce) { "ENFORCE" } else { "AUDIT" }

        # --- 1. Authentication Policy (TGT court + restriction d'ouverture de session) ---
        $polName = if ($silo.PolicyName) { $silo.PolicyName } else { "$($silo.Name)_Policy" }
        $tgtLife = if ($silo.UserTGTLifetimeMins) { [int]$silo.UserTGTLifetimeMins } else { 240 }

        $polParams = @{
            Name                          = $polName
            UserTGTLifetimeMins           = $tgtLife
            ProtectedFromAccidentalDeletion = $false
        }
        if ($enforce) { $polParams.Enforce = $true } else { $polParams.AuditOnly = $true }

        # SDDL : seuls les membres du groupe indique peuvent demander un TGT pour ces comptes
        if ($silo.AllowedToAuthenticateFromGroup) {
            $gSid = Get-GroupSID -GroupName $silo.AllowedToAuthenticateFromGroup -DomainNetbios $DomainNetbios
            if ($gSid) {
                $polParams.UserAllowedToAuthenticateFrom =
                    "O:SYG:SYD:(XA;OICI;CR;;;WD;(Member_of {SID($($gSid.Value))}))"
            }
        }

        $existPol = Get-ADAuthenticationPolicy -Filter "Name -eq '$polName'" -ErrorAction SilentlyContinue
        if (-not $existPol) {
            try {
                New-ADAuthenticationPolicy @polParams -ErrorAction Stop
                Write-Log "  + Politique $polName (TGT $tgtLife min, $modeLabel)" "Green"
                Add-SetupStat "Silos auth" "Created"
            } catch {
                Write-Log "  ! Politique $polName : $($_.Exception.Message)" "Yellow"
                Add-SetupStat "Silos auth" "Warning"; continue
            }
        } else {
            Write-Log "  = Politique $polName (existe)" "DarkGray"
            Add-SetupStat "Silos auth" "Existing"
        }

        # --- 2. Authentication Policy Silo ---
        $siloParams = @{ Name = $silo.Name; UserAuthenticationPolicy = $polName
                         ComputerAuthenticationPolicy = $polName; ServiceAuthenticationPolicy = $polName
                         ProtectedFromAccidentalDeletion = $false }
        if ($enforce) { $siloParams.Enforce = $true } else { $siloParams.AuditOnly = $true }
        if ($silo.Description) { $siloParams.Description = $silo.Description }

        $existSilo = Get-ADAuthenticationPolicySilo -Filter "Name -eq '$($silo.Name)'" -ErrorAction SilentlyContinue
        if (-not $existSilo) {
            try {
                New-ADAuthenticationPolicySilo @siloParams -ErrorAction Stop
                Write-Log "  + Silo $($silo.Name) ($modeLabel)" "Green"
            } catch {
                Write-Log "  ! Silo $($silo.Name) : $($_.Exception.Message)" "Yellow"
                Add-SetupStat "Silos auth" "Warning"; continue
            }
        } else {
            Write-Log "  = Silo $($silo.Name) (existe)" "DarkGray"
        }

        # --- 3. Affectation des comptes au silo ---
        foreach ($member in $silo.Members) {
            $acct = Get-ADUser -Filter "SamAccountName -eq '$member'" -ErrorAction SilentlyContinue
            if (-not $acct) { Write-Log "    ! compte introuvable : $member" "Yellow"; continue }
            try {
                Grant-ADAuthenticationPolicySiloAccess -Identity $silo.Name -Account $acct -ErrorAction SilentlyContinue
                Set-ADUser -Identity $acct -AuthenticationPolicySilo $silo.Name -ErrorAction Stop
                Write-Log "    -> $member assigne au silo" "DarkGray"
            } catch {
                Write-Log "    ! assignation de $member : $($_.Exception.Message)" "Yellow"
            }
        }

        if (-not $enforce) { Write-Log "    [Mode AUDIT : la restriction n'est pas appliquee, seulement journalisee]" "DarkYellow" }
        if ($silo._risk)   { Write-Log "    [RISQUE : $($silo._risk)]" "DarkYellow" }
    }
}

function New-LabTier0Protection {
    param([string]$ConfigDir, [string]$DomainNetbios)
    if (-not (Test-Path (Join-Path $ConfigDir "tier0.json"))) {
        Write-Log "--- Protection Tier 0 ---" "Cyan"
        Write-Log "  tier0.json absent - PSO et silos ignores" "DarkGray"; return
    }
    $cfg = Read-Config "tier0.json" -ConfigDir $ConfigDir
    if ($cfg.Enabled -eq $false) { Write-Log "  Protection Tier 0 desactivee dans tier0.json" "DarkGray"; return }

    New-LabPSOs       -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios
    New-LabAuthSilos  -ConfigDir $ConfigDir -DomainNetbios $DomainNetbios
}

Export-ModuleMember -Function New-LabTier0Protection
