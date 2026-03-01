Import-Module (Join-Path $PSScriptRoot '../src/ShimBuilder.psm1') -Force -DisableNameChecking

Describe 'ShimBuilder' {
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
}
