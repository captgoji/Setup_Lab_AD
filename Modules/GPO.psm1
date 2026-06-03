# ==============================================================================
# GPO.psm1 - Gestion des GPOs
# Inspire de sec_ad/GPO.psm1 avec adaptation pour le lab Setup_Lab_AD
# ==============================================================================

function Get-FunctionalLevel {
    # Detecte le niveau fonctionnel du domaine/foret
    # Retourne @{ ForestLevel = int; DomainLevel = int }
    param([string]$DomainName)
    try {
        Write-Log "--- Detection du niveau fonctionnel ---" "Cyan"
        $forest = Get-ADForest -Identity $DomainName
        $domain = Get-ADDomain -Identity $DomainName

        $forestLevel = switch -Regex ($forest.ForestMode) {
            'Windows2016Forest' { 2016 }
            'Windows2019Forest' { 2019 }
            'Windows2022Forest' { 2022 }
            'Windows2025Forest' { 2025 }
            '(\d{4})Forest'     { [int]$matches[1] }
            default             { 2016 }   # fallback conservateur
        }
        $domainLevel = switch -Regex ($domain.DomainMode) {
            'Windows2016Domain' { 2016 }
            'Windows2019Domain' { 2019 }
            'Windows2022Domain' { 2022 }
            'Windows2025Domain' { 2025 }
            '(\d{4})Domain'     { [int]$matches[1] }
            default             { 2016 }
        }

        Write-Log "  Foret  : $($forest.ForestMode) -> niveau $forestLevel" "Cyan"
        Write-Log "  Domaine: $($domain.DomainMode) -> niveau $domainLevel" "Cyan"
        return @{ ForestLevel = $forestLevel; DomainLevel = $domainLevel }
    } catch {
        Write-Log "  ! Impossible de detecter le niveau fonctionnel : $_" "Yellow"
        return @{ ForestLevel = 2016; DomainLevel = 2016 }
    }
}

function Get-GPOsToImport {
    # Retourne la liste des GPOs a importer selon le niveau fonctionnel
    param([hashtable]$FunctionalLevels, [object]$GPOConfig)

    $gposToImport = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $GPOConfig.GPOs.Common.gpos) { $gposToImport.Add($g) }

    if ($FunctionalLevels.ForestLevel -ge 2025) {
        Write-Log "  Niveau >= 2025 : ajout GPOs Level2025" "Cyan"
        foreach ($g in $GPOConfig.GPOs.Level2025.gpos) { $gposToImport.Add($g) }
    } elseif ($FunctionalLevels.ForestLevel -le 2016) {
        Write-Log "  Niveau <= 2016 : ajout GPOs Level2016" "Cyan"
        foreach ($g in $GPOConfig.GPOs.Level2016.gpos) { $gposToImport.Add($g) }
    }
    return $gposToImport
}

