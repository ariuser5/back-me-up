[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SourcePath = (Get-Location).Path,

    [Parameter()]
    [string[]]$ExcludePattern,

    [Parameter()]
    [switch]$KeepLocal,

    [Parameter()]
    [System.Security.SecureString]$ArchivePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$coreDir = Join-Path -Path $scriptDir -ChildPath '.\core'

$bitwardenScriptPath = Join-Path -Path $coreDir -ChildPath 'Bitwarden-Session.ps1'
$archiveScriptPath = Join-Path -Path $coreDir -ChildPath 'Archive-Local.ps1'
$uploadScriptPath = Join-Path -Path $coreDir -ChildPath 'Upload-GDrive.ps1'
$commonScriptPath = Join-Path -Path $coreDir -ChildPath 'Common.ps1'

foreach ($path in @($bitwardenScriptPath, $archiveScriptPath, $uploadScriptPath, $commonScriptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required core script not found at '$path'."
    }
}

. $commonScriptPath

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "Source path '$SourcePath' does not exist or is not a directory."
}

$predefinedRcloneDest = 'gdrive:Backups/Security-SD-Card'
$bwItemName = [string]$env:BACKUP_BW_ITEM_NAME
$bwItemId = [string]$env:BACKUP_BW_ITEM_ID

$resolvedSourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
$sourceRoot = [System.IO.Path]::GetPathRoot($resolvedSourcePath)
$isRootSource = [string]::Equals(
    $resolvedSourcePath.TrimEnd([char]'\', [char]'/'),
    $sourceRoot.TrimEnd([char]'\', [char]'/'),
    [System.StringComparison]::OrdinalIgnoreCase
)

$defaultExcludePatterns = @('[[]no-sync[]]*')
if ($isRootSource) {
    $defaultExcludePatterns += @('System Volume Information*', '$RECYCLE.BIN*')
}

$callerExcludePatterns = @($ExcludePattern | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$effectiveExcludePatterns = @($defaultExcludePatterns + $callerExcludePatterns | Select-Object -Unique)

$safeSourceName = Get-BackupSafeFolderName -Path $SourcePath
$archivePrefix = "backup-$safeSourceName"
$cleanupStateJson = $null
$effectiveArchivePassword = $null

try {
    Write-BackupDebug -Message 'Orchestration started.'

    $verboseEnabled = $VerbosePreference -ne 'SilentlyContinue'

    $useProvidedPassword = $PSBoundParameters.ContainsKey('ArchivePassword')
    if ($useProvidedPassword) {
        Write-BackupDebug -Message 'Using provided archive password; skipping Bitwarden acquire/cleanup.'
        $effectiveArchivePassword = $ArchivePassword
    }
    else {
        if ([string]::IsNullOrWhiteSpace($bwItemName) -and [string]::IsNullOrWhiteSpace($bwItemId)) {
            throw "Bitwarden item selector is not configured. Set environment variable BACKUP_BW_ITEM_ID or BACKUP_BW_ITEM_NAME, or pass -ArchivePassword."
        }

        $bwAcquire = & $bitwardenScriptPath -Action Acquire -BwItemName $bwItemName -BwItemId $bwItemId -Verbose:$verboseEnabled | Select-Object -Last 1

        if ($null -eq $bwAcquire -or [string]::IsNullOrWhiteSpace([string]$bwAcquire.Password)) {
            throw 'Bitwarden password acquisition did not return a password.'
        }

        $effectiveArchivePassword = ConvertTo-SecureString -String ([string]$bwAcquire.Password) -AsPlainText -Force
        $cleanupStateJson = [string]$bwAcquire.CleanupStateJson
    }

    if ($null -eq $effectiveArchivePassword) {
        throw 'Archive password is null before archive creation.'
    }

    $archivePath = (& $archiveScriptPath `
        -SourcePath $SourcePath `
        -OutputRoot (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PCOps\Backups') `
        -ArchivePrefix $archivePrefix `
        -CompressionLevel 9 `
        -ExcludePattern $effectiveExcludePatterns `
        -ArchivePassword $effectiveArchivePassword `
        -Verbose:$verboseEnabled | Select-Object -Last 1)

    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        throw 'Archive script did not return an archive path.'
    }

    & $uploadScriptPath -ArchivePath $archivePath -RcloneDest $predefinedRcloneDest -KeepLocal:$KeepLocal -Verbose:$verboseEnabled | Out-Null
    Write-BackupLog -Level INFO -Message 'Backup completed successfully.'
}
catch {
    Write-BackupLog -Level ERROR -Message $_.Exception.Message
    throw
}
finally {
    $effectiveArchivePassword = $null

    if (-not [string]::IsNullOrWhiteSpace($cleanupStateJson)) {
        $verboseEnabled = $VerbosePreference -ne 'SilentlyContinue'
        & $bitwardenScriptPath -Action Cleanup -CleanupStateJson $cleanupStateJson -Verbose:$verboseEnabled
    }
}