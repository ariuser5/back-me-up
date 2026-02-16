<#
.SYNOPSIS
Runs the local backup workflow.

.DESCRIPTION
Main entrypoint for creating a local backup archive. By default it runs interactively,
showing values loaded from config and allowing confirmation or edits before execution.

Use -NonInteractive for unattended execution.

.PARAMETER SourcePath
Path to the folder/drive that will be archived.

.PARAMETER BackupLocation
Backup destination root. Supports local paths (for example C:\Backups) and
rclone remotes (for example gdrive:Documents/some/path).

.PARAMETER DestinationName
Optional nested folder name under BackupLocation.
When omitted, defaults to the source folder name.
When provided as empty or whitespace, no nested folder is used.

.PARAMETER NamePattern
Expression used to build output archive file name.
Supports placeholders: {DestinationName}, {SourceName}, {Now()}.
When omitted, defaults to backup-{SourceName}-{Now()}.

.PARAMETER ExcludePattern
Wildcard patterns excluded from the archive.

.PARAMETER Encrypt
Enables archive encryption.

.PARAMETER Password
SecureString password used when -Encrypt is enabled.

.PARAMETER PasswordManager
Password manager provider name. Empty means disabled.
Supported value: Bitwarden.

.PARAMETER NonInteractive
Skips prompts and resolves values from explicit params, config, and defaults.

.PARAMETER ConfigPath
Path to config JSON. Defaults to backup.config.json in the repo root.

.EXAMPLE
.\Run.ps1

.EXAMPLE
.\Run.ps1 -NonInteractive

.EXAMPLE
$pw = Read-Host "Archive password" -AsSecureString
.\Run.ps1 -NonInteractive -SourcePath "S:\" -BackupLocation "D:\Backups" -ExcludePattern "[[]no-sync[]]*" -Encrypt -Password $pw

.EXAMPLE
.\Run.ps1 -NonInteractive -Encrypt -PasswordManager "Bitwarden"

.EXAMPLE
.\Run.ps1 -NonInteractive -DestinationName "my-custom-name-I-wish"

.EXAMPLE
.\Run.ps1 -NonInteractive -DestinationName ""

.EXAMPLE
.\Run.ps1 -NonInteractive -NamePattern "backup-{DestinationName}-{Now()}"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourcePath,

    [Parameter()]
    [string]$BackupLocation,

    [Parameter()]
    [AllowEmptyString()]
    [string]$DestinationName,

    [Parameter()]
    [string]$NamePattern,

    [Parameter()]
    [string[]]$ExcludePattern,

    [Parameter()]
    [switch]$Encrypt,

    [Parameter()]
    [System.Security.SecureString]$Password,

    [Parameter()]
    [string]$PasswordManager,

    [Parameter()]
    [switch]$NonInteractive,

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

function Convert-ToEnvSegment {
    param([Parameter(Mandatory = $true)][string]$Text)

    $value = $Text.ToUpperInvariant()
    $value = ($value -replace '[^A-Z0-9]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'VALUE'
    }

    return $value
}

function Set-PasswordManagerEnvironmentVariables {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter()][string]$RootKey = 'PasswordManagers',
        [Parameter()][string]$Prefix = 'BACKMEUP_PM'
    )

    if (-not (Test-ConfigProperty -Config $Config -Name $RootKey)) {
        return
    }

    $root = $Config.$RootKey
    if ($null -eq $root) {
        return
    }

    function Set-NestedEnvValue {
        param(
            [Parameter(Mandatory = $true)][object]$Node,
            [string[]]$PathSegments = @(),
            [Parameter(Mandatory = $true)][string]$EnvPrefix
        )

        if ($null -eq $Node) {
            return
        }

        $properties = @()
        if (($Node -isnot [string]) -and ($Node.PSObject -ne $null)) {
            $properties = @($Node.PSObject.Properties)
        }

        if ($properties.Count -gt 0) {
            foreach ($property in $properties) {
                Set-NestedEnvValue -Node $property.Value -PathSegments ($PathSegments + $property.Name) -EnvPrefix $EnvPrefix
            }
            return
        }

        if (@($PathSegments).Count -eq 0) {
            return
        }

        $envSegments = @($EnvPrefix) + @($PathSegments | ForEach-Object { Convert-ToEnvSegment -Text [string]$_ })
        $envName = ($envSegments -join '_')
        $envValue = if ($null -eq $Node) { '' } else { [string]$Node }
        [Environment]::SetEnvironmentVariable($envName, $envValue, 'Process')
    }

    Set-NestedEnvValue -Node $root -PathSegments @() -EnvPrefix $Prefix
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

