# ==============================================================================
# SetupLab-Version: 2.2
# Logging.psm1 - Journalisation de ce que Windows ne logge pas nativement
# Pilote par Configs\audit_logging.json (chaque section est optionnelle)
# ==============================================================================

function Test-Apply {
    # Une entree sans champ "Apply" est appliquee ; "Apply": false la desactive
    param($Entry)
    return -not ($null -ne $Entry.Apply -and $Entry.Apply -eq $false)
}

function Set-LabRegistryValue {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    $key  = $Path -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\'
    $kind = [Microsoft.Win32.RegistryValueKind]$Type
    $data = switch ($Type) {
        "DWord"       { [int]$Value }
        "QWord"       { [long]$Value }
        "MultiString" { [string[]]$Value }
        default       { [string]$Value }
    }
    [Microsoft.Win32.Registry]::SetValue($key, $Name, $data, $kind)
}

# ------------------------------------------------------------------------------

function Set-LabAuditRegistry {
    param($Entries)
    Write-Log "  > Registre (PowerShell, ligne de commande, NTLM, LDAP...)" "Cyan"
    foreach ($e in $Entries) {
        if (-not (Test-Apply $e)) { Write-Log "    - $($e.Name) [desactive dans la config]" "DarkGray"; continue }
        try {
            if ($e.EnsureDirectory) { $null = New-Item -ItemType Directory -Force -Path $e.Value }
            Set-LabRegistryValue -Path $e.Path -Name $e.Name -Type $e.Type -Value $e.Value
            Write-Log "    + $($e.Name) = $($e.Value)  ($($e.Why))" "Green"
            Add-SetupStat "Journalisation" "Created"
        } catch {
            Write-Log "    ! $($e.Path)\$($e.Name) : $($_.Exception.Message)" "Yellow"
            Add-SetupStat "Journalisation" "Warning"
        }
    }
}

function Set-LabAdvancedAudit {
    # auditpol avec les GUID de sous-categories : fonctionne quelle que soit la langue
    param($Config)
    Write-Log "  > Strategie d'audit avancee (auditpol)" "Cyan"
    if ($Config.ForceSubcategoryOverride) {
        Set-LabRegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "SCENoApplyLegacyAuditPolicy" -Type DWord -Value 1
        Write-Log "    + SCENoApplyLegacyAuditPolicy = 1 (sous-categories prioritaires)" "Green"
    }
    foreach ($s in $Config.Subcategories) {
        $succ = if ($s.Success) { "enable" } else { "disable" }
        $fail = if ($s.Failure) { "enable" } else { "disable" }
        $out  = & auditpol.exe /set "/subcategory:$($s.Guid)" "/success:$succ" "/failure:$fail" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $flags = @(); if ($s.Success) { $flags += "S" }; if ($s.Failure) { $flags += "F" }
            Write-Log ("    + {0,-38} [{1}]  {2}" -f $s.Name, ($flags -join '/'), $s.Why) "Green"
            Add-SetupStat "Journalisation" "Created"
        } else {
            Write-Log "    ! $($s.Name) : $($out -join ' ')" "Yellow"
            Add-SetupStat "Journalisation" "Warning"
        }
    }
}

