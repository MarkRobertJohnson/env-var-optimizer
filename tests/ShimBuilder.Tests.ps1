Import-Module (Join-Path $PSScriptRoot '../src/ShimBuilder.psm1') -Force -DisableNameChecking

Describe 'ShimBuilder' {
    It 'auto-generates a shim name for a single explicit target when name is omitted' {
        $root = Join-Path $env:TEMP ('pathopt-shim-single-autoname-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'
        $targetPath = Join-Path $root 'tools\kdenlive.exe'

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        'stub' | Set-Content -Path $targetPath -Encoding ASCII

        @"
{
  "version": 1,
  "shims": [
    {
      "target": "$($targetPath.Replace('\', '\\'))",
      "launcherType": "cmd"
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        $result = Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir

        $result.shimCount | Should Be 1
        $result.launchers[0].name | Should Be 'kdenlive'
        (Test-Path -LiteralPath (Join-Path $binDir 'kdenlive.cmd')) | Should Be $true

        Remove-Item -Recurse -Force -Path $root
    }

    It 'expands wildcard targets into one shim per matched file' {
        $root = Join-Path $env:TEMP ('pathopt-shim-wildcard-' + [guid]::NewGuid().ToString('N'))
        $toolsDir = Join-Path $root 'tools'
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
        '@echo off' | Set-Content -Path (Join-Path $toolsDir 'alpha.bat') -Encoding ASCII
        '@echo off' | Set-Content -Path (Join-Path $toolsDir 'beta.bat') -Encoding ASCII
        '@echo off' | Set-Content -Path (Join-Path $toolsDir 'ignore.cmd') -Encoding ASCII

        @"
{
  "version": 1,
  "shims": [
    {
      "target": "tools\\*.bat",
      "launcherType": "cmd"
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        $result = Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir

        $result.shimCount | Should Be 2
        (Test-Path -LiteralPath (Join-Path $binDir 'alpha.cmd')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $binDir 'beta.cmd')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $binDir 'ignore.cmd')) | Should Be $false

        Remove-Item -Recurse -Force -Path $root
    }

    It 'creates cmd and ps1 launchers from manifest' {
        $root = Join-Path $env:TEMP ('pathopt-shim-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "foo",
      "target": "C:\\Windows\\System32\\where.exe",
      "launcherType": "cmd"
    },
    {
      "name": "bar",
      "target": "C:\\Tools\\bar\\run.ps1",
      "launcherType": "cmd+ps1"
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        $result = Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir

        $result.shimCount | Should Be 2
        (Test-Path -LiteralPath (Join-Path $binDir 'foo.cmd')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $binDir 'bar.cmd')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $binDir 'bar.ps1')) | Should Be $true

        Remove-Item -Recurse -Force -Path $root
    }

    It 'throws on duplicate names without priority map' {
        $root = Join-Path $env:TEMP ('pathopt-shim-dup-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    { "name": "tool", "target": "C:\\A\\tool.exe" },
    { "name": "tool", "target": "C:\\B\\tool.exe" }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        $didThrow = $false
        try {
            Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir | Out-Null
        }
        catch {
            $didThrow = $true
        }

        $didThrow | Should Be $true

        Remove-Item -Recurse -Force -Path $root
    }

    It 'generates wrappers with locked positional and overridable defaults' {
        $root = Join-Path $env:TEMP ('pathopt-shim-args-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "envrefresh",
      "target": "C:\\dev\\env-var-optimizer\\pathopt.ps1",
      "launcherType": "cmd+ps1",
      "args": {
        "lockedPositional": ["refresh"],
        "defaults": {
          "--scope": "path"
        }
      }
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir | Out-Null

        $cmdPath = Join-Path $binDir 'envrefresh.cmd'
        $ps1Path = Join-Path $binDir 'envrefresh.ps1'

        (Test-Path -LiteralPath $cmdPath) | Should Be $true
        (Test-Path -LiteralPath $ps1Path) | Should Be $true

        $cmdContent = Get-Content -LiteralPath $cmdPath -Raw
        $cmdContent.Contains('envrefresh.ps1') | Should Be $true

        $ps1Content = Get-Content -LiteralPath $ps1Path -Raw
        $ps1Content.Contains('lockedPositional') | Should Be $true
        $ps1Content.Contains('refresh') | Should Be $true
        $ps1Content.Contains('--scope') | Should Be $true
        $ps1Content.Contains('Positional overrides are not allowed') | Should Be $true

        Remove-Item -Recurse -Force -Path $root
    }

    It 'rejects args policy when launcherType is cmd' {
        $root = Join-Path $env:TEMP ('pathopt-shim-args-cmd-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "envrefresh",
      "target": "C:\\dev\\env-var-optimizer\\pathopt.ps1",
      "launcherType": "cmd",
      "args": {
        "lockedPositional": ["refresh"],
        "defaults": {
          "--scope": "path"
        }
      }
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        $didThrow = $false
        try {
            Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir | Out-Null
        }
        catch {
            $didThrow = $true
          $_.Exception.Message.Contains("must set launcherType to 'ps1' or 'cmd+ps1'") | Should Be $true
        }

        $didThrow | Should Be $true

        Remove-Item -Recurse -Force -Path $root
    }

    It 'supports args policy with ps1 launcher only' {
        $root = Join-Path $env:TEMP ('pathopt-shim-args-ps1-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "envrefresh",
      "target": "C:\\dev\\env-var-optimizer\\pathopt.ps1",
      "launcherType": "ps1",
      "args": {
        "lockedPositional": ["refresh"],
        "defaults": {
          "--scope": "path"
        }
      }
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        $result = Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir

        (Test-Path -LiteralPath (Join-Path $binDir 'envrefresh.cmd')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $binDir 'envrefresh.ps1')) | Should Be $true
        $result.launchers.Count | Should Be 1
        $result.launchers[0].launcherType | Should Be 'ps1'

        Remove-Item -Recurse -Force -Path $root
    }

    It 'marks existing launchers as unchanged when content is identical' {
        $root = Join-Path $env:TEMP ('pathopt-shim-unchanged-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "envrefresh",
      "target": "C:\\dev\\env-var-optimizer\\pathopt.ps1",
      "launcherType": "cmd+ps1",
      "args": {
        "lockedPositional": ["refresh"],
        "defaults": {
          "--scope": "path"
        }
      }
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir | Out-Null
        $secondRun = Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir

        @($secondRun.launchers | Where-Object { $_.action -eq 'unchanged' }).Count | Should Be 2

        Remove-Item -Recurse -Force -Path $root
    }

    It 'supports locked command tokens with additional positional tail when enabled' {
        $root = Join-Path $env:TEMP ('pathopt-shim-tail-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "pathadd",
      "target": "C:\\dev\\env-var-optimizer\\pathopt.ps1",
      "launcherType": "cmd+ps1",
      "args": {
        "lockedPositional": ["add"],
        "allowPositionalTail": true
      }
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir | Out-Null

        $ps1Path = Join-Path $binDir 'pathadd.ps1'
        $ps1Content = Get-Content -LiteralPath $ps1Path -Raw
        $ps1Content.Contains('allowPositionalTail') | Should Be $true
        $ps1Content.Contains('Positional overrides are not allowed') | Should Be $true

        Remove-Item -Recurse -Force -Path $root
    }

    It 'removes previously managed launchers that are no longer in manifest during install' {
        $root = Join-Path $env:TEMP ('pathopt-shim-install-' + [guid]::NewGuid().ToString('N'))
        $manifestV1 = Join-Path $root 'manifest-v1.json'
        $manifestV2 = Join-Path $root 'manifest-v2.json'
        $statePath = Join-Path $root 'state.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "oldshim",
      "target": "C:\\Windows\\System32\\where.exe",
      "launcherType": "cmd"
    }
  ]
}
"@ | Set-Content -Path $manifestV1 -Encoding ASCII

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "newshim",
      "target": "C:\\Windows\\System32\\where.exe",
      "launcherType": "cmd"
    }
  ]
}
"@ | Set-Content -Path $manifestV2 -Encoding ASCII

        Install-PathShims -ManifestPath $manifestV1 -BinDir $binDir -StatePath $statePath | Out-Null
        $result = Install-PathShims -ManifestPath $manifestV2 -BinDir $binDir -StatePath $statePath

        (Test-Path -LiteralPath (Join-Path $binDir 'oldshim.cmd')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $binDir 'newshim.cmd')) | Should Be $true
        @($result.removedLaunchers | Where-Object { $_.action -eq 'removed' }).Count | Should Be 1

        Remove-Item -Recurse -Force -Path $root
    }

    It 'allows invocation with no user args' {
        $root = Join-Path $env:TEMP ('pathopt-shim-noargs-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $root 'manifest.json'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $root | Out-Null

        @"
{
  "version": 1,
  "shims": [
    {
      "name": "envrefresh",
      "target": "C:\\Windows\\System32\\where.exe",
      "launcherType": "cmd+ps1",
      "args": {
        "lockedPositional": ["where"]
      }
    }
  ]
}
"@ | Set-Content -Path $manifestPath -Encoding ASCII

        Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir | Out-Null

        $ps1Path = Join-Path $binDir 'envrefresh.ps1'
        $didThrow = $false
        try {
            & $ps1Path | Out-Null
        }
        catch {
            $didThrow = $true
            $_.Exception.Message.Contains('Cannot bind argument to parameter') | Should Be $false
        }

        $didThrow | Should Be $false

        Remove-Item -Recurse -Force -Path $root
    }
}