function Get-BackupDestination {
    param([Parameter(Mandatory = $true)][string]$Location)

    if ([string]::IsNullOrWhiteSpace($Location)) {
        throw 'BackupLocation cannot be empty.'
    }

    $firstColonIndex = $Location.IndexOf(':')
    if ($firstColonIndex -le 0) {
        return [pscustomobject]@{
            Provider = 'Local'
            Root = $Location
        }
    }

    $prefix = $Location.Substring(0, $firstColonIndex)
    if ($prefix.Length -eq 1 -and $prefix -match '^[A-Za-z]$') {
        return [pscustomobject]@{
            Provider = 'Local'
            Root = $Location
        }
    }

    return [pscustomobject]@{
        Provider = 'Rclone'
        Root = $Location
    }
}

function Get-LocalStagingRoot {
    $sessionId = [guid]::NewGuid().ToString('N')
    $stagingRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("back-me-up-{0}" -f $sessionId)
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    return $stagingRoot
}

function Resolve-ArchiveFileNameFromExpression {
    param(
        [Parameter(Mandatory = $true)][string]$Expression,
        [Parameter(Mandatory = $true)][string]$DestinationName,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $resolvedName = $Expression
    $resolvedName = $resolvedName.Replace('{DestinationName}', $DestinationName)
    $resolvedName = $resolvedName.Replace('{SourceName}', $SourceName)
    $resolvedName = $resolvedName.Replace('{Now()}', $timestamp)

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $invalidCharsPattern = '[{0}]' -f [regex]::Escape(($invalidChars -join ''))
    $resolvedName = ($resolvedName -replace $invalidCharsPattern, '_').Trim()

    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        throw 'NamePattern resolved to an empty archive file name.'
    }

    if (-not $resolvedName.EndsWith('.7z', [System.StringComparison]::OrdinalIgnoreCase)) {
        $resolvedName = "$resolvedName.7z"
    }

    return $resolvedName
}

function Resolve-PasswordManagerProvider {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'None'
    }

    $normalized = $Name.Trim()
    if ([string]::Equals($normalized, 'Bitwarden', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Bitwarden'
    }

    throw "Unsupported PasswordManager '$Name'. Supported values: Bitwarden."
}

function Get-PasswordManagerScriptPath {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$ScriptsDirectory
    )

    $scriptName = "Get-PasswordFrom{0}.ps1" -f $Provider
    $path = Join-Path -Path $ScriptsDirectory -ChildPath $scriptName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Password manager provider script not found at '$path'."
    }

    return $path
}

function Resolve-InteractivePasswordSourceChoice {
    param([bool]$DefaultToManager)

    try {
        $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Manual password', 'Type the password manually.'),
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Password manager', 'Retrieve the password from a configured password manager.'),
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel', 'Stop the backup run.')
        )

        $defaultChoice = if ($DefaultToManager) { 1 } else { 0 }
        $selection = $Host.UI.PromptForChoice(
            'Archive password source',
            'How do you want to provide the archive password?',
            $choices,
            $defaultChoice
        )

        switch ($selection) {
            0 { return 'Manual' }
            1 { return 'Manager' }
            default { return 'Cancel' }
        }
    }
    catch {
        while ($true) {
            $inputValue = Read-Host 'Password source: enter M (manual), P (password manager), or C (cancel)'
            $normalized = if ($null -eq $inputValue) { '' } else { $inputValue.Trim().ToUpperInvariant() }

            switch ($normalized) {
                'M' { return 'Manual' }
                'P' { return 'Manager' }
                'C' { return 'Cancel' }
                default { }
            }
        }
    }
}

