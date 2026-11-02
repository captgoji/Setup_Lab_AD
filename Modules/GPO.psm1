# ==============================================================================
# SetupLab-Version: 2.2
# GPO.psm1 - Gestion des GPOs
# Inspire de sec_ad/GPO.psm1 avec adaptation pour le lab Setup_Lab_AD
# L'OU racine est parametrable (-RootOU) : plus de chemin NETOPTIMA en dur
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
            'Windows2016Forest' { 2016 ; break }
            'Windows2019Forest' { 2019 ; break }
            'Windows2022Forest' { 2022 ; break }
            'Windows2025Forest' { 2025 ; break }
            '(\d{4})Forest'     { [int]$matches[1] ; break }
            default             { 2016 ; break }   # fallback conservateur
        }
        $domainLevel = switch -Regex ($domain.DomainMode) {
            'Windows2016Domain' { 2016 ; break }
            'Windows2019Domain' { 2019 ; break }
            'Windows2022Domain' { 2022 ; break }
            'Windows2025Domain' { 2025 ; break }
            '(\d{4})Domain'     { [int]$matches[1] ; break }
            default             { 2016 ; break }
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

    Write-Log "--- Import GPOs de securite ---" "Cyan"
    if (-not (Test-Path $GPOConfigFile)) {
        Write-Log "  ! GPO_config.json absent ($GPOConfigFile) - import securite ignore" "Yellow"
        return
    }
    $backupDirs = @(Get-ChildItem $BackupPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\{[0-9a-fA-F-]{36}\}$' })
    if ($backupDirs.Count -eq 0) {
        Write-Log "  ! AUCUN backup {GUID} trouve dans $BackupPath" "Yellow"
        Write-Log "    Copier le dossier Configs\GPO\ (backups Backup-GPO) a cote du script puis relancer." "Yellow"
        Write-Log "    Si le projet vient de git : verifier que Configs/GPO est bien versionne (.gitignore)." "Yellow"
        return
    }
    $withReport = @($backupDirs | Where-Object { Test-Path (Join-Path $_.FullName "gpreport.xml") })
    Write-Log "  Backups trouves : $($backupDirs.Count) dossier(s) {GUID}, dont $($withReport.Count) avec gpreport.xml" "Cyan"
    if ($withReport.Count -lt $backupDirs.Count) {
        Write-Log "  ! $($backupDirs.Count - $withReport.Count) backup(s) sans gpreport.xml : impossible d'identifier leur nom, ignores" "Yellow"
    }
    $gpoConfig    = Get-Content $GPOConfigFile -Raw | ConvertFrom-Json
    $gposToImport = Get-GPOsToImport -FunctionalLevels $FunctionalLevels -GPOConfig $gpoConfig

    Write-Log "  $($gposToImport.Count) GPO(s) a importer pour ce niveau fonctionnel" "Cyan"

    $imported = 0
    $skipped  = 0
    $existing = 0

    foreach ($gpoName in $gposToImport) {
        if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
            Write-Log "  = $gpoName (existe)" "DarkGray"
            Add-SetupStat "GPOs securite" "Existing"
            $existing++
            continue
        }
        $ok = Import-GPOFromBackup -GPOName $gpoName -BackupPath $BackupPath -Domain $DomainName
        if ($ok) {
            Write-Log "  + $gpoName [importe]" "Green"
            Add-SetupStat "GPOs securite" "Created"
            $imported++
        } else {
            Write-Log "  ! $gpoName [backup introuvable]" "Yellow"
            Add-SetupStat "GPOs securite" "Warning"
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
        [string]$DomainDN,
        [string]$RootOU
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

    # Aucune GPO de securite presente (import ignore) -> inutile de tenter les liaisons
    $allTierGPOs = @($gpoConfig.TierMappings.PSObject.Properties | ForEach-Object { $_.Value.gpos }) | Select-Object -Unique
    $present     = @($allTierGPOs | Where-Object { Get-GPO -Name $_ -ErrorAction SilentlyContinue })
    if ($present.Count -eq 0) {
        Write-Log "  ! Aucune des $($allTierGPOs.Count) GPO de securite n'existe dans le domaine - liaison ignoree (voir import ci-dessus)" "Yellow"
        return
    }
    if ($present.Count -lt $allTierGPOs.Count) {
        Write-Log "  $($present.Count)/$($allTierGPOs.Count) GPO de securite presentes - les absentes seront signalees" "Yellow"
    }

    # Construire le mapping dynamiquement depuis ous.json via le champ GPOTier
    $ouConfig  = Read-Config "ous.json" -ConfigDir $ConfigDir
    $tierOUMap = @{}

    foreach ($ou in $ouConfig) {
        if (-not $ou.GPOTier -or $ou.GPOTier -eq "null") { continue }

        # Reconstruire le DN complet de l OU
        $ouName   = Resolve-LabToken -Value $ou.Name -RootOU $RootOU
        $parentDN = Resolve-OUDN -ParentChain $ou.Parent -DomainDN $DomainDN -RootOU $RootOU
        $fullDN   = "OU=$ouName,$parentDN"

        # Une meme valeur GPOTier peut mapper plusieurs OUs (ex: Tier1 et Tier1_Legacy -> Serveurs)
        if (-not $tierOUMap.ContainsKey($ou.GPOTier)) {
            $tierOUMap[$ou.GPOTier] = [System.Collections.Generic.List[string]]::new()
        }
        $tierOUMap[$ou.GPOTier].Add($fullDN)
        Write-Log "  Mapping : $($ou.GPOTier) -> OU=$ouName" "DarkGray"
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
    # GPOs du lab definies dans GPO_config.json (section "LabGPOs") :
    #   - importees depuis Configs\GPO\ si un backup du meme nom existe
    #   - sinon creees vides
    #   - liaisons, "Applique", etat et blocage d'heritage geres ici
    #     (ces informations ne sont pas contenues dans un backup GPO)
    param(
        [string]$GPOConfigFile,
        [string]$DomainDN,
        [string]$DomainName,
        [string]$BackupPath,
        [string]$RootOU
    )
    Write-Log "--- GPOs du lab ---" "Cyan"

    if (-not (Test-Path $GPOConfigFile)) {
        Write-Log "  ! GPO_config.json absent - GPOs du lab ignorees" "Yellow"; return
    }
    $labCfg = (Get-Content $GPOConfigFile -Raw | ConvertFrom-Json).LabGPOs
    if (-not $labCfg -or -not $labCfg.gpos) {
        Write-Log "  ! Section LabGPOs absente de GPO_config.json - GPOs du lab ignorees" "Yellow"; return
    }

    $useBackup = (Test-Path $BackupPath) -and @(Get-ChildItem $BackupPath -Directory -ErrorAction SilentlyContinue).Count -gt 0

    foreach ($gpo in $labCfg.gpos) {
        if (-not $gpo.Name) { continue }
        $existing = Get-GPO -Name $gpo.Name -ErrorAction SilentlyContinue

        if (-not $existing) {
            $imported = $false
            if ($useBackup) { $imported = Import-GPOFromBackup -GPOName $gpo.Name -BackupPath $BackupPath -Domain $DomainName }
            if ($imported) {
                Write-Log "  + $($gpo.Name) [importee depuis backup]" "Green"
            } else {
                New-GPO -Name $gpo.Name -Comment $gpo.Comment | Out-Null
                Write-Log "  + $($gpo.Name) [creee vide - aucun backup]" "Yellow"
            }
            Add-SetupStat "GPOs lab" "Created"
        } elseif ($existing.User.DSVersion -eq 0 -and $existing.Computer.DSVersion -eq 0 -and $useBackup -and
                  (Import-GPOFromBackup -GPOName $gpo.Name -BackupPath $BackupPath -Domain $DomainName)) {
            # GPO deja presente mais vide (ancienne version du lab) -> on y importe le backup
            Write-Log "  + $($gpo.Name) [existait vide - backup importe]" "Green"
            Add-SetupStat "GPOs lab" "Created"
        } else {
            Write-Log "  = $($gpo.Name) (existe)" "DarkGray"
            Add-SetupStat "GPOs lab" "Existing"
        }

        $obj = Get-GPO -Name $gpo.Name -ErrorAction SilentlyContinue
        if (-not $obj) { continue }

        # Etat (Import-GPO ne restaure pas l'etat de la GPO)
        $status = if ($gpo.Disabled) { "AllSettingsDisabled" } elseif ($gpo.Status) { $gpo.Status } else { $null }
        if ($status -and "$($obj.GpoStatus)" -ne $status) {
            $obj.GpoStatus = $status
            Write-Log "    Etat : $status" "DarkGray"
        }

        # Liaisons
        $targets = @($gpo.LinkTo | Where-Object { $_ } | ForEach-Object { Resolve-LabToken -Value $_ -RootOU $RootOU -DomainDN $DomainDN })
        foreach ($target in $targets) {
            if (-not (Get-ADObject -Filter "DistinguishedName -eq '$target'" -ErrorAction SilentlyContinue)) {
                Write-Log "    ! Cible de liaison introuvable : $target" "Yellow"; continue
            }
            $link = (Get-GPInheritance -Target $target).GpoLinks | Where-Object { $_.DisplayName -eq $gpo.Name }
            if (-not $link) { New-GPLink -Name $gpo.Name -Target $target | Out-Null }
            if ($gpo.Enforced) { Set-GPLink -Name $gpo.Name -Target $target -Enforced Yes | Out-Null }
            $flag = if ($gpo.Enforced) { " [Applique]" } else { "" }
            $verb = if ($link) { "=" } else { "+" }
            Write-Log "    $verb Liee a $(($target -split ',')[0])$flag" $(if ($link) { "DarkGray" } else { "Green" })
        }
        if ($targets.Count -gt 1) { Write-Log "    Liee a $($targets.Count) emplacements" "DarkYellow" }
        if ($targets.Count -eq 0) { Write-Log "    Aucune liaison" "DarkGray" }
    }

    foreach ($ou in $labCfg.BlockInheritance) {
        $dn = Resolve-LabToken -Value $ou -RootOU $RootOU -DomainDN $DomainDN
        if (-not (Get-ADObject -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
            Write-Log "  ! OU introuvable pour blocage d'heritage : $dn" "Yellow"; continue
        }
        Set-GPInheritance -Target $dn -IsBlocked Yes | Out-Null
        Write-Log "  Heritage bloque : $dn" "DarkYellow"
    }
}

Export-ModuleMember -Function Get-FunctionalLevel, Get-GPOsToImport, Import-GPOFromBackup, Import-SecurityGPOs, Set-GPOsToTiers, New-LabGPOs