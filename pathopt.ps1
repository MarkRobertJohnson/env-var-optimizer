Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src/Cli.ps1')

Invoke-PathOptCli -CliArgs $args
