# ==============================================================================
# SetupLab-Version: 2.2
# Services.psm1 - Services Windows et taches planifiees
# ==============================================================================

function Grant-ServiceLogonRight {
    # Ajoute des comptes au droit "Ouvrir une session en tant que service"
    # SANS ecraser les titulaires actuels (important sur un domaine existant)
    param([string[]]$Accounts)

    $export = Join-Path $env:TEMP "setuplab_rights_export.inf"
    secedit /export /mergedpolicy /cfg $export /areas USER_RIGHTS /quiet | Out-Null

    $holders = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $export) {
        $line = Get-Content $export -Encoding Unicode | Where-Object { $_ -match '^\s*SeServiceLogonRight\s*=' }
        if ($line) {
            (($line -split '=', 2)[1]).Split(',') | ForEach-Object { $_.Trim() } |
                Where-Object { $_ } | ForEach-Object { $holders.Add($_) }
        }
        Remove-Item $export -Force -ErrorAction SilentlyContinue
    }
    # LOCAL SERVICE, NETWORK SERVICE, NT SERVICE\ALL SERVICES (defauts Windows - restaures
    # au passage si une ancienne version du script les avait retires)
    foreach ($base in @("*S-1-5-19", "*S-1-5-20", "*S-1-5-80-0")) { if ($holders -notcontains $base) { $holders.Add($base) } }

    $added = 0
    foreach ($acc in $Accounts) {
        try {
            $sid = ([System.Security.Principal.NTAccount]$acc).Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            Write-Log "  ! Compte introuvable pour SeServiceLogonRight : $acc" "Yellow"; continue
        }
        if ($holders -notcontains "*$sid") { $holders.Add("*$sid"); $added++ }
    }

    if ($added -eq 0) { Write-Log "  = SeServiceLogonRight deja a jour" "DarkGray"; return }

    $tempInf = Join-Path $env:TEMP "setuplab_rights_apply.inf"
    @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeServiceLogonRight = $($holders -join ',')
"@ | Out-File $tempInf -Encoding Unicode
    secedit /configure /db "$env:TEMP\setuplab_secedit.sdb" /cfg $tempInf /areas USER_RIGHTS /quiet | Out-Null
    Remove-Item $tempInf -ErrorAction SilentlyContinue
    Write-Log "  + SeServiceLogonRight : $added compte(s) ajoute(s), titulaires existants conserves" "Green"
}

function Get-LabServiceBinary {
    # Un script PowerShell ne peut pas etre un service (pas de dialogue avec le SCM -> erreur 1053).
    # On compile une fois un vrai service .NET minimal qui ne fait rien.
    $exe = "C:\Services\AuditLabService.exe"
    if (Test-Path $exe) { return $exe }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $exe)
    $cs = @"
using System.ServiceProcess;
public class AuditLabService : ServiceBase {
    public AuditLabService() { ServiceName = "AuditLabService"; CanStop = true; }
    protected override void OnStart(string[] args) { }
    protected override void OnStop() { }
    public static void Main() { ServiceBase.Run(new AuditLabService()); }
}
"@
    try {
        Add-Type -TypeDefinition $cs -ReferencedAssemblies "System.ServiceProcess" `
            -OutputAssembly $exe -OutputType ConsoleApplication -ErrorAction Stop
        Write-Log "  + Binaire de service compile : $exe" "Green"
        return $exe
    } catch {
        Write-Log "  ! Compilation du binaire de service echouee : $($_.Exception.Message)" "Yellow"
        return $null
    }
}

function Start-LabService {
    param([string]$Name, [string]$Account)
    try {
        Start-Service -Name $Name -ErrorAction Stop
        Write-Log "    [Running] $Name ($Account)" "Green"
    } catch {
        $inner = $_.Exception.InnerException
        $msg   = if ($inner) { $inner.Message } else { $_.Exception.Message }
        Write-Log "    [Not started] $Name ($Account) : $msg" "Yellow"
        Add-SetupStat "Services" "Warning"
    }
}

function New-WindowsServices {
    param([string]$ConfigDir, [string]$DomainNetbios, [string]$DefaultUserPass)
    Write-Log "--- Services Windows ---" "Cyan"
    $SvcConfig   = Read-Config "users_service.json" -ConfigDir $ConfigDir
    $svcAccounts = @($SvcConfig | ForEach-Object { "$DomainNetbios\$($_.SamAccountName)" }) + "$DomainNetbios\adm_dupont"
    Grant-ServiceLogonRight -Accounts $svcAccounts

    $exe = Get-LabServiceBinary
    if (-not $exe) { return }
    $bin = "`"$exe`""

    foreach ($svc in (Read-Config "services.json" -ConfigDir $ConfigDir)) {
        $acct     = "$DomainNetbios\$($svc.Account)"
        $existing = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue

        if ($existing) {
            # Ancienne version du lab : service pointant sur powershell.exe -> on le corrige
            if ($existing.PathName -match 'powershell\.exe') {
                sc.exe config $svc.Name binPath= $bin 2>$null | Out-Null
                Write-Log "  ~ $($svc.Name) : binaire PowerShell remplace par $exe" "DarkYellow"
            } else {
                Write-Log "  = $($svc.Name) (existe)" "DarkGray"
            }
            Add-SetupStat "Services" "Existing"
            if ($existing.State -ne 'Running') { Start-LabService -Name $svc.Name -Account $acct }
            continue
        }

        sc.exe create $svc.Name binPath= $bin DisplayName= $svc.DisplayName start= auto obj= $acct password= $DefaultUserPass 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ! $($svc.Name) : creation echouee (sc.exe code $LASTEXITCODE)" "Yellow"
            Add-SetupStat "Services" "Warning"
            continue
        }
        sc.exe description $svc.Name $svc.Description 2>$null | Out-Null
        Write-Log "  + $($svc.Name) ($acct)" "Green"
        Add-SetupStat "Services" "Created"
        Start-LabService -Name $svc.Name -Account $acct
    }
}

function New-ScheduledTasks {
    param([string]$ConfigDir, [string]$DomainNetbios, [string]$DefaultUserPass)
    Write-Log "--- Taches planifiees ---" "Cyan"
    $T0Config = Read-Config "users_t0.json" -ConfigDir $ConfigDir
    foreach ($task in (Read-Config "tasks.json" -ConfigDir $ConfigDir)) {
        if (Get-ScheduledTask -TaskName $task.Name -ErrorAction SilentlyContinue) {
            Write-Log "  = $($task.Name) (existe)" "DarkGray"
            Add-SetupStat "Taches planifiees" "Existing"
            continue
        }
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command Start-Sleep 10"
        $trigger = New-ScheduledTaskTrigger -Daily -At $task.TriggerTime
        $userId  = "$DomainNetbios\$($task.Account)"

        try {
            Register-ScheduledTask -TaskName $task.Name -Action $action -Trigger $trigger `
                -Description $task.Description -Force `
                -User $userId -Password $DefaultUserPass -RunLevel Highest -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "  ! $($task.Name) ($userId) : $($_.Exception.Message)" "Yellow"
            Add-SetupStat "Taches planifiees" "Warning"
            continue
        }

        $isT0  = $T0Config | Where-Object { $_.SamAccountName -eq $task.Account }
        $color = if ($isT0) { "DarkYellow" } else { "Green" }
        $flag  = if ($isT0) { " [RISQUE : compte T0]" } else { "" }
        Write-Log "  + $($task.Name) ($userId)$flag" $color
        Add-SetupStat "Taches planifiees" "Created"
    }
}

Export-ModuleMember -Function New-WindowsServices, New-ScheduledTasks