function Set-LabEventLogs {
    # Active les journaux desactives par defaut et agrandit ceux trop petits
    # (ne reduit jamais une taille existante)
    param($Entries)
    Write-Log "  > Journaux d'evenements" "Cyan"
    foreach ($e in $Entries) {
        if (-not (Test-Apply $e)) { Write-Log "    - $($e.Name) [desactive dans la config]" "DarkGray"; continue }
        $log = Get-WinEvent -ListLog $e.Name -ErrorAction SilentlyContinue
        if (-not $log) { Write-Log "    - $($e.Name) [absent sur ce serveur]" "DarkGray"; continue }
        try {
            $changes = @()
            if ($e.MaxSizeMB) {
                $bytes = [int64]$e.MaxSizeMB * 1MB
                if ($log.MaximumSizeInBytes -lt $bytes) {
                    # Les journaux analytiques/debug doivent etre desactives pour changer la taille
                    if ($log.IsEnabled -and ($log.LogType -eq 'Analytical' -or $log.LogType -eq 'Debug')) {
                        $log.IsEnabled = $false; $log.SaveChanges()
                    }
                    $log.MaximumSizeInBytes = $bytes
                    $changes += "taille $($e.MaxSizeMB) Mo"
                }
            }
            if ($e.Enable -and -not $log.IsEnabled) { $log.IsEnabled = $true; $changes += "active" }
            if ($changes.Count -gt 0) {
                $log.SaveChanges()
                Write-Log "    + $($e.Name) : $($changes -join ', ')" "Green"
                Add-SetupStat "Journalisation" "Created"
            } else {
                Write-Log "    = $($e.Name) (deja conforme)" "DarkGray"
                Add-SetupStat "Journalisation" "Existing"
            }
        } catch {
            Write-Log "    ! $($e.Name) : $($_.Exception.Message)" "Yellow"
            Add-SetupStat "Journalisation" "Warning"
        }
    }
}

function Set-LabFileSacl {
    # SACL NTFS : sans elles, la sous-categorie "File System" ne produit rien (4663)
    param($Entries, [string]$DomainNetbios)
    Write-Log "  > SACL NTFS" "Cyan"
    foreach ($e in $Entries) {
        if (-not (Test-Apply $e)) { continue }
        if (-not (Test-Path -LiteralPath $e.Path)) { Write-Log "    - $($e.Path) [introuvable]" "DarkGray"; continue }
        try {
            $sid  = Get-GroupSID -GroupName $e.Principal -DomainNetbios $DomainNetbios
            $acl  = Get-Acl -LiteralPath $e.Path -Audit
            $rule = New-Object System.Security.AccessControl.FileSystemAuditRule(
                $sid,
                [System.Security.AccessControl.FileSystemRights]$e.Rights,
                "ContainerInherit,ObjectInherit", "None",
                [System.Security.AccessControl.AuditFlags]$e.Flags)
            $acl.AddAuditRule($rule)
            Set-Acl -LiteralPath $e.Path -AclObject $acl -ErrorAction Stop
            Write-Log "    + $($e.Path) : $($e.Principal) [$($e.Rights)] ($($e.Flags))" "Green"
            Add-SetupStat "Journalisation" "Created"
        } catch {
            Write-Log "    ! $($e.Path) : $($_.Exception.Message)" "Yellow"
            Add-SetupStat "Journalisation" "Warning"
        }
    }
}

function Set-LabDirectorySacl {
    # SACL AD : necessaires pour 5136 (modifications) et 4662 (ex : DCSync)
    param($Entries, [string]$DomainDN, [string]$RootOU, [string]$DomainNetbios)
    Write-Log "  > SACL Active Directory" "Cyan"
    if (-not (Test-Path "AD:\")) { Write-Log "    ! Lecteur AD:\ indisponible" "Yellow"; return }
    foreach ($e in $Entries) {
        if (-not (Test-Apply $e)) { continue }
        $dn = Resolve-LabToken -Value $e.Target -RootOU $RootOU -DomainDN $DomainDN
        try {
            $sid  = Get-GroupSID -GroupName $e.Principal -DomainNetbios $DomainNetbios
            $acl  = Get-Acl -Path "AD:\$dn" -Audit
            $inh  = if ($e.Inheritance) { $e.Inheritance } else { "All" }
            $rule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
                $sid,
                [System.DirectoryServices.ActiveDirectoryRights]$e.Rights,
                [System.Security.AccessControl.AuditFlags]$e.Flags,
                [System.DirectoryServices.ActiveDirectorySecurityInheritance]$inh)
            $acl.AddAuditRule($rule)
            Set-Acl -Path "AD:\$dn" -AclObject $acl -ErrorAction Stop
            Write-Log "    + $dn : $($e.Principal) [$($e.Rights)]  ($($e.Why))" "Green"
            Add-SetupStat "Journalisation" "Created"
        } catch {
            Write-Log "    ! $dn : $($_.Exception.Message)" "Yellow"
            Add-SetupStat "Journalisation" "Warning"
        }
    }
}

function Set-LabSmbAudit {
    # N'applique que les parametres supportes par l'OS (certains n'existent qu'en 2025)
    param($Config)
    Write-Log "  > Audit SMB serveur" "Cyan"
    $cmd   = Get-Command Set-SmbServerConfiguration -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Log "    ! Set-SmbServerConfiguration indisponible" "Yellow"; return }
    $splat = @{}
    foreach ($p in $Config.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        if ($cmd.Parameters.ContainsKey($p.Name)) { $splat[$p.Name] = [bool]$p.Value }
        else { Write-Log "    - $($p.Name) [non supporte sur cet OS]" "DarkGray" }
    }
    if ($splat.Count -eq 0) { return }
    try {
        Set-SmbServerConfiguration @splat -Force -ErrorAction Stop
        Write-Log "    + $(($splat.Keys | ForEach-Object { "$_=$($splat[$_])" }) -join ', ')" "Green"
        Add-SetupStat "Journalisation" "Created"
    } catch { Write-Log "    ! $($_.Exception.Message)" "Yellow"; Add-SetupStat "Journalisation" "Warning" }
}

