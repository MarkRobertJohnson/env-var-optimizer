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

}
