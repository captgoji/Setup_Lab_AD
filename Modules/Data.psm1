# ==============================================================================
# SetupLab-Version: 2.2
# Data.psm1 - Alimentation des partages en donnees de test (Configs\data.json)
#
# - Contenu aleatoire (incompressible, non dedupliquable) : volumetrie realiste
#   pour les tests de sauvegarde, de chiffrement massif (ransomware), de DLP...
# - Noms de fichiers metier par partage, repartis dans les sous-dossiers existants
# - Dates de creation/modification etalees dans le passe (donnees "dormantes")
# - Idempotent : complete jusqu'a la taille cible, ne regenere pas l'existant
# - Garde-fou d'espace disque : s'arrete avant de saturer le volume
# ==============================================================================

function New-RandomFile {
    param([string]$Path, [long]$SizeBytes, [byte[]]$Buffer, $Rng)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $remaining = $SizeBytes
        while ($remaining -gt 0) {
            $chunk = [int][math]::Min([long]$Buffer.Length, $remaining)
            $Rng.GetBytes($Buffer)
            $stream.Write($Buffer, 0, $chunk)
            $remaining -= $chunk
        }
    } finally {
        $stream.Dispose()
    }
}

function Test-FolderWritable {
    # Teste reellement l'ecriture (cree puis supprime un fichier temoin).
    # Plus fiable que lire les ACL, et gere les heritages casses.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        try { $null = New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop } catch { return $false }
    }
    $probe = Join-Path $Path ".sl_write_test_$PID"
    try {
        [IO.File]::WriteAllText($probe, "x")
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Get-FolderSize {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [long]$sum } else { return [long]0 }
}