function Import-GPOFromBackup {
    # Importe une GPO depuis un backup {GUID}
    # Retourne $true si succes, $false sinon
    param([string]$GPOName, [string]$BackupPath, [string]$Domain)

    $backupFolders = Get-ChildItem -Path $BackupPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\{[0-9a-fA-F-]{36}\}$' }

    foreach ($folder in $backupFolders) {
        $reportPath = Join-Path $folder.FullName "gpreport.xml"
        if (-not (Test-Path $reportPath)) { continue }
        try {
            [xml]$report = Get-Content $reportPath -ErrorAction SilentlyContinue
            if ($report.GPO.Name -ne $GPOName) { continue }

            $backupId = $folder.Name -replace '[{}]', ''
            Import-GPO -BackupId $backupId -TargetName $GPOName -Path $BackupPath `
                -Domain $Domain -CreateIfNeeded -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Write-Log "    ! Import backup echoue pour $GPOName : $_" "Yellow"
            return $false
        }
    }
    return $false
}

function Import-SecurityGPOs {
    # Importe les GPOs de securite depuis les backups selon le niveau fonctionnel
    param(
        [string]$GPOConfigFile,
        [string]$BackupPath,
        [string]$DomainName,
        [hashtable]$FunctionalLevels
    )

    if (-not (Test-Path $GPOConfigFile)) {
        Write-Log "  GPO_config.json absent - import securite ignore" "DarkGray"
        return
    }
    if (-not (Test-Path $BackupPath) -or (Get-ChildItem $BackupPath -Directory -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Log "  Dossier GPO\ absent ou vide - import securite ignore" "DarkGray"
        return
    }

    Write-Log "--- Import GPOs de securite ---" "Cyan"
    $gpoConfig    = Get-Content $GPOConfigFile -Raw | ConvertFrom-Json
    $gposToImport = Get-GPOsToImport -FunctionalLevels $FunctionalLevels -GPOConfig $gpoConfig

    Write-Log "  $($gposToImport.Count) GPO(s) a importer pour ce niveau fonctionnel" "Cyan"

    $imported = 0
    $skipped  = 0
    $existing = 0

    foreach ($gpoName in $gposToImport) {
        if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
            Write-Log "  = $gpoName (existe)" "DarkGray"
            $existing++
            continue
        }
        $ok = Import-GPOFromBackup -GPOName $gpoName -BackupPath $BackupPath -Domain $DomainName
        if ($ok) {
            Write-Log "  + $gpoName [importe]" "Green"
            $imported++
        } else {
            Write-Log "  ! $gpoName [backup introuvable]" "Yellow"
            $skipped++
        }
    }
    Write-Log "  Resultat : $imported importees | $existing existantes | $skipped sans backup" "Cyan"
}

function Set-GPOsToTiers {
    # Lie les GPOs aux OUs selon le champ GPOTier du ous.json
    # Le mapping est construit dynamiquement - aucune structure d OUs imposee
    param(
        [string]$GPOConfigFile,
        [string]$ConfigDir,
        [string]$DomainName,
        [string]$DomainDN
    )

    if (-not (Test-Path $GPOConfigFile)) {
        Write-Log "  GPO_config.json absent - liaison tiers ignoree" "DarkGray"
        return
    }

    Write-Log "--- Liaison GPOs aux tiers (depuis ous.json) ---" "Cyan"
    $gpoConfig = Get-Content $GPOConfigFile -Raw | ConvertFrom-Json

    if (-not $gpoConfig.TierMappings) {
        Write-Log "  ! Aucun TierMappings dans GPO_config.json" "Yellow"
        return
    }

    # Construire le mapping dynamiquement depuis ous.json via le champ GPOTier
    $ouConfig  = Read-Config "ous.json" -ConfigDir $ConfigDir
    $tierOUMap = @{}

    foreach ($ou in $ouConfig) {
        if (-not $ou.GPOTier -or $ou.GPOTier -eq "null") { continue }

        # Reconstruire le DN complet de l OU
        $parentDN = Resolve-OUDN -ParentChain $ou.Parent -DomainDN $DomainDN
        $fullDN   = "OU=$($ou.Name),$parentDN"

        # Une meme valeur GPOTier peut mapper plusieurs OUs (ex: Tier1 et Tier1_Legacy -> Serveurs)
        if (-not $tierOUMap.ContainsKey($ou.GPOTier)) {
            $tierOUMap[$ou.GPOTier] = [System.Collections.Generic.List[string]]::new()
        }
        $tierOUMap[$ou.GPOTier].Add($fullDN)
        Write-Log "  Mapping : $($ou.GPOTier) -> OU=$($ou.Name)" "DarkGray"
    }

    if ($tierOUMap.Count -eq 0) {
        Write-Log "  Aucun champ GPOTier defini dans ous.json - liaison ignoree" "Yellow"
        return
    }

    # Lier les GPOs de chaque tier aux OUs correspondantes
    foreach ($tierName in $gpoConfig.TierMappings.PSObject.Properties.Name) {
        if (-not $tierOUMap.ContainsKey($tierName)) {
            Write-Log "  ! Aucune OU avec GPOTier=$tierName dans ous.json" "Yellow"
            continue
        }

        $tierGPOs = $gpoConfig.TierMappings.$tierName.gpos
        Write-Log "  -> $tierName : $($tierGPOs.Count) GPO(s) a lier" "Yellow"

        foreach ($ouTarget in $tierOUMap[$tierName]) {
            if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouTarget'" -ErrorAction SilentlyContinue)) {
                Write-Log "    ! OU introuvable : $ouTarget" "Yellow"
                continue
            }
            Write-Log "    OU cible : $ouTarget" "DarkGray"

            foreach ($gpoName in $tierGPOs) {
                if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
                    Write-Log "    ! GPO introuvable : $gpoName" "Yellow"
                    continue
                }
                try {
                    New-GPLink -Name $gpoName -Target $ouTarget -Domain $DomainName -ErrorAction SilentlyContinue | Out-Null
                    Write-Log "    + $gpoName -> $(($ouTarget -split ',')[0])" "Green"
                } catch {
                    Write-Log "    ! Liaison echouee : $gpoName" "Yellow"
                }
            }
        }
    }
}

function New-LabGPOs {
    # GPOs de base du lab (toujours creees, avec ou sans backups)
    param(
        [string]$DomainDN,
        [string]$DomainName,
        [string]$BackupPath
    )
    Write-Log "--- GPOs de base du lab ---" "Cyan"

    $GPOs = @(
        @{ Name="GPO_Securite_Mots_de_passe"; OUs=@($DomainDN);                                                                                                            Comment="Politique de mots de passe domaine";     Enforced=$false; Disabled=$false }
        @{ Name="GPO_Postes_Standard";        OUs=@("OU=Postes,OU=NETOPTIMA,$DomainDN");                                                                                   Comment="Configuration standard des postes";      Enforced=$false; Disabled=$false }
        @{ Name="GPO_Serveurs_Hardening";     OUs=@("OU=Serveurs,OU=NETOPTIMA,$DomainDN");                                                                                 Comment="Durcissement des serveurs";              Enforced=$true;  Disabled=$false }
        @{ Name="GPO_IT_Outils";              OUs=@("OU=IT,OU=Utilisateurs,OU=NETOPTIMA,$DomainDN");                                                                       Comment="Outils specifiques equipe IT";           Enforced=$false; Disabled=$false }
        @{ Name="GPO_Restricted_Tier0";       OUs=@("OU=Tier0,OU=NETOPTIMA,$DomainDN");                                                                                    Comment="Restrictions renforcees comptes Tier 0"; Enforced=$false; Disabled=$false }
        @{ Name="GPO_Fond_Ecran";             OUs=@($DomainDN);                                                                                                            Comment="Fond d ecran entreprise";                Enforced=$false; Disabled=$false }
        @{ Name="GPO_Proxy_Navigation";       OUs=@("OU=Commercial,OU=Utilisateurs,OU=NETOPTIMA,$DomainDN","OU=Direction,OU=Utilisateurs,OU=NETOPTIMA,$DomainDN");          Comment="Proxy navigation web";                   Enforced=$false; Disabled=$false }
        @{ Name="GPO_Desactivee_Test";        OUs=@();                                                                                                                     Comment="GPO de test desactivee";                 Enforced=$false; Disabled=$true  }
    )

    $useBackup = (Test-Path $BackupPath) -and (Get-ChildItem $BackupPath -Directory -ErrorAction SilentlyContinue).Count -gt 0

    foreach ($gpo in $GPOs) {
        $existing = Get-GPO -Name $gpo.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            $imported = $false
            if ($useBackup) {
                $imported = Import-GPOFromBackup -GPOName $gpo.Name -BackupPath $BackupPath -Domain $DomainName
            }
            if ($imported) {
                Write-Log "  + $($gpo.Name) [importe depuis backup]" "Green"
            } else {
                New-GPO -Name $gpo.Name -Comment $gpo.Comment | Out-Null
                Write-Log "  + $($gpo.Name) [cree vide]" "Green"
            }
            $existing = Get-GPO -Name $gpo.Name -ErrorAction SilentlyContinue
        } else {
            Write-Log "  = $($gpo.Name) (existe)" "DarkGray"
        }

        if ($existing -and $gpo.Disabled) { $existing.GpoStatus = "AllSettingsDisabled" }
        foreach ($ouTarget in $gpo.OUs) {
            try { New-GPLink -Name $gpo.Name -Target $ouTarget -ErrorAction SilentlyContinue | Out-Null } catch {}
            if ($gpo.Enforced) { Set-GPLink -Name $gpo.Name -Target $ouTarget -Enforced Yes -ErrorAction SilentlyContinue | Out-Null }
        }
        if ($gpo.OUs.Count -gt 1) { Write-Log "    Liee a $($gpo.OUs.Count) OUs" "DarkYellow" }
    }

    foreach ($blockedOU in @("OU=Tier0,OU=NETOPTIMA,$DomainDN","OU=Serveurs,OU=NETOPTIMA,$DomainDN")) {
        Set-GPInheritance -Target $blockedOU -IsBlocked Yes -ErrorAction SilentlyContinue | Out-Null
        Write-Log "  Heritage bloque : $blockedOU" "DarkYellow"
    }
}

Export-ModuleMember -Function Get-FunctionalLevel, Get-GPOsToImport, Import-GPOFromBackup, Import-SecurityGPOs, Set-GPOsToTiers, New-LabGPOs