function Read-InteractivePasswordManagerProvider {
    param([string]$CurrentProviderName)

    while ($true) {
        $defaultProvider = if ([string]::IsNullOrWhiteSpace($CurrentProviderName)) { 'Bitwarden' } else { $CurrentProviderName.Trim() }
        $inputValue = Read-Host "PasswordManager provider [$defaultProvider]"
        $candidate = if ([string]::IsNullOrWhiteSpace($inputValue)) { $defaultProvider } else { $inputValue.Trim() }

        try {
            return Resolve-PasswordManagerProvider -Name $candidate
        }
        catch {
            Write-BackupLog -Level WARNING -Message $_.Exception.Message
        }
    }
}

function Resolve-InteractivePasswordManagerFailureAction {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    Write-BackupLog -Level WARNING -Message "Password retrieval from $Provider failed. $FailureMessage"

    try {
        $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Enter password', 'Provide an explicit password now.'),
            (New-Object System.Management.Automation.Host.ChoiceDescription '&No encryption', 'Continue without archive encryption.'),
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel', 'Stop the backup run.')
        )

        $selection = $Host.UI.PromptForChoice(
            'Password retrieval failed',
            "Unable to retrieve password from $Provider. Choose how to continue.",
            $choices,
            0
        )

        switch ($selection) {
            0 { return 'EnterPassword' }
            1 { return 'NoEncryption' }
            default { return 'Cancel' }
        }
    }
    catch {
        while ($true) {
            $inputValue = Read-Host 'Password retrieval failed. Enter P (provide password), N (no encryption), or C (cancel)'
            $normalized = if ($null -eq $inputValue) { '' } else { $inputValue.Trim().ToUpperInvariant() }

            switch ($normalized) {
                'P' { return 'EnterPassword' }
                'N' { return 'NoEncryption' }
                'C' { return 'Cancel' }
                default { }
            }
        }
    }
}

function Get-PasswordFromManager {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$ScriptsDirectory,
        [Parameter(Mandatory = $true)][bool]$NonInteractiveExecution,
        [Parameter(Mandatory = $true)][bool]$VerboseEnabled
    )

    $providerScriptPath = Get-PasswordManagerScriptPath -Provider $Provider -ScriptsDirectory $ScriptsDirectory
    $result = & $providerScriptPath -NonInteractive:$NonInteractiveExecution -Verbose:$VerboseEnabled
    $secure = $result | Select-Object -Last 1

    if ($secure -isnot [System.Security.SecureString]) {
        throw "$Provider provider did not return a secure password value."
    }

    return $secure
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$defaultSourceRoot = Get-BackupDefaultSourcePath -RepoRoot $scriptRoot
$scriptsDir = Join-Path -Path $scriptRoot -ChildPath 'scripts'
$commonScriptPath = Join-Path -Path $scriptsDir -ChildPath 'Common.ps1'
$archiveScriptPath = Join-Path -Path $scriptsDir -ChildPath 'Archive-Local.ps1'
$rcloneUploadScriptPath = Join-Path -Path $scriptsDir -ChildPath 'Upload-Rclone.ps1'

foreach ($required in @($commonScriptPath, $archiveScriptPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required script not found at '$required'."
    }
}

. $commonScriptPath

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $scriptRoot -ChildPath 'backup.config.json'
}

[Environment]::SetEnvironmentVariable('BACKMEUP_CONFIG_PATH', $ConfigPath, 'Process')

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
$defaultNamePattern = 'backup-{SourceName}-{Now()}'

$sourceFromConfig = if (Test-ConfigProperty -Config $config -Name 'SourcePath') { [string]$config.SourcePath } else { $null }
$backupLocationFromConfig = if (Test-ConfigProperty -Config $config -Name 'BackupLocation') { [string]$config.BackupLocation } else { $null }
$passwordManagerFromConfig = if (Test-ConfigProperty -Config $config -Name 'PasswordManager') { [string]$config.PasswordManager } else { $null }
$excludeFromConfig = Get-ConfigStringArray -Config $config -Name 'ExcludePattern'
$namePatternFromConfig = if (Test-ConfigProperty -Config $config -Name 'NamePattern') { [string]$config.NamePattern } else { $null }

$encryptFromConfig = $false
$encryptConfigSpecified = $false
if (Test-ConfigProperty -Config $config -Name 'EncryptionEnabled') {
    $encryptFromConfig = [bool]$config.EncryptionEnabled
    $encryptConfigSpecified = $true
}

