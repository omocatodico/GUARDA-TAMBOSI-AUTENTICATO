[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root 'tools\StopAllLauncher.cs'
$output = Join-Path $root 'stop-all-admin.exe'

if (-not (Test-Path -Path $source)) {
    throw "Sorgente non trovato: $source"
}

$code = Get-Content -Path $source -Raw
Add-Type -TypeDefinition $code -Language CSharp -OutputAssembly $output -OutputType ConsoleApplication

Write-Output "Creato: $output"
