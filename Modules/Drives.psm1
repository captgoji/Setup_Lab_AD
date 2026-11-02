# ==============================================================================
# SetupLab-Version: 2.2
# Drives.psm1 - Lecteurs reseau via GPO (Group Policy Preferences - Drive Maps)
# Comme en production : une GPO utilisateur avec un Drives.xml dans SYSVOL,
# et un ciblage par groupe (Item-Level Targeting).
# ==============================================================================

$script:DriveMapsCSE = "{5794DAFD-BE60-433F-88A2-1A31939AC01F}"   # CSE Drive Maps
$script:GppToolExt   = "{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}"   # Extension GPMC Preferences
$script:NullGuid     = "{00000000-0000-0000-0000-000000000000}"

function Get-StableGuid {
    # GUID deterministe (meme lecteur = meme uid a chaque execution)
    param([string]$Seed)
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed))
    return ([guid]::new($bytes)).ToString().ToUpper()
}

function ConvertTo-XmlAttr { param([string]$Value) [System.Security.SecurityElement]::Escape($Value) }

function Get-SysvolPoliciesPath {
    param([string]$DomainName)
    $sysvol = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue).SysVol
    if ($sysvol -and (Test-Path "$sysvol\$DomainName\Policies")) { return "$sysvol\$DomainName\Policies" }
    return "\\$DomainName\SYSVOL\$DomainName\Policies"
}

function Add-UserExtension {
    # Ajoute Drive Maps a gPCUserExtensionNames en respectant le format attendu :
    # [{CSE}{outil}...] tries par GUID
    param([string]$Current)
    $map = [ordered]@{}
    foreach ($m in [regex]::Matches("$Current", '\[([^\]]+)\]')) {
        $guids = [regex]::Matches($m.Groups[1].Value, '\{[0-9A-Fa-f-]{36}\}') | ForEach-Object { $_.Value.ToUpper() }
        if (-not $guids) { continue }
        $cse = $guids[0]
        if (-not $map.Contains($cse)) { $map[$cse] = [System.Collections.Generic.List[string]]::new() }
        foreach ($t in ($guids | Select-Object -Skip 1)) { if (-not $map[$cse].Contains($t)) { $map[$cse].Add($t) } }
    }
    foreach ($cse in @($script:NullGuid, $script:DriveMapsCSE)) {
        if (-not $map.Contains($cse)) { $map[$cse] = [System.Collections.Generic.List[string]]::new() }
        if (-not $map[$cse].Contains($script:GppToolExt)) { $map[$cse].Add($script:GppToolExt) }
    }
    return (($map.Keys | Sort-Object) | ForEach-Object { "[$_$(($map[$_] | Sort-Object) -join '')]" }) -join ''
}

function Resolve-DrivePath {
    param($Drive, $SharesCfg, $DfsCfg, [string]$DomainName, [string]$ServerFqdn)

    if ($Drive.Path) {
        return $Drive.Path.Replace('{SERVER}', $ServerFqdn).Replace('{DOMAIN}', $DomainName)
    }
    $share = $SharesCfg | Where-Object { $_.ShareName -eq $Drive.Share } | Select-Object -First 1
    if (-not $share) { Write-Log "    ! Partage '$($Drive.Share)' absent de shares.json" "Yellow"; return $null }

    $via = if ($Drive.Via) { $Drive.Via } else { "Dfs" }
    if ($via -eq "Dfs") {
        if (-not $DfsCfg -or -not $DfsCfg.Enabled -or -not $share.Dfs) {
            Write-Log "    ~ $($Drive.Letter): pas de DFS pour '$($Drive.Share)' -> acces SMB direct" "Yellow"
        } else {
            $folder = if ($share.Dfs.Folder) { $share.Dfs.Folder } else { $share.ShareName }
            return "\\$DomainName\$($DfsCfg.NamespaceName)\$folder"
        }
    }
    return "\\$ServerFqdn\$($share.ShareName)"
}

