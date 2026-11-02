# ==============================================================================
# SetupLab-Version: 2.2
# Dfs.psm1 - Espace de noms DFS de domaine (DomainV2)
# Les cibles sont les partages caches crees par Shares.psm1 (ex : RH$)
# ==============================================================================

function Set-DfsFolderVisibility {
    # Permissions de lecture du dossier DFS -> ce que l'ABE du namespace affiche.
    # Independant du NTFS de la cible : c'est voulu (cas d'incoherence testable).
    param([string]$FolderPath, [string[]]$Accounts, [string]$DomainNetbios)

    $dfsutil = Join-Path $env:SystemRoot "System32\dfsutil.exe"
    if (-not (Test-Path $dfsutil)) {
        Write-Log "    ! dfsutil.exe absent (RSAT-DFS-Mgmt-Con) - visibilite non appliquee" "Yellow"
        return
    }

    $first = $true
    foreach ($acc in (@($Accounts) + "Domain Admins" | Select-Object -Unique)) {
        $name = Resolve-AccountName -Name $acc -DomainNetbios $DomainNetbios
        if (-not $name) { continue }
        $dfsArgs = @("property", "sd", "grant", $FolderPath, "$($name):RX")
        if ($first) { $dfsArgs += @("protect", "replace") }   # 1er ACE : remplace et coupe l'heritage
        $out = & $dfsutil @dfsArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "    ! dfsutil ($acc) : $($out -join ' ')" "Yellow"
        }
        $first = $false
    }
    Write-Log "    Visible (ABE) par : $((@($Accounts) + 'Domain Admins' | Select-Object -Unique) -join ', ')" "DarkGray"
}

