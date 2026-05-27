Import-Module (Join-Path $PSScriptRoot '../src/PathApply.psm1') -Force -DisableNameChecking

Describe 'PathApply' {
    It 'creates a post-apply snapshot after successful writes' {
        $root = Join-Path $env:TEMP ('pathopt-apply-' + [guid]::NewGuid().ToString('N'))
        $planPath = Join-Path $root 'plan.json'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        '{}' | Set-Content -Path $planPath -Encoding UTF8

        try {
            Mock -ModuleName PathApply Read-PlanFile {
                [pscustomobject]@{
                    proposedUserPath = 'C:\Users\Me\Bin;D:\UserTools'
                    proposedMachinePath = 'C:\Windows\System32;C:\Tools\Bin'
                    planHash = 'plan-hash'
                }
            }

            Mock -ModuleName PathApply Get-PathValue {
                param([string]$Scope)

                switch ($Scope) {
                    'User' { 'C:\Users\Me\Bin' }
                    'Machine' { 'C:\Windows\System32' }
                    default { '' }
                }
            }

            Mock -ModuleName PathApply Test-IsAdministrator { $true }
            Mock -ModuleName PathApply Set-PathValue { }

            $result = Invoke-PathPlanApply -PlanPath $planPath -BackupDir $root
            $snapshots = @(Get-ChildItem -LiteralPath $root -Filter 'path-snapshot-*.json' | Sort-Object Name)

            $snapshots.Count | Should Be 2
            (Test-Path -LiteralPath $result.snapshotPath -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath $result.postApplySnapshotPath -PathType Leaf) | Should Be $true
            $result.snapshotPath | Should Not Be $result.postApplySnapshotPath
        }
        finally {
            Remove-Item -Recurse -Force -Path $root
        }
    }

    It 'retains entries added since the snapshot in their current scopes during rollback' {
        $root = Join-Path $env:TEMP ('pathopt-rollback-' + [guid]::NewGuid().ToString('N'))
        $snapshotPath = Join-Path $root 'snapshot.json'
        $global:PathOptRollbackWrites = @()

        New-Item -ItemType Directory -Force -Path $root | Out-Null
        @{
            version = 1
            generatedAt = '2026-05-27T00:00:00.0000000Z'
            userPath = 'C:\Users\Me\Bin;D:\UserTools'
            machinePath = 'C:\Windows\System32'
            processPath = 'C:\Windows\System32;C:\Users\Me\Bin;D:\UserTools'
        } | ConvertTo-Json | Set-Content -Path $snapshotPath -Encoding UTF8

        try {
            Mock -ModuleName PathApply Test-IsAdministrator { $true }
            Mock -ModuleName PathApply Get-PathValue {
                param([string]$Scope)

                switch ($Scope) {
                    'User' { 'C:\Users\Me\Bin;D:\UserTools;E:\NewUserTool' }
                    'Machine' { 'C:\Windows\System32;C:\NewMachineTool' }
                    default { '' }
                }
            }

            Mock -ModuleName PathApply Get-PathLengthWarnings { @() }
            Mock -ModuleName PathApply Set-PathValue {
                param([string]$Scope, [string]$Value, [switch]$WhatIf)

                $global:PathOptRollbackWrites += [pscustomobject]@{
                    Scope = $Scope
                    Value = $Value
                    WhatIf = [bool]$WhatIf
                }
            }

            $result = Invoke-PathRollback -SnapshotPath $snapshotPath

            $global:PathOptRollbackWrites.Count | Should Be 2
            (@($global:PathOptRollbackWrites | Where-Object Scope -eq 'User'))[0].Value | Should Be 'C:\Users\Me\Bin;D:\UserTools;E:\NewUserTool'
            (@($global:PathOptRollbackWrites | Where-Object Scope -eq 'Machine'))[0].Value | Should Be 'C:\Windows\System32;C:\NewMachineTool'
            $result.retainedEntryCount | Should Be 2
            $result.retainedUserEntryCount | Should Be 1
            $result.retainedMachineEntryCount | Should Be 1
            $result.exact | Should Be $false
        }
        finally {
            Remove-Variable -Name PathOptRollbackWrites -Scope Global -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force -Path $root
        }
    }
}