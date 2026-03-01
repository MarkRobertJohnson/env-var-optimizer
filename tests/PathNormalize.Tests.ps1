Import-Module (Join-Path $PSScriptRoot '../src/PathNormalize.psm1') -Force -DisableNameChecking

Describe 'PathNormalize' {
    It 'treats case and trailing slash as equivalent canonical keys' {
        $a = Get-CanonicalPathKey -Path 'C:\\Program Files\\Nodejs\\'
        $b = Get-CanonicalPathKey -Path 'c:/program files/nodejs'

        $a | Should Be $b
    }

    It 'splits and joins PATH values' {
        $parts = Split-PathVariableValue -Value 'C:\\A;C:\\B;;C:\\C'
        $parts.Count | Should Be 4

        $joined = Join-PathVariableValue -Entries $parts
        $joined | Should Be 'C:\\A;C:\\B;C:\\C'
    }

    It 'compresses with environment variable substitutions when shorter' {
        $compressed = ConvertTo-CompressedPathEntry -Path (Join-Path $env:LOCALAPPDATA 'Programs')
        $compressed.Length | Should BeLessThan (Join-Path $env:LOCALAPPDATA 'Programs').Length
    }
}
