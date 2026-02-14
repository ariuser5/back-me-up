<#
.SYNOPSIS
Runs the local backup workflow.

.DESCRIPTION
Main entrypoint for creating a local backup archive. By default it runs interactively,
showing values loaded from config and allowing confirmation or edits before execution.

Use -NonInteractive for unattended execution. Add -Strict to require explicit values
for imposed parameters rather than falling back to config/defaults.

.PARAMETER SourcePath
Path to the folder/drive that will be archived.

.PARAMETER BackupLocation
Local output root where archives are written.

.PARAMETER ExcludePattern
Wildcard patterns excluded from the archive.

.PARAMETER Encrypt
Enables archive encryption.

.PARAMETER ArchivePassword
SecureString password used when -Encrypt is enabled.

.PARAMETER NonInteractive
Skips prompts and resolves values from explicit params, config, and defaults.

.PARAMETER Strict
Only valid with -NonInteractive. Requires explicit values for SourcePath,
BackupLocation, ExcludePattern, and Encrypt.

.PARAMETER ConfigPath
Path to config JSON. Defaults to backup.config.json in the repo root.

.EXAMPLE
.\Run.ps1

.EXAMPLE
.\Run.ps1 -NonInteractive

.EXAMPLE
$pw = Read-Host "Archive password" -AsSecureString
.\Run.ps1 -NonInteractive -Strict -SourcePath "S:\" -BackupLocation "D:\Backups" -ExcludePattern "[[]no-sync[]]*" -Encrypt -ArchivePassword $pw
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourcePath,

    [Parameter()]
    [string]$BackupLocation,

    [Parameter()]
    [string[]]$ExcludePattern,

    [Parameter()]
    [switch]$Encrypt,

    [Parameter()]
    [System.Security.SecureString]$ArchivePassword,

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [switch]$Strict,

    [Parameter()]
    [string]$ConfigPath
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

function Test-ConfigProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name)
}

function Get-ConfigStringArray {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-ConfigProperty -Config $Config -Name $Name)) {
        return @()
    }

    $values = @($Config.$Name)
    return @($values | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Read-ResolvedTextValue {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$CurrentValue
    )

    $inputValue = Read-Host "$Label [$CurrentValue]"
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return $CurrentValue
    }

    return $inputValue
}

function Read-ResolvedExcludePattern {
    param([string[]]$CurrentPatterns)

    $currentText = @($CurrentPatterns) -join ';'
    $prompt = 'ExcludePattern (semicolon-separated, enter - for none)'
    $inputValue = Read-Host "$prompt [$currentText]"

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return @($CurrentPatterns)
    }

    if ($inputValue -eq '-') {
        return @()
    }

    return @($inputValue.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Read-ResolvedEncryptionChoice {
    param([bool]$CurrentValue)

    $defaultMarker = if ($CurrentValue) { 'Y' } else { 'N' }
    $inputValue = Read-Host "Encrypt archive? (Y/N) [$defaultMarker]"

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return $CurrentValue
    }

    $normalized = $inputValue.Trim().ToUpperInvariant()
    if ($normalized -in @('Y', 'YES')) {
        return $true
    }

    if ($normalized -in @('N', 'NO')) {
        return $false
    }

    throw "Invalid encryption choice '$inputValue'. Enter Y or N."
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)

    $ptr = [System.IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [System.IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Read-ArchivePasswordFromPrompt {
    $first = Read-Host 'Archive password' -AsSecureString
    $second = Read-Host 'Confirm archive password' -AsSecureString

    $firstPlain = Convert-SecureStringToPlainText -Secure $first
    $secondPlain = Convert-SecureStringToPlainText -Secure $second

    if ([string]::IsNullOrWhiteSpace($firstPlain)) {
        throw 'Archive password cannot be empty when encryption is enabled.'
    }

    if (-not [string]::Equals($firstPlain, $secondPlain, [System.StringComparison]::Ordinal)) {
        throw 'Archive password confirmation does not match.'
    }

    $firstPlain = $null
    $secondPlain = $null
    return $first
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$defaultSourceRoot = Get-BackupDefaultSourcePath -RepoRoot $scriptRoot
$scriptsDir = Join-Path -Path $scriptRoot -ChildPath 'scripts'
$commonScriptPath = Join-Path -Path $scriptsDir -ChildPath 'Common.ps1'
$archiveScriptPath = Join-Path -Path $scriptsDir -ChildPath 'Archive-Local.ps1'

foreach ($required in @($commonScriptPath, $archiveScriptPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required script not found at '$required'."
    }
}

. $commonScriptPath

if ($Strict -and -not $NonInteractive) {
    throw '-Strict can only be used together with -NonInteractive.'
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $scriptRoot -ChildPath 'backup.config.json'
}

$config = $null
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $configRaw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($configRaw)) {
            $config = $configRaw | ConvertFrom-Json
        }
    }
    catch {
        throw "Unable to parse config file '$ConfigPath'. $($_.Exception.Message)"
    }
}

