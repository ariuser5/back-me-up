<#
.SYNOPSIS
Initializes local backup defaults for this clone.

.DESCRIPTION
Creates a local backup.config.json file with defaults based on the current clone
location. The generated file is intended to be machine-local and is ignored by git.

.PARAMETER ConfigPath
Optional path to the config file to create. Defaults to .ctrl\backup.config.json.

.PARAMETER Force
Overwrites an existing config file without prompting.

.EXAMPLE
.\Initialize.ps1

.EXAMPLE
.\Initialize.ps1 -Force
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$workspaceRoot = Split-Path -Path $scriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $scriptRoot -ChildPath 'backup.config.json'
}

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    if (-not $Force) {
        try {
            $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
                (New-Object System.Management.Automation.Host.ChoiceDescription '&No', 'Keep the existing configuration and cancel initialization.'),
                (New-Object System.Management.Automation.Host.ChoiceDescription '&Yes', 'Reinitialize and overwrite the existing configuration.')
            )

            $selection = $Host.UI.PromptForChoice(
                'Reinitialize backup location',
                "Config file already exists at '$ConfigPath'. Do you want to overwrite it?",
                $choices,
                0
            )

            if ($selection -ne 1) {
                Write-Output 'Initialization canceled. Existing config was not changed.'
                return
            }
        }
        catch {
            throw "Config file already exists at '$ConfigPath'. Re-run with -Force to overwrite in non-interactive contexts."
        }
    }
}

$configDir = Split-Path -Path $ConfigPath -Parent
if (-not [string]::IsNullOrWhiteSpace($configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

$config = [ordered]@{
    SourcePath = $workspaceRoot
    BackupLocation = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PCOps\Backups')
    ExcludePattern = @('[[]no-sync[]]*', 'back-me-up*', '.ctrl*', 'System Volume Information*', '$RECYCLE.BIN*')
    EncryptionEnabled = $false
}

$configJson = $config | ConvertTo-Json -Depth 5
Set-Content -LiteralPath $ConfigPath -Value $configJson -Encoding UTF8

Write-Output "Initialized backup config at '$ConfigPath'."
