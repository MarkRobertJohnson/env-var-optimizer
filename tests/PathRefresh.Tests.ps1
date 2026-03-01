Import-Module (Join-Path $PSScriptRoot '../src/PathRefresh.psm1') -Force -DisableNameChecking

Describe 'PathRefresh' {
    It 'merges machine path first, then user path, and removes canonical duplicates' {
        $result = Merge-PathFromScopes -MachinePath 'C:\\Windows\\System32;C:\\Tools\\Bin' -UserPath 'C:/tools/bin;D:\\UserBin'

        $result.entries.Count | Should Be 3
        $result.entries[0] | Should Be 'C:\\Windows\\System32'
        $result.entries[1] | Should Be 'C:\\Tools\\Bin'
        $result.entries[2] | Should Be 'D:\\UserBin'
        $result.duplicatesRemoved | Should Be 1
    }

    It 'uses User value over Machine value for specific variable refresh' {
        $name = 'PATHOPT_TEST_CONFLICT'
        [Environment]::SetEnvironmentVariable($name, 'process-old', 'Process')

        try {
            $result = Invoke-EnvironmentRefresh -Scope $name -UserVariables @{ $name = 'user-value' } -MachineVariables @{ $name = 'machine-value' }

            $result.changedCount | Should Be 1
            ([Environment]::GetEnvironmentVariable($name, 'Process')) | Should Be 'user-value'
            $result.operations[0].source | Should Be 'User'
        }
        finally {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    It 'supports whatif for specific variable refresh without changing process value' {
        $name = 'PATHOPT_TEST_WHATIF'
        [Environment]::SetEnvironmentVariable($name, 'process-old', 'Process')

        try {
            $result = Invoke-EnvironmentRefresh -Scope $name -WhatIf -UserVariables @{ $name = 'user-value' } -MachineVariables @{}

            $result.whatIf | Should Be $true
            $result.changedCount | Should Be 1
            ([Environment]::GetEnvironmentVariable($name, 'Process')) | Should Be 'process-old'
        }
        finally {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    It 'reports missing variable as skipped' {
        $result = Invoke-EnvironmentRefresh -Scope 'PATHOPT_TEST_MISSING' -WhatIf -UserVariables @{} -MachineVariables @{}

        $result.changedCount | Should Be 0
        $result.skippedCount | Should Be 1
        $result.operations[0].skipped | Should Be $true
        $result.operations[0].reason | Should Be 'missing'
    }

    It 'refreshes PATH scope in current process' {
        $original = [Environment]::GetEnvironmentVariable('Path', 'Process')

        try {
            $result = Invoke-EnvironmentRefresh -Scope 'path' -UserPathValue 'D:\\UserOnly' -MachinePathValue 'C:\\Windows\\System32'

            $result.changedCount | Should Be 1
            ([Environment]::GetEnvironmentVariable('Path', 'Process')) | Should Be 'C:\\Windows\\System32;D:\\UserOnly'
            $result.operations[0].duplicatesRemoved | Should Be 0
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $original, 'Process')
        }
    }

    It 'refreshes all variables including PATH in whatif mode' {
        $name = 'PATHOPT_TEST_ALL'
        [Environment]::SetEnvironmentVariable($name, 'old', 'Process')

        try {
            $result = Invoke-EnvironmentRefresh -Scope 'all' -WhatIf -UserVariables @{ $name = 'user-value'; Path = 'D:\\U' } -MachineVariables @{ Path = 'C:\\M' } -UserPathValue 'D:\\U' -MachinePathValue 'C:\\M'

            $result.scope | Should Be 'all'
            $result.operationCount | Should BeGreaterThan 1
            $result.operations[0].variable | Should Be 'Path'
            ([Environment]::GetEnvironmentVariable($name, 'Process')) | Should Be 'old'
        }
        finally {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    It 'skips PATH refresh when machine and user sources are both empty' {
        $original = [Environment]::GetEnvironmentVariable('Path', 'Process')
        [Environment]::SetEnvironmentVariable('Path', 'C:\\KeepMe', 'Process')

        try {
            $result = Invoke-EnvironmentRefresh -Scope 'path' -UserPathValue '' -MachinePathValue ''

            $result.changedCount | Should Be 0
            $result.operations[0].skipped | Should Be $true
            $result.operations[0].reason | Should Be 'empty_source_path'
            ([Environment]::GetEnvironmentVariable('Path', 'Process')) | Should Be 'C:\\KeepMe'
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $original, 'Process')
        }
    }

    It 'does not treat null path parameters as explicit empty values' {
        $original = [Environment]::GetEnvironmentVariable('Path', 'Process')
        [Environment]::SetEnvironmentVariable('Path', 'C:\\KeepMe', 'Process')

        try {
            $result = Invoke-PathRefresh -UserPathValue $null -MachinePathValue 'C:\\MachinePath' -WhatIf
            $result.skipped | Should Not Be $true
            $result.machineEntryCount | Should Be 1
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $original, 'Process')
        }
    }

    It 'returns warning payload when refresh appears to run in child shell process' {
        $warnings = @(Get-RefreshExecutionWarnings -ExecutionContext ([pscustomobject]@{
            currentProcessId   = 1234
            currentProcessName = 'pwsh'
            parentProcessId    = 2222
            parentProcessName  = 'cmd'
        }))

        $warnings.Count | Should Be 1
        $warnings[0].code | Should Be 'child_shell_process'
        $warnings[0].message.Contains('child process 1234 (pwsh)') | Should Be $true
        $warnings[0].message.Contains('interactive parent process 2222 (cmd)') | Should Be $true
        $warnings[0].message.Contains('pathopt.ps1') | Should Be $true
        $warnings[0].commandPath.EndsWith('pathopt.ps1') | Should Be $true
    }

    It 'throws when execution context indicates child shell process' {
        $context = [pscustomobject]@{
            currentProcessId   = 1234
            currentProcessName = 'pwsh'
            parentProcessId    = 2222
            parentProcessName  = 'cmd'
        }

        $didThrow = $false
        try {
            Invoke-EnvironmentRefresh -Scope 'path' -WhatIf -RefreshExecutionContext $context -UserPathValue 'D:\\U' -MachinePathValue 'C:\\M' | Out-Null
        }
        catch {
            $didThrow = $true
            $_.Exception.Message.Contains('child process 1234 (pwsh)') | Should Be $true
            $_.Exception.Message.Contains('interactive parent process 2222 (cmd)') | Should Be $true
            $_.Exception.Message.Contains('pathopt.ps1') | Should Be $true
        }

        $didThrow | Should Be $true
    }

    It 'does not warn when parent is non-shell process' {
        $warnings = @(Get-RefreshExecutionWarnings -ExecutionContext ([pscustomobject]@{
            currentProcessId   = 1234
            currentProcessName = 'pwsh'
            parentProcessId    = 4444
            parentProcessName  = 'Code'
        }))

        $warnings.Count | Should Be 0
    }
}