function Set-LabFirewallLog {
    param($Config)
    if (-not (Test-Apply $Config)) { return }
    Write-Log "  > Journal du pare-feu Windows" "Cyan"
    try {
        Set-NetFirewallProfile -All `
            -LogBlocked $(if ($Config.LogBlocked) { 'True' } else { 'False' }) `
            -LogAllowed $(if ($Config.LogAllowed) { 'True' } else { 'False' }) `
            -LogMaxSizeKilobytes $Config.MaxSizeKB -ErrorAction Stop
        Write-Log "    + Bloque=$($Config.LogBlocked) Autorise=$($Config.LogAllowed) ($($Config.MaxSizeKB) Ko) -> %SystemRoot%\System32\LogFiles\Firewall\pfirewall.log" "Green"
        Add-SetupStat "Journalisation" "Created"
    } catch { Write-Log "    ! $($_.Exception.Message)" "Yellow"; Add-SetupStat "Journalisation" "Warning" }
}

function Set-LabNetlogonDebug {
    param($Config)
    if (-not $Config.DebugLogging) { return }
    Write-Log "  > Debug Netlogon" "Cyan"
    $out = & nltest.exe /dbflag:0x2080ffff 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "    + Actif -> %SystemRoot%\debug\netlogon.log" "Green"
        Add-SetupStat "Journalisation" "Created"
    } else { Write-Log "    ! nltest : $($out -join ' ')" "Yellow" }
}

function Resolve-SysmonFile {
    # Cherche un fichier relatif dans Modules\ puis Configs\ (ou chemin absolu)
    param([string]$RelativePath, [string[]]$SearchDirs)
    if (-not $RelativePath) { return $null }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        if (Test-Path $RelativePath) { return $RelativePath } else { return $null }
    }
    foreach ($d in $SearchDirs) {
        if (-not $d) { continue }
        $candidate = Join-Path $d $RelativePath
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Install-LabSysmon {
    # Installation / mise a jour NON INTERACTIVE de Sysmon :
    #   Sysmon64.exe -accepteula -i <config.xml>   (installation)
    #   Sysmon64.exe -c <config.xml>               (mise a jour si deja installe)
    param($Config, [string]$ConfigDir, [string]$ModulesDir)
    if (-not (Test-Apply $Config)) { return }
    Write-Log "  > Sysmon" "Cyan"

    $searchDirs = @($ModulesDir, $ConfigDir)
    $bin = $null
    foreach ($b in @($Config.BinaryPath, "Sysmon\Sysmon64.exe", "Sysmon64.exe")) {
        $bin = Resolve-SysmonFile -RelativePath $b -SearchDirs $searchDirs
        if ($bin) { break }
    }
    if (-not $bin) {
        Write-Log "    - Sysmon64.exe introuvable (attendu : Modules\Sysmon\Sysmon64.exe) - ignore" "DarkGray"
        return
    }

    # Le binaire doit etre signe par Microsoft (evite d'executer n'importe quoi en SYSTEM)
    $sig = Get-AuthenticodeSignature -FilePath $bin
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Write-Log "    ! Signature invalide ou non Microsoft sur $bin ($($sig.Status)) - installation annulee" "Yellow"
        Add-SetupStat "Journalisation" "Warning"
        return
    }

    $conf = $null
    foreach ($c in @($Config.ConfigPath, "Sysmon\sysmonconfig.xml", "sysmonconfig.xml")) {
        $conf = Resolve-SysmonFile -RelativePath $c -SearchDirs $searchDirs
        if ($conf) { break }
    }
    $confTxt = if ($conf) { "config $conf" } else { "config par defaut Sysmon (minimale)" }

    $svcName   = [IO.Path]::GetFileNameWithoutExtension($bin)          # Sysmon64
    $installed = Get-Service -Name $svcName, "Sysmon", "Sysmon64" -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($installed) {
        if (-not $conf) { Write-Log "    = Sysmon deja installe ($($installed.Name))" "DarkGray"; Add-SetupStat "Journalisation" "Existing"; return }
        $sysArgs = @("-accepteula", "-c", $conf)
        $action  = "configuration mise a jour"
    } else {
        $sysArgs = @("-accepteula", "-i")
        if ($conf) { $sysArgs += $conf }
        $action  = "installe"
    }

    $out = & $bin @sysArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        Write-Log "    + Sysmon $action ($confTxt) - service : $($svc.Status)" "Green"
        Write-Log "      Commande : `"$bin`" $($sysArgs -join ' ')" "DarkGray"
        Add-SetupStat "Journalisation" "Created"
    } else {
        Write-Log "    ! Sysmon (code $LASTEXITCODE) : $(($out | Select-Object -Last 3) -join ' ')" "Yellow"
        Add-SetupStat "Journalisation" "Warning"
    }
}