function New-LabDriveMaps {
    param([string]$ConfigDir, [string]$DomainName, [string]$DomainNetbios, [string]$DomainDN, [string]$RootOU)
    Write-Log "--- Lecteurs reseau (GPP Drive Maps) ---" "Cyan"

    if (-not (Test-Path (Join-Path $ConfigDir "drives.json"))) { Write-Log "  drives.json absent - ignore" "DarkGray"; return }
    $cfg = Read-Config "drives.json" -ConfigDir $ConfigDir
    if (-not $cfg.Enabled) { Write-Log "  Lecteurs reseau desactives dans drives.json" "DarkGray"; return }

    $sharesCfg  = Read-Config "shares.json" -ConfigDir $ConfigDir
    $dfsCfg     = if (Test-Path (Join-Path $ConfigDir "dfs.json")) { Read-Config "dfs.json" -ConfigDir $ConfigDir } else { $null }
    $cs         = Get-CimInstance Win32_ComputerSystem
    $serverFqdn = "$($cs.DNSHostName).$($cs.Domain)"

    # --- GPO ---
    $gpo = Get-GPO -Name $cfg.GPOName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $cfg.GPOName -Comment "Mappage des lecteurs reseau (GPP)"
        Write-Log "  + GPO $($cfg.GPOName)" "Green"
        Add-SetupStat "GPOs lab" "Created"
    } else {
        Write-Log "  = GPO $($cfg.GPOName) (existe)" "DarkGray"
    }
    $gpo.GpoStatus = "ComputerSettingsDisabled"   # GPO purement utilisateur
    $guid = "{$($gpo.Id.ToString().ToUpper())}"

    # --- Construction du Drives.xml ---
    $now   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $cfg.Drives) {
        if (-not $d.Letter) { continue }
        $letter = $d.Letter.Substring(0,1).ToUpper()
        $path   = Resolve-DrivePath -Drive $d -SharesCfg $sharesCfg -DfsCfg $dfsCfg -DomainName $DomainName -ServerFqdn $serverFqdn
        if (-not $path) { Add-SetupStat "Lecteurs reseau" "Warning"; continue }
        $label  = if ($d.Label) { $d.Label } else { $d.Share }

        # Ciblage : membre d'au moins un des groupes (OU logique)
        $filters = ""; $targets = @()
        if ($d.Groups -and @($d.Groups).Count -gt 0) {
            $i = 0
            foreach ($g in $d.Groups) {
                $sid  = Get-GroupSID -GroupName $g -DomainNetbios $DomainNetbios
                $name = Resolve-AccountName -Name $g -DomainNetbios $DomainNetbios
                if (-not $sid) { continue }
                $bool = if ($i -eq 0) { "AND" } else { "OR" }
                $filters += "<FilterGroup bool=`"$bool`" not=`"0`" name=`"$(ConvertTo-XmlAttr $name)`" sid=`"$sid`" userContext=`"1`" primaryGroup=`"0`" localGroup=`"0`"/>"
                $targets += $g; $i++
            }
            if ($filters) { $filters = "<Filters>$filters</Filters>" }
        }

        $uid = Get-StableGuid "$guid|$letter"
        $xPath  = ConvertTo-XmlAttr $path
        $xLabel = ConvertTo-XmlAttr $label
        $driveXml = "<Drive clsid=`"{935D1B74-9CB8-4e3c-9914-7DD559B7A417}`" name=`"$($letter):`" status=`"$($letter):`" image=`"2`" changed=`"$now`" uid=`"{$uid}`" bypassErrors=`"1`">" +
                    "<Properties action=`"U`" thisDrive=`"NOCHANGE`" allDrives=`"NOCHANGE`" userName=`"`" path=`"$xPath`" label=`"$xLabel`" persistent=`"1`" useLetter=`"1`" letter=`"$letter`"/>" +
                    $filters + "</Drive>"
        $items.Add($driveXml)

        $who  = if ($targets) { $targets -join ' | ' } else { "tous les utilisateurs" }
        $risk = if ($d._risk) { "  [RISQUE : $($d._risk)]" } else { "" }
        $col  = if ($d._risk) { "DarkYellow" } else { "Green" }
        Write-Log ("    {0}: -> {1}  ({2}){3}" -f $letter, $path, $who, $risk) $col
        Add-SetupStat "Lecteurs reseau" "Created"
    }

    if ($items.Count -eq 0) {
        Write-Log "  ! Aucun lecteur genere - Drives.xml NON modifie (voir erreurs ci-dessus)" "Yellow"
        return
    }

    $xml = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`r`n<Drives clsid=`"{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}`">" + ($items -join '') + "</Drives>"

    # --- Ecriture SYSVOL (uniquement si le contenu a change) ---
    $gpoDir    = Join-Path (Get-SysvolPoliciesPath -DomainName $DomainName) $guid
    $drivesDir = Join-Path $gpoDir "User\Preferences\Drives"
    $drivesXml = Join-Path $drivesDir "Drives.xml"
    $strip     = { param($s) $s -replace 'changed="[^"]*"', '' }
    if ((Test-Path $drivesXml) -and ((& $strip (Get-Content $drivesXml -Raw -Encoding UTF8)).Trim() -eq (& $strip $xml).Trim())) {
        Write-Log "  = Drives.xml inchange" "DarkGray"
    } else {
        $null = New-Item -ItemType Directory -Force -Path $drivesDir
        [IO.File]::WriteAllText($drivesXml, $xml, (New-Object Text.UTF8Encoding($true)))

        # Version utilisateur (+65536) dans l'AD ET dans GPT.ini, sinon les clients ignorent la GPO
        $gpoDN = "CN=$guid,CN=Policies,CN=System,$DomainDN"
        $obj   = Get-ADObject -Identity $gpoDN -Properties versionNumber, gPCUserExtensionNames
        $ver   = [int]$obj.versionNumber + 65536
        Set-ADObject -Identity $gpoDN -Replace @{
            versionNumber         = $ver
            gPCUserExtensionNames = (Add-UserExtension -Current $obj.gPCUserExtensionNames)
        }
        $gptIni = Join-Path $gpoDir "GPT.ini"
        $ini    = if (Test-Path $gptIni) { Get-Content $gptIni -Raw } else { "[General]`r`n" }
        if ($ini -match '(?m)^Version=\d+') { $ini = $ini -replace '(?m)^Version=\d+', "Version=$ver" }
        else { $ini = $ini.TrimEnd() + "`r`nVersion=$ver`r`n" }
        Set-Content -Path $gptIni -Value $ini -Encoding ASCII -NoNewline
        Write-Log "  + Drives.xml ecrit ($($items.Count) lecteur(s)) - version GPO $ver" "Green"
    }

    # --- Liaisons ---
    foreach ($target in $cfg.LinkTo) {
        $dn = Resolve-LabToken -Value $target -RootOU $RootOU -DomainDN $DomainDN
        if (-not (Get-ADObject -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
            Write-Log "  ! Cible de liaison introuvable : $dn" "Yellow"; continue
        }
        $linked = (Get-GPInheritance -Target $dn).GpoLinks | Where-Object { $_.DisplayName -eq $cfg.GPOName }
        if ($linked) { Write-Log "  = Liee a $dn" "DarkGray" }
        else {
            New-GPLink -Name $cfg.GPOName -Target $dn | Out-Null
            Write-Log "  + Liee a $dn" "Green"
        }
    }
}

Export-ModuleMember -Function New-LabDriveMaps