function New-LabDfs {
    param([string]$ConfigDir, [string]$DomainName, [string]$DomainNetbios)
    Write-Log "--- DFS Namespace ---" "Cyan"

    if (-not (Test-Path (Join-Path $ConfigDir "dfs.json"))) {
        Write-Log "  dfs.json absent - DFS ignore" "DarkGray"; return
    }
    $cfg = Read-Config "dfs.json" -ConfigDir $ConfigDir
    if (-not $cfg.Enabled) { Write-Log "  DFS desactive dans dfs.json" "DarkGray"; return }

    if (-not (Get-Module -ListAvailable -Name DFSN)) {
        Write-Log "  ! Module DFSN absent (role FS-DFS-Namespace / RSAT-DFS-Mgmt-Con non installe)" "Yellow"; return
    }
    Import-Module DFSN -ErrorAction Stop

    $svc = Get-Service -Name Dfs -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log "  ! Service DFS Namespace introuvable" "Yellow"; return }
    if ($svc.StartType -eq 'Disabled') { Set-Service -Name Dfs -StartupType Automatic }
    if ($svc.Status -ne 'Running')     { Start-Service -Name Dfs }

    $cs         = Get-CimInstance Win32_ComputerSystem
    $serverFqdn = "$($cs.DNSHostName).$($cs.Domain)"
    $nsName     = $cfg.NamespaceName
    $nsPath     = "\\$DomainName\$nsName"

    # --- Racine du namespace ---
    $null = New-Item -ItemType Directory -Force -Path $cfg.RootFolder
    if (-not (Get-SmbShare -Name $nsName -ErrorAction SilentlyContinue)) {
        $everyone = Resolve-AccountName -Name "Everyone"       -DomainNetbios $DomainNetbios
        $admins   = Resolve-AccountName -Name "Administrators" -DomainNetbios $DomainNetbios
        New-SmbShare -Name $nsName -Path $cfg.RootFolder -ReadAccess $everyone -FullAccess $admins `
            -Description "Racine DFS $nsName" -ErrorAction Stop | Out-Null
        Write-Log "  + Partage racine \\$env:COMPUTERNAME\$nsName" "Green"
    }

    $root = $null
    try { $root = Get-DfsnRoot -Path $nsPath -ErrorAction Stop } catch {}
    if (-not $root) {
        try {
            New-DfsnRoot -Path $nsPath -TargetPath "\\$serverFqdn\$nsName" -Type DomainV2 `
                -Description $cfg.Description -ErrorAction Stop | Out-Null
            if ($cfg.EnableABE) { Set-DfsnRoot -Path $nsPath -EnableAccessBasedEnumeration $true -ErrorAction Stop | Out-Null }
            $abeTxt = if ($cfg.EnableABE) { "ABE active" } else { "sans ABE" }
            Write-Log "  + Namespace $nsPath (DomainV2, $abeTxt)" "Green"
            Add-SetupStat "Namespace DFS" "Created"
        } catch {
            Write-Log "  ! Creation namespace echouee : $($_.Exception.Message)" "Yellow"
            Add-SetupStat "Namespace DFS" "Warning"
            return
        }
    } else {
        Write-Log "  = Namespace $nsPath (existe, configuration non modifiee)" "DarkGray"
        Add-SetupStat "Namespace DFS" "Existing"
    }

    # --- Dossiers DFS ---
    foreach ($share in (Read-Config "shares.json" -ConfigDir $ConfigDir)) {
        if (-not $share.Dfs) { continue }
        $folder      = if ($share.Dfs.Folder)      { $share.Dfs.Folder }      else { $share.ShareName }
        $targetShare = if ($share.Dfs.TargetShare) { $share.Dfs.TargetShare } else { "$($share.ShareName)`$" }
        $folderPath  = "$nsPath\$folder"
        $mainTarget  = "\\$serverFqdn\$targetShare"

        $exists = $null
        try { $exists = Get-DfsnFolder -Path $folderPath -ErrorAction Stop } catch {}
        if (-not $exists) {
            try {
                New-DfsnFolder -Path $folderPath -TargetPath $mainTarget `
                    -Description "Partage $($share.ShareName)" -ErrorAction Stop | Out-Null
                Write-Log "  + $folderPath -> $mainTarget" "Green"
                Add-SetupStat "Dossiers DFS" "Created"
            } catch {
                Write-Log "  ! $folderPath : $($_.Exception.Message)" "Yellow"
                Add-SetupStat "Dossiers DFS" "Warning"
                continue
            }
        } else {
            Write-Log "  = $folderPath (existe)" "DarkGray"
            Add-SetupStat "Dossiers DFS" "Existing"
        }

        # Cibles supplementaires (2e serveur, cible obsolete...)
        foreach ($t in $share.Dfs.ExtraTargets) {
            if (-not $t.Path) { continue }
            $state = if ($t.State) { $t.State } else { "Online" }
            $tExists = $null
            try { $tExists = Get-DfsnFolderTarget -Path $folderPath -TargetPath $t.Path -ErrorAction Stop } catch {}
            if ($tExists) { Write-Log "    = Cible $($t.Path) (existe)" "DarkGray"; continue }
            try {
                New-DfsnFolderTarget -Path $folderPath -TargetPath $t.Path -State $state -ErrorAction Stop | Out-Null
                Write-Log "    + Cible supplementaire $($t.Path) [$state]" "DarkYellow"
            } catch {
                Write-Log "    ! Cible $($t.Path) non ajoutee (serveur injoignable ?) : $($_.Exception.Message)" "Yellow"
            }
        }

        # Visibilite ABE du dossier DFS
        if ($share.Dfs.VisibleTo -and @($share.Dfs.VisibleTo).Count -gt 0) {
            Set-DfsFolderVisibility -FolderPath $folderPath -Accounts $share.Dfs.VisibleTo -DomainNetbios $DomainNetbios
        } else {
            Write-Log "    Visible par tous (aucune restriction ABE sur le dossier DFS)" "DarkGray"
        }
    }
}

Export-ModuleMember -Function New-LabDfs