$sourcePathSpecified = $PSBoundParameters.ContainsKey('SourcePath')
$backupLocationSpecified = $PSBoundParameters.ContainsKey('BackupLocation')
$destinationNameSpecified = $PSBoundParameters.ContainsKey('DestinationName')
$passwordManagerSpecified = $PSBoundParameters.ContainsKey('PasswordManager')
$namePatternSpecified = $PSBoundParameters.ContainsKey('NamePattern')
$excludePatternSpecified = $PSBoundParameters.ContainsKey('ExcludePattern')
$encryptSpecified = $PSBoundParameters.ContainsKey('Encrypt')
$passwordSpecified = $PSBoundParameters.ContainsKey('Password')
if ($passwordSpecified -and -not $encryptSpecified) {
    $Encrypt = $true
    $encryptSpecified = $true
}

$resolvedSourcePath = if ($sourcePathSpecified) { $SourcePath } elseif (-not [string]::IsNullOrWhiteSpace($sourceFromConfig)) { $sourceFromConfig } else { $defaultSourcePath }
$resolvedBackupLocation = if ($backupLocationSpecified) { $BackupLocation } elseif (-not [string]::IsNullOrWhiteSpace($backupLocationFromConfig)) { $backupLocationFromConfig } else { $defaultBackupLocation }
$resolvedExcludePattern = if ($excludePatternSpecified) { @($ExcludePattern) } elseif ($excludeFromConfig.Count -gt 0) { @($excludeFromConfig) } else { @($defaultExcludePattern) }
$resolvedNamePattern = if ($namePatternSpecified) { $NamePattern } elseif (-not [string]::IsNullOrWhiteSpace($namePatternFromConfig)) { $namePatternFromConfig } else { $defaultNamePattern }
$resolvedPasswordManager = if ($passwordManagerSpecified) { $PasswordManager } elseif (-not [string]::IsNullOrWhiteSpace($passwordManagerFromConfig)) { $passwordManagerFromConfig } else { '' }
$useEncryption = if ($encryptSpecified) { [bool]$Encrypt } elseif ($encryptConfigSpecified) { $encryptFromConfig } else { $false }

Set-PasswordManagerEnvironmentVariables -Config $config

$resolvedPasswordManager = if ([string]::IsNullOrWhiteSpace($resolvedPasswordManager)) { '' } else { $resolvedPasswordManager.Trim() }
$passwordManagerProvider = Resolve-PasswordManagerProvider -Name $resolvedPasswordManager

if ($passwordSpecified -and $passwordManagerProvider -ne 'None') {
    Write-BackupLog -Level WARNING -Message 'PasswordManager is ignored because Password was explicitly provided.'
}

if (-not $NonInteractive) {
    if (-not $sourcePathSpecified) {
        $resolvedSourcePath = Read-ResolvedTextValue -Label 'SourcePath' -CurrentValue $resolvedSourcePath
    }

    if (-not $backupLocationSpecified) {
        $resolvedBackupLocation = Read-ResolvedTextValue -Label 'BackupLocation' -CurrentValue $resolvedBackupLocation
    }

    if (-not $excludePatternSpecified) {
        $resolvedExcludePattern = Read-ResolvedExcludePattern -CurrentPatterns $resolvedExcludePattern
    }

    if (-not $encryptSpecified) {
        $useEncryption = Read-ResolvedEncryptionChoice -CurrentValue $useEncryption
    }
}

