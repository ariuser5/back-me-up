<#
.SYNOPSIS
Runs the backup workflow through the repository orchestrator script.

.DESCRIPTION
Wrapper script that resolves the orchestrator path, validates inputs, applies default
exclusions, and forwards parameters to the main backup script.

When run without SourcePath, this script now defaults to the parent directory of .ctrl
so backup behavior remains aligned with the previous top-level location.

.PARAMETER SourcePath
Directory to back up. Defaults to the parent directory of .ctrl.

.PARAMETER KeepLocal
Keeps the local archive after upload.

.PARAMETER ArchivePassword
Optional secure password for archive encryption. If omitted, the orchestrator acquires
the password from Bitwarden based on environment configuration.

.PARAMETER RcloneDest
Optional rclone destination override. If omitted, the script uses configured or
orchestrator defaults. Supports placeholder {SourceFolderName}.

.PARAMETER ConfigPath
Optional path to a local JSON config file. Defaults to .ctrl\backup.config.json.

.EXAMPLE
.\Create-Backup.ps1

.EXAMPLE
.\Create-Backup.ps1 -SourcePath 'D:\Data' -KeepLocal
#
.EXAMPLE
.\Create-Backup.ps1 -ConfigPath '.\backup.config.json'
#>



[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourcePath,

    [Parameter()]
    [switch]$KeepLocal,

    [Parameter()]
    [System.Security.SecureString]$ArchivePassword,

    [Parameter()]
    [string]$RcloneDest,

    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$workspaceRoot = Split-Path -Path $scriptRoot -Parent
$orchestratorPath = Join-Path -Path $scriptRoot -ChildPath 'scripts\Backup-Create.ps1'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $scriptRoot -ChildPath 'backup.config.json'
}

if (-not (Test-Path -LiteralPath $orchestratorPath -PathType Leaf)) {
    throw "Orchestrator script not found at '$orchestratorPath'."
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    try {
        $configRaw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($configRaw)) {
            $config = $configRaw | ConvertFrom-Json

            if ([string]::IsNullOrWhiteSpace($SourcePath) -and $config.PSObject.Properties.Name -contains 'SourcePath' -and -not [string]::IsNullOrWhiteSpace([string]$config.SourcePath)) {
                $SourcePath = [string]$config.SourcePath
            }

            if (-not $PSBoundParameters.ContainsKey('KeepLocal') -and $config.PSObject.Properties.Name -contains 'KeepLocal') {
                $KeepLocal = [bool]$config.KeepLocal
            }

            if ([string]::IsNullOrWhiteSpace($RcloneDest) -and $config.PSObject.Properties.Name -contains 'RcloneDest' -and -not [string]::IsNullOrWhiteSpace([string]$config.RcloneDest)) {
                $RcloneDest = [string]$config.RcloneDest
            }
        }
    }
    catch {
        throw "Unable to parse config file '$ConfigPath'. $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = $workspaceRoot
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "Source path '$SourcePath' does not exist or is not a directory."
}

$resolvedSourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
$resolvedScriptRoot = (Resolve-Path -LiteralPath $scriptRoot).Path
$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $workspaceRoot).Path
$selfScriptName = Split-Path -Path $MyInvocation.MyCommand.Path -Leaf

$wrapperDefaultExcludes = @('[[]no-sync[]]*')
if ([string]::Equals(
    $resolvedSourcePath.TrimEnd([char]'\', [char]'/'),
    $resolvedScriptRoot.TrimEnd([char]'\', [char]'/'),
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    $wrapperDefaultExcludes += @('scripts*', $selfScriptName)
}
elseif ([string]::Equals(
    $resolvedSourcePath.TrimEnd([char]'\', [char]'/'),
    $resolvedWorkspaceRoot.TrimEnd([char]'\', [char]'/'),
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    $wrapperDefaultExcludes += @('.ctrl*')
}

$effectiveExcludePatterns = @($wrapperDefaultExcludes | Select-Object -Unique)

$invokeParams = @{
    SourcePath = $SourcePath
    ExcludePattern = $effectiveExcludePatterns
    KeepLocal = [bool]$KeepLocal
    Verbose = ($VerbosePreference -ne 'SilentlyContinue')
}

if (-not [string]::IsNullOrWhiteSpace($RcloneDest)) {
    $invokeParams.RcloneDest = $RcloneDest
}

if ($PSBoundParameters.ContainsKey('ArchivePassword')) {
    $invokeParams.ArchivePassword = $ArchivePassword
}

& $orchestratorPath @invokeParams