$defaultSourcePath = $defaultSourceRoot
$defaultBackupLocation = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PCOps\Backups'
$defaultExcludePattern = @('[[]no-sync[]]*', '.ctrl*')

$sourceFromConfig = if (Test-ConfigProperty -Config $config -Name 'SourcePath') { [string]$config.SourcePath } else { $null }
$backupLocationFromConfig = if (Test-ConfigProperty -Config $config -Name 'BackupLocation') { [string]$config.BackupLocation } else { $null }
$excludeFromConfig = Get-ConfigStringArray -Config $config -Name 'ExcludePattern'

$encryptFromConfig = $false
$encryptConfigSpecified = $false
if (Test-ConfigProperty -Config $config -Name 'EncryptionEnabled') {
    $encryptFromConfig = [bool]$config.EncryptionEnabled
    $encryptConfigSpecified = $true
}

$encryptSpecified = $PSBoundParameters.ContainsKey('Encrypt')
$passwordSpecified = $PSBoundParameters.ContainsKey('ArchivePassword')
if ($passwordSpecified -and -not $encryptSpecified) {
    $Encrypt = $true
    $encryptSpecified = $true
}

if ($Strict) {
    foreach ($requiredParam in @('SourcePath', 'BackupLocation', 'ExcludePattern', 'Encrypt')) {
        if (-not $PSBoundParameters.ContainsKey($requiredParam)) {
            throw "Missing required parameter '$requiredParam' in -Strict mode."
        }
    }
}

if ($Strict) {
    $resolvedSourcePath = $SourcePath
    $resolvedBackupLocation = $BackupLocation
    $resolvedExcludePattern = @($ExcludePattern)
    $useEncryption = [bool]$Encrypt
}
else {
    $resolvedSourcePath = if ($PSBoundParameters.ContainsKey('SourcePath')) { $SourcePath } elseif (-not [string]::IsNullOrWhiteSpace($sourceFromConfig)) { $sourceFromConfig } else { $defaultSourcePath }
    $resolvedBackupLocation = if ($PSBoundParameters.ContainsKey('BackupLocation')) { $BackupLocation } elseif (-not [string]::IsNullOrWhiteSpace($backupLocationFromConfig)) { $backupLocationFromConfig } else { $defaultBackupLocation }
    $resolvedExcludePattern = if ($PSBoundParameters.ContainsKey('ExcludePattern')) { @($ExcludePattern) } elseif ($excludeFromConfig.Count -gt 0) { @($excludeFromConfig) } else { @($defaultExcludePattern) }
    $useEncryption = if ($encryptSpecified) { [bool]$Encrypt } elseif ($encryptConfigSpecified) { $encryptFromConfig } else { $false }
}

if (-not $NonInteractive) {
    $resolvedSourcePath = Read-ResolvedTextValue -Label 'SourcePath' -CurrentValue $resolvedSourcePath
    $resolvedBackupLocation = Read-ResolvedTextValue -Label 'BackupLocation' -CurrentValue $resolvedBackupLocation
    $resolvedExcludePattern = Read-ResolvedExcludePattern -CurrentPatterns $resolvedExcludePattern
    $useEncryption = Read-ResolvedEncryptionChoice -CurrentValue $useEncryption
}

if ([string]::IsNullOrWhiteSpace($resolvedSourcePath)) {
    throw 'SourcePath resolved to an empty value.'
}

if ([string]::IsNullOrWhiteSpace($resolvedBackupLocation)) {
    throw 'BackupLocation resolved to an empty value.'
}

if (-not (Test-Path -LiteralPath $resolvedSourcePath -PathType Container)) {
    throw "Source path '$resolvedSourcePath' does not exist or is not a directory."
}

New-Item -ItemType Directory -Path $resolvedBackupLocation -Force | Out-Null

if ($useEncryption -and -not $passwordSpecified) {
    if ($NonInteractive) {
        throw 'Encryption is enabled but ArchivePassword was not provided in -NonInteractive mode.'
    }

    $ArchivePassword = Read-ArchivePasswordFromPrompt
    $passwordSpecified = $true
}

if (-not $useEncryption -and $passwordSpecified) {
    throw 'ArchivePassword was provided but -Encrypt is not enabled.'
}

$safeSourceName = Get-BackupSafeFolderName -Path $resolvedSourcePath
$archivePrefix = "backup-$safeSourceName"

$archiveParams = @{
    SourcePath = $resolvedSourcePath
    OutputRoot = $resolvedBackupLocation
    ArchivePrefix = $archivePrefix
    CompressionLevel = 9
    ExcludePattern = @($resolvedExcludePattern)
    Verbose = ($VerbosePreference -ne 'SilentlyContinue')
}

if ($useEncryption) {
    $archiveParams.ArchivePassword = $ArchivePassword
}

$archivePath = (& $archiveScriptPath @archiveParams | Select-Object -Last 1)
if ([string]::IsNullOrWhiteSpace($archivePath)) {
    throw 'Archive script did not return an archive path.'
}

Write-BackupLog -Level INFO -Message "Backup completed. Archive created at '$archivePath'."
Write-Output $archivePath