if (-not $NonInteractive -and $useEncryption -and -not $passwordSpecified) {
    $passwordSourceChoice = Resolve-InteractivePasswordSourceChoice -DefaultToManager:($passwordManagerProvider -ne 'None')

    switch ($passwordSourceChoice) {
        'Manual' {
            $passwordManagerProvider = 'None'
        }
        'Manager' {
            if ($passwordManagerProvider -eq 'None') {
                $passwordManagerProvider = Read-InteractivePasswordManagerProvider -CurrentProviderName $resolvedPasswordManager
            }
        }
        default {
            Write-BackupLog -Level INFO -Message 'Backup canceled by user before password input.'
            return
        }
    }
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

$destination = Get-BackupDestination -Location $resolvedBackupLocation
if ($destination.Provider -eq 'Local') {
    New-Item -ItemType Directory -Path $destination.Root -Force | Out-Null
}
elseif ($destination.Provider -eq 'Rclone') {
    if (-not (Test-Path -LiteralPath $rcloneUploadScriptPath -PathType Leaf)) {
        throw "Required upload script not found at '$rcloneUploadScriptPath'."
    }
}
else {
    throw "Unsupported backup destination provider '$($destination.Provider)'."
}

if ($useEncryption -and -not $passwordSpecified) {
    if ($passwordManagerProvider -ne 'None') {
        while ($useEncryption -and -not $passwordSpecified -and $passwordManagerProvider -ne 'None') {
            try {
                $Password = Get-PasswordFromManager -Provider $passwordManagerProvider -ScriptsDirectory $scriptsDir -NonInteractiveExecution $NonInteractive -VerboseEnabled ($VerbosePreference -ne 'SilentlyContinue')
                $passwordSpecified = $true
                break
            }
            catch {
                if ($NonInteractive) {
                    throw "Password retrieval from $passwordManagerProvider failed in -NonInteractive mode. $($_.Exception.Message)"
                }

                $action = Resolve-InteractivePasswordManagerFailureAction -Provider $passwordManagerProvider -FailureMessage $_.Exception.Message
                switch ($action) {
                    'EnterPassword' {
                        $Password = Read-ArchivePasswordFromPrompt
                        $passwordSpecified = $true
                    }
                    'NoEncryption' {
                        $useEncryption = $false
                        $passwordSpecified = $false
                    }
                    default {
                        Write-BackupLog -Level INFO -Message 'Backup canceled by user after password manager retrieval failure.'
                        return
                    }
                }
            }
        }
    }
}

if ($useEncryption -and -not $passwordSpecified) {
    if ($NonInteractive) {
        throw 'Encryption is enabled but Password was not provided in -NonInteractive mode.'
    }

    $Password = Read-ArchivePasswordFromPrompt
    $passwordSpecified = $true
}

if (-not $useEncryption -and $passwordSpecified) {
    throw 'Password was provided but -Encrypt is not enabled.'
}

$safeSourceName = Get-BackupSafeFolderName -Path $resolvedSourcePath
$archivePrefix = "backup-$safeSourceName"
$resolvedDestinationFolderName = if ($destinationNameSpecified) { $DestinationName } else { $safeSourceName }
if ([string]::IsNullOrWhiteSpace($resolvedDestinationFolderName)) {
    $resolvedDestinationFolderName = ''
}
else {
    $resolvedDestinationFolderName = $resolvedDestinationFolderName.Trim()
}

$archiveNameDestinationToken = if ([string]::IsNullOrWhiteSpace($resolvedDestinationFolderName)) { $safeSourceName } else { $resolvedDestinationFolderName }
$resolvedArchiveFileName = Resolve-ArchiveFileNameFromExpression -Expression $resolvedNamePattern -DestinationName $archiveNameDestinationToken -SourceName $safeSourceName

$stagingRoot = $null
if ($destination.Provider -eq 'Rclone') {
    $stagingRoot = Get-LocalStagingRoot
}

$archiveParams = @{
    SourcePath = $resolvedSourcePath
    OutputRoot = if ($destination.Provider -eq 'Local') { $destination.Root } else { $stagingRoot }
    DestinationFolderName = $resolvedDestinationFolderName
    ArchiveFileName = $resolvedArchiveFileName
    ArchivePrefix = $archivePrefix
    CompressionLevel = 9
    ExcludePattern = @($resolvedExcludePattern)
    Verbose = ($VerbosePreference -ne 'SilentlyContinue')
}

if ($useEncryption) {
    $archiveParams.ArchivePassword = $Password
}


try {
    $archivePath = (& $archiveScriptPath @archiveParams | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        throw 'Archive script did not return an archive path.'
    }

    if ($destination.Provider -eq 'Rclone') {
        $localArchivePath = $archivePath
        $archivePath = (& $rcloneUploadScriptPath -ArchivePath $localArchivePath -RemoteRoot $destination.Root -ContainerName $resolvedDestinationFolderName -Verbose:($VerbosePreference -ne 'SilentlyContinue') | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($archivePath)) {
            throw 'Rclone upload script did not return a remote archive path.'
        }
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($stagingRoot) -and (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-BackupLog -Level INFO -Message "Backup completed. Archive created at '$archivePath'."
Write-Output $archivePath
