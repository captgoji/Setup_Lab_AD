# ==============================================================================
# Shares.psm1 - Partages NTFS
# ==============================================================================

function New-NTFSShares {
    param([string]$ConfigDir, [string]$DomainNetbios)
    Write-Log "--- Partages NTFS ---" "Cyan"
    foreach ($share in (Read-Config "shares.json" -ConfigDir $ConfigDir)) {
        $null = New-Item -ItemType Directory -Force -Path $share.Path
        foreach ($sub in $share.SubFolders) {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $share.Path $sub)
        }

        $acl = Get-Acl $share.Path
        foreach ($entry in $share.ACLs) {
            $sid = Get-GroupSID -GroupName $entry.Group -DomainNetbios $DomainNetbios
            if (-not $sid) { continue }
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, $entry.Rights, "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $acl.SetAccessRule($rule)
            Write-Log "    ACL : $($entry.Group) -> $($entry.Rights)" "DarkGray"
        }
        Set-Acl -Path $share.Path -AclObject $acl

        if ($share.BrokenInheritance -and $share.BrokenInheritance.SubFolder) {
            $subPath = Join-Path $share.Path $share.BrokenInheritance.SubFolder
            if (Test-Path $subPath) {
                $subAcl = Get-Acl -LiteralPath $subPath
                $subAcl.SetAccessRuleProtection($true, $false)
                foreach ($entry in $share.BrokenInheritance.ACLs) {
                    $sid = Get-GroupSID -GroupName $entry.Group -DomainNetbios $DomainNetbios
                    if (-not $sid) { continue }
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $sid, $entry.Rights, "ContainerInherit,ObjectInherit", "None", "Allow"
                    )
                    $subAcl.AddAccessRule($rule)
                    Write-Log "      [Heritage casse] $($entry.Group) -> $($entry.Rights)" "DarkYellow"
                }
                Set-Acl -LiteralPath $subPath -AclObject $subAcl
                Write-Log "    Heritage casse sur : $subPath" "DarkYellow"
            }
        }

        if (-not (Get-SmbShare -Name $share.ShareName -ErrorAction SilentlyContinue)) {
            $domAdminsName = Get-BuiltinGroup -GroupName "Domain Admins"
            New-SmbShare -Name $share.ShareName -Path $share.Path `
                -FullAccess "$DomainNetbios\$domAdminsName" -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Log "  + $($share.ShareName) -> $($share.Path)" "Green"
    }
}

Export-ModuleMember -Function New-NTFSShares
