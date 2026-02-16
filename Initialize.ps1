<#
.SYNOPSIS
Initializes local backup defaults for this clone.

.DESCRIPTION
Creates a local backup.config.json file with defaults based on the current clone
location. The generated file is intended to be machine-local and is ignored by git.

.PARAMETER ConfigPath
Optional path to the config file to create. Defaults to backup.config.json in the repo root.

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

function Get-BackupDefaultSourcePath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $repoName = Split-Path -Path $RepoRoot -Leaf
    $repoParent = Split-Path -Path $RepoRoot -Parent
    $parentName = if ([string]::IsNullOrWhiteSpace($repoParent)) { '' } else { Split-Path -Path $repoParent -Leaf }

    if ([string]::Equals($repoName, '.ctrl', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Split-Path -Path $RepoRoot -Parent)
    }

    if ([string]::Equals($parentName, '.ctrl', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Split-Path -Path $repoParent -Parent)
    }

    return $repoParent
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$defaultSourcePath = Get-BackupDefaultSourcePath -RepoRoot $scriptRoot

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
    SourcePath = $defaultSourcePath
    BackupLocation = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PCOps\Backups')
    PasswordManager = ''
    PasswordManagers = [ordered]@{
        Bitwarden = [ordered]@{
            ItemName = ''
        }
    }
    NamePattern = 'backup-{SourceName}-{Now()}'
    ExcludePattern = @('back-me-up*', '.ctrl*', 'System Volume Information*', '$RECYCLE.BIN*', '[[]no-sync[]]*')
    EncryptionEnabled = $false
}

$configJson = $config | ConvertTo-Json -Depth 5
Set-Content -LiteralPath $ConfigPath -Value $configJson -Encoding UTF8

Write-Output "Initialized backup config at '$ConfigPath'."
