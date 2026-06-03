# ==============================================================================
# Services.psm1 - Services Windows et taches planifiees
# ==============================================================================

function New-WindowsServices {
    param([string]$ConfigDir, [string]$DomainNetbios, [string]$DefaultUserPass)
    Write-Log "--- Services Windows ---" "Cyan"
    $SvcConfig   = Read-Config "users_service.json" -ConfigDir $ConfigDir
    $svcAccounts = (($SvcConfig | ForEach-Object { "$DomainNetbios\$($_.SamAccountName)" }) + "$DomainNetbios\adm_dupont") -join ","

    $tempInf = [IO.Path]::GetTempFileName() + ".inf"
    @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeServiceLogonRight = *S-1-5-20,*S-1-5-19,$svcAccounts
"@ | Out-File $tempInf -Encoding Unicode
    secedit /configure /db "$env:TEMP\secedit.sdb" /cfg $tempInf /quiet 2>$null
    Remove-Item $tempInf -ErrorAction SilentlyContinue

    foreach ($svc in (Read-Config "services.json" -ConfigDir $ConfigDir)) {
        if (Get-Service -Name $svc.Name -ErrorAction SilentlyContinue) {
            Write-Log "  = $($svc.Name) (existe)" "DarkGray"; continue
        }
        $dir  = "C:\Services\$($svc.Name)"
        $ps1  = "$dir\service.ps1"
        $null = New-Item -ItemType Directory -Force -Path $dir
        "`$running = `$true; while (`$running) { Start-Sleep -Seconds 30 }" | Out-File $ps1 -Encoding UTF8
        $bin  = "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ps1`""
        $acct = "$DomainNetbios\$($svc.Account)"
        sc.exe create $svc.Name binPath= $bin DisplayName= $svc.DisplayName start= auto obj= $acct password= $DefaultUserPass 2>$null | Out-Null
        sc.exe description $svc.Name $svc.Description 2>$null | Out-Null
        try   { Start-Service -Name $svc.Name -ErrorAction Stop
                Write-Log "  + $($svc.Name) [Running] ($acct)" "Green" }
        catch { Write-Log "  + $($svc.Name) [Not started] ($acct)" "Yellow" }
    }
}

function New-ScheduledTasks {
    param([string]$ConfigDir, [string]$DomainNetbios, [string]$DefaultUserPass)
    Write-Log "--- Taches planifiees ---" "Cyan"
    $T0Config = Read-Config "users_t0.json" -ConfigDir $ConfigDir
    foreach ($task in (Read-Config "tasks.json" -ConfigDir $ConfigDir)) {
        if (Get-ScheduledTask -TaskName $task.Name -ErrorAction SilentlyContinue) {
            Write-Log "  = $($task.Name) (existe)" "DarkGray"; continue
        }
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Start-Sleep 10"
        $trigger = New-ScheduledTaskTrigger -Daily -At $task.TriggerTime
        $userId  = "$DomainNetbios\$($task.Account)"

        Register-ScheduledTask -TaskName $task.Name -Action $action -Trigger $trigger `
            -Description $task.Description -Force `
            -User $userId -Password $DefaultUserPass -RunLevel Highest | Out-Null

        $isT0  = $T0Config | Where-Object { $_.SamAccountName -eq $task.Account }
        $color = if ($isT0) { "DarkYellow" } else { "Green" }
        $flag  = if ($isT0) { " [RISQUE : compte T0]" } else { "" }
        Write-Log "  + $($task.Name) ($userId)$flag" $color
    }
}

Export-ModuleMember -Function New-WindowsServices, New-ScheduledTasks