function New-LabShareData {
    param([string]$ConfigDir)
    Write-Log "--- Donnees de test dans les partages ---" "Cyan"

    if (-not (Test-Path (Join-Path $ConfigDir "data.json"))) { Write-Log "  data.json absent - ignore" "DarkGray"; return }
    $cfg = Read-Config "data.json" -ConfigDir $ConfigDir
    if (-not $cfg.Enabled) { Write-Log "  Generation desactivee dans data.json" "DarkGray"; return }

    $sharesCfg = Read-Config "shares.json" -ConfigDir $ConfigDir
    $minBytes  = [long]([math]::Max(1, [int]$cfg.MinFileSizeMB)) * 1MB
    $maxBytes  = [long]([math]::Max([int]$cfg.MinFileSizeMB, [int]$cfg.MaxFileSizeMB)) * 1MB
    $maxAge    = if ($cfg.MaxAgeDays) { [int]$cfg.MaxAgeDays } else { 0 }
    $minFree   = [long]$(if ($cfg.MinFreeSpaceGB) { $cfg.MinFreeSpaceGB } else { 5 }) * 1GB

    # --- Plan : ce qu'il manque par partage ---
    $plan = @()
    foreach ($d in $cfg.Shares) {
        if ($d.Apply -eq $false) { continue }
        $share = $sharesCfg | Where-Object { $_.ShareName -eq $d.Share } | Select-Object -First 1
        if (-not $share)                   { Write-Log "  ! Partage '$($d.Share)' absent de shares.json" "Yellow"; continue }
        if (-not (Test-Path $share.Path))  { Write-Log "  ! Dossier introuvable : $($share.Path)" "Yellow"; continue }

        $target  = [long]$d.SizeMB * 1MB
        $current = Get-FolderSize -Path $share.Path
        if ($current -ge $target) {
            Write-Log ("  = {0,-14} deja alimente ({1:N0} Mo / {2:N0} Mo)" -f $d.Share, ($current / 1MB), $d.SizeMB) "DarkGray"
            Add-SetupStat "Donnees (partages)" "Existing"
            continue
        }
        $plan += [pscustomobject]@{ Def = $d; Share = $share; Missing = $target - $current; Current = $current }
    }
    if ($plan.Count -eq 0) { return }

    $totalMissing = ($plan | Measure-Object -Property Missing -Sum).Sum
    Write-Log ("  {0:N2} Go a generer sur {1} partage(s) (fichiers de {2} a {3} Mo, marge disque {4} Go)" -f `
        ($totalMissing / 1GB), $plan.Count, ($minBytes / 1MB), ($maxBytes / 1MB), ($minFree / 1GB)) "White"

    $rng    = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] (1MB)
    $now    = Get-Date
    $done   = [long]0
    $sw     = [Diagnostics.Stopwatch]::StartNew()

    try {
        foreach ($p in $plan) {
            $d       = $p.Def
            $root    = $p.Share.Path
            $drive   = New-Object IO.DriveInfo((Split-Path $root -Qualifier))
            $folders = @("") + @($p.Share.SubFolders | Where-Object { $_ })
            $names   = @($d.Names      | Where-Object { $_ }); if ($names.Count -eq 0) { $names = @("Document") }
            $exts    = @($d.Extensions | Where-Object { $_ }); if ($exts.Count  -eq 0) { $exts  = @(".bin") }

            # Ne garder que les dossiers ou le compte courant peut reellement ecrire :
            # un sous-dossier a heritage casse (ex: IT\Logs reserve a GRP_Admins_SI)
            # provoquerait sinon un "acces refuse" en plein milieu de la generation.
            $writable = @($folders | Where-Object { Test-FolderWritable -Path (Join-Path $root $_) })
            if ($writable.Count -eq 0) { $writable = @("") }
            $skipped = @($folders | Where-Object { $writable -notcontains $_ -and $_ -ne "" })
            if ($skipped.Count -gt 0) {
                Write-Log "    (dossiers non accessibles en ecriture, ignores : $($skipped -join ', '))" "DarkGray"
            }

            $generated = [long]0; $files = 0; $stopped = $false
            while ($generated -lt $p.Missing) {
                $size = Get-Random -Minimum $minBytes -Maximum ($maxBytes + 1)
                if ($generated + $size -gt $p.Missing) { $size = $p.Missing - $generated }

                if ($drive.AvailableFreeSpace - $size -lt $minFree) {
                    Write-Log ("  ! {0} : espace disque insuffisant sur {1} (reste {2:N1} Go, marge {3} Go) - arret" -f `
                        $d.Share, $drive.Name, ($drive.AvailableFreeSpace / 1GB), ($minFree / 1GB)) "Yellow"
                    Add-SetupStat "Donnees (partages)" "Warning"
                    $stopped = $true; break
                }

                # Date coherente avec le nom et le dossier d'annee
                $date = if ($maxAge -gt 0) { $now.AddDays(-(Get-Random -Maximum $maxAge)).AddMinutes(-(Get-Random -Maximum 1440)) } else { $now }

                $dir = Join-Path $root $writable[(Get-Random -Maximum $writable.Count)]
                if ($d.YearFolders) { $dir = Join-Path $dir $date.Year }
                if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }

                $fileName = "{0}_{1:yyyy-MM}_{2:D4}{3}" -f $names[(Get-Random -Maximum $names.Count)], $date,
                            (Get-Random -Maximum 10000), $exts[(Get-Random -Maximum $exts.Count)]
                $file = Join-Path $dir $fileName
                if (Test-Path -LiteralPath $file) { continue }

                try {
                    New-RandomFile -Path $file -SizeBytes $size -Buffer $buffer -Rng $rng
                } catch {
                    # Acces refuse malgre le pre-filtrage (ACL ponctuelle) : on ignore ce fichier
                    Write-Log "    ! ecriture refusee : $file - ignore" "DarkGray"
                    continue
                }
                if ($maxAge -gt 0) {
                    try {
                        $item = Get-Item -LiteralPath $file
                        $item.CreationTime   = $date
                        $item.LastWriteTime  = $date.AddDays((Get-Random -Maximum 30)).AddMinutes((Get-Random -Maximum 600))
                        if ($item.LastWriteTime -gt $now) { $item.LastWriteTime = $now }
                        $item.LastAccessTime = $item.LastWriteTime
                    } catch {}
                }

                $generated += $size; $done += $size; $files++
                $pct  = [math]::Min(100, [int](($done / $totalMissing) * 100))
                $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { ($done / 1MB) / $sw.Elapsed.TotalSeconds } else { 0 }
                Write-Progress -Activity "Generation de donnees de test" `
                    -Status ("{0} : {1:N0} / {2:N0} Mo  |  total {3:N2} / {4:N2} Go  |  {5:N0} Mo/s" -f `
                        $d.Share, ($generated / 1MB), ($p.Missing / 1MB), ($done / 1GB), ($totalMissing / 1GB), $rate) `
                    -PercentComplete $pct
            }

            $color = if ($stopped) { "Yellow" } else { "Green" }
            Write-Log ("  + {0,-14} {1,5} fichier(s), {2:N0} Mo ajoutes (total {3:N0} Mo)" -f `
                $d.Share, $files, ($generated / 1MB), (($p.Current + $generated) / 1MB)) $color
            if ($files -gt 0) { Add-SetupStat "Donnees (partages)" "Created" }
            if ($stopped) { break }
        }
    } finally {
        Write-Progress -Activity "Generation de donnees de test" -Completed
        $rng.Dispose()
    }
    Write-Log ("  Termine : {0:N2} Go en {1:mm\:ss}" -f ($done / 1GB), $sw.Elapsed) "Cyan"
}

Export-ModuleMember -Function New-LabShareData
