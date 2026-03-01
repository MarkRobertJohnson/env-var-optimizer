Import-Module (Join-Path $PSScriptRoot '../src/PathPlan.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../src/PathNormalize.psm1') -Force -DisableNameChecking

Describe 'PathPlan' {
    It 'deduplicates and consolidates shared paths to machine scope' {
        $root = Join-Path $env:TEMP ('pathopt-test-' + [guid]::NewGuid().ToString('N'))
        $m1 = Join-Path $root 'machineA'
        $m2 = Join-Path $root 'machineB'
        $u1 = Join-Path $root 'userA'

        New-Item -ItemType Directory -Force -Path $m1, $m2, $u1 | Out-Null

        $machine = @($m1, $m2)
        $user = @($m1.ToUpperInvariant(), $u1)

        $plan = New-PathOptimizationPlan -UserEntries $user -MachineEntries $machine -Scope both -ScopePolicy SharedToMachine

        $machineKeys = @($plan.proposedMachineEntries | ForEach-Object { Get-CanonicalPathKey -Path $_ })
        $userKeys = @($plan.proposedUserEntries | ForEach-Object { Get-CanonicalPathKey -Path $_ })
        $m1Key = Get-CanonicalPathKey -Path $m1

        ($machineKeys | Where-Object { $_ -eq $m1Key }).Count | Should Be 1
        ($userKeys | Where-Object { $_ -eq $m1Key }).Count | Should Be 0

        Remove-Item -Recurse -Force -Path $root
    }

    It 'quarantines missing entries' {
        $missing = Join-Path $env:TEMP ('pathopt-missing-' + [guid]::NewGuid().ToString('N'))
        $plan = New-PathOptimizationPlan -UserEntries @($missing) -MachineEntries @() -Scope both -ScopePolicy SharedToMachine

        $plan.quarantine.Count | Should Be 1
        $plan.entries[0].status | Should Be 'remove_missing'
    }

    It 'is deterministic for the same input' {
        $root = Join-Path $env:TEMP ('pathopt-stable-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null

        $machine = @($root)
        $user = @($root)

        $plan1 = New-PathOptimizationPlan -UserEntries $user -MachineEntries $machine -Scope both -ScopePolicy SharedToMachine
        Start-Sleep -Milliseconds 50
        $plan2 = New-PathOptimizationPlan -UserEntries $user -MachineEntries $machine -Scope both -ScopePolicy SharedToMachine

        $plan1.planHash | Should Be $plan2.planHash

        Remove-Item -Recurse -Force -Path $root
    }
}