# ------------------------------------------------------------------------------

function Enable-LabAuditLogging {
    param([string]$ConfigDir, [string]$DomainDN, [string]$RootOU, [string]$DomainNetbios, [string]$ModulesDir)
    Write-Log "--- Journalisation avancee ---" "Cyan"

    if (-not (Test-Path (Join-Path $ConfigDir "audit_logging.json"))) {
        Write-Log "  audit_logging.json absent - journalisation ignoree" "DarkGray"; return
    }
    $cfg = Read-Config "audit_logging.json" -ConfigDir $ConfigDir
    if ($cfg.Enabled -eq $false) { Write-Log "  Journalisation desactivee dans la config" "DarkGray"; return }

    if ($cfg.Registry)       { Set-LabAuditRegistry -Entries $cfg.Registry }
    if ($cfg.AdvancedAudit)  { Set-LabAdvancedAudit -Config $cfg.AdvancedAudit }
    if ($cfg.Sysmon)         { Install-LabSysmon    -Config $cfg.Sysmon -ConfigDir $ConfigDir -ModulesDir $ModulesDir }
    if ($cfg.EventLogs)      { Set-LabEventLogs     -Entries $cfg.EventLogs }
    if ($cfg.FileSystemSacl) { Set-LabFileSacl      -Entries $cfg.FileSystemSacl -DomainNetbios $DomainNetbios }
    if ($cfg.DirectorySacl)  { Set-LabDirectorySacl -Entries $cfg.DirectorySacl -DomainDN $DomainDN -RootOU $RootOU -DomainNetbios $DomainNetbios }
    if ($cfg.Smb)            { Set-LabSmbAudit      -Config $cfg.Smb }
    if ($cfg.Firewall)       { Set-LabFirewallLog   -Config $cfg.Firewall }
    if ($cfg.Netlogon)       { Set-LabNetlogonDebug -Config $cfg.Netlogon }
}

Export-ModuleMember -Function Enable-LabAuditLogging
