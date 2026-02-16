<#
.SYNOPSIS
Retrieves archive password from Bitwarden CLI.

.DESCRIPTION
Reads a password from a Bitwarden item using `bw get password <ItemName>`.
Returns a SecureString on success.

.PARAMETER ItemName
Bitwarden item name (or id) used by `bw get password`.
If omitted, resolves from environment variable `BACKMEUP_PM_BITWARDEN_ITEMNAME`.

.PARAMETER NonInteractive
When set, uses `--nointeraction` to ensure the command fails instead of prompting.

.PARAMETER Command
Bitwarden CLI command name. Defaults to `bw`.
If omitted, resolves from `BACKMEUP_PM_BITWARDEN_COMMAND` and then falls back to `bw`.

.EXAMPLE
.\scripts\Get-PasswordFromBitwarden.ps1 -ItemName 'backup-archive-password'

.EXAMPLE
.\scripts\Get-PasswordFromBitwarden.ps1 -ItemName 'backup-archive-password' -NonInteractive
#>

[CmdletBinding()]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string]$ItemName,

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [AllowEmptyString()]
    [string]$Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-BitwardenRetryAction {
    try {
        $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Retry with item', 'Retry using a different Bitwarden item name.'),
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel', 'Stop password retrieval.')
        )

        $selection = $Host.UI.PromptForChoice(
            'Bitwarden password retrieval failed',
            'Choose how to continue.',
            $choices,
            0
        )

        if ($selection -eq 0) {
            return 'Retry'
        }

        return 'Cancel'
    }
    catch {
        while ($true) {
            $inputValue = Read-Host 'Bitwarden retrieval failed. Enter R (retry with another item) or C (cancel)'
            $normalized = if ($null -eq $inputValue) { '' } else { $inputValue.Trim().ToUpperInvariant() }

            switch ($normalized) {
                'R' { return 'Retry' }
                'C' { return 'Cancel' }
                default { }
            }
        }
    }
}

function Read-BitwardenItemName {
    param([string]$CurrentItemName)

    while ($true) {
        $defaultItem = if ([string]::IsNullOrWhiteSpace($CurrentItemName)) { '' } else { $CurrentItemName.Trim() }
        $promptText = if ([string]::IsNullOrWhiteSpace($defaultItem)) { 'Bitwarden item name' } else { "Bitwarden item name [$defaultItem]" }
        $inputValue = Read-Host $promptText
        $candidate = if ([string]::IsNullOrWhiteSpace($inputValue)) { $defaultItem } else { $inputValue.Trim() }

        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }

        Write-Host '[WARNING] Bitwarden item name cannot be empty.'
    }
}

function Get-BitwardenItemNameFromConfig {
    $configPath = $env:BACKMEUP_CONFIG_PATH
    if ([string]::IsNullOrWhiteSpace($configPath)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $null
    }

    try {
        $configRaw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($configRaw)) {
            return $null
        }

        $config = $configRaw | ConvertFrom-Json
        if ($null -eq $config -or -not ($config.PSObject.Properties.Name -contains 'PasswordManagers')) {
            return $null
        }

        $passwordManagers = $config.PasswordManagers
        if ($null -eq $passwordManagers -or -not ($passwordManagers.PSObject.Properties.Name -contains 'Bitwarden')) {
            return $null
        }

        $bitwardenSection = $passwordManagers.Bitwarden
        if ($null -eq $bitwardenSection -or -not ($bitwardenSection.PSObject.Properties.Name -contains 'ItemName')) {
            return $null
        }

        $value = [string]$bitwardenSection.ItemName
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        return $value.Trim()
    }
    catch {
        return $null
    }
}

$resolvedCommand = if (-not [string]::IsNullOrWhiteSpace($Command)) { $Command.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($env:BACKMEUP_PM_BITWARDEN_COMMAND)) { $env:BACKMEUP_PM_BITWARDEN_COMMAND.Trim() } else { 'bw' }
$itemSource = 'none'
$resolvedItemName = ''
if (-not [string]::IsNullOrWhiteSpace($ItemName)) {
    $resolvedItemName = $ItemName.Trim()
    $itemSource = 'parameter'
}
elseif (-not [string]::IsNullOrWhiteSpace($env:BACKMEUP_PM_BITWARDEN_ITEMNAME)) {
    $resolvedItemName = $env:BACKMEUP_PM_BITWARDEN_ITEMNAME.Trim()
    $itemSource = 'environment BACKMEUP_PM_BITWARDEN_ITEMNAME'
}
elseif (-not [string]::IsNullOrWhiteSpace($env:BACKMEUP_PM_BITWARDEN_ITEM_NAME)) {
    $resolvedItemName = $env:BACKMEUP_PM_BITWARDEN_ITEM_NAME.Trim()
    $itemSource = 'environment BACKMEUP_PM_BITWARDEN_ITEM_NAME'
}
else {
    $fromConfig = Get-BitwardenItemNameFromConfig
    if (-not [string]::IsNullOrWhiteSpace($fromConfig)) {
        $resolvedItemName = $fromConfig
        $itemSource = 'config PasswordManagers.Bitwarden.ItemName'
    }
}

if (-not [string]::IsNullOrWhiteSpace($resolvedItemName)) {
    Write-Host "[INFO] Using Bitwarden item name from $itemSource."
}

$bitwardenCommand = Get-Command -Name $resolvedCommand -ErrorAction SilentlyContinue
if ($null -eq $bitwardenCommand) {
    throw "Bitwarden CLI '$resolvedCommand' was not found. Install Bitwarden CLI and ensure it is available in PATH."
}

$currentItemName = $resolvedItemName
if ($NonInteractive -and [string]::IsNullOrWhiteSpace($currentItemName)) {
    throw 'Bitwarden item name is required in -NonInteractive mode. Set PasswordManagers.Bitwarden.ItemName in config or pass -ItemName.'
}

if (-not $NonInteractive -and [string]::IsNullOrWhiteSpace($currentItemName)) {
    $currentItemName = Read-BitwardenItemName -CurrentItemName $currentItemName
}

while ($true) {
    $arguments = @('get', 'password', $currentItemName)
    if ($NonInteractive) {
        $arguments = @('--nointeraction') + $arguments
    }

    Write-Host "[INFO] Retrieving password from Bitwarden item '$currentItemName'."

    $output = & $bitwardenCommand.Source @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($NonInteractive) {
            throw "Bitwarden password retrieval failed in non-interactive mode for item '$currentItemName'. Ensure Bitwarden CLI is logged in and unlocked."
        }

        Write-Host "[WARNING] Bitwarden password retrieval failed for item '$currentItemName'."
        $action = Resolve-BitwardenRetryAction
        if ($action -eq 'Retry') {
            $currentItemName = Read-BitwardenItemName -CurrentItemName $currentItemName
            continue
        }

        throw 'Bitwarden password retrieval canceled by user.'
    }

    $lines = @($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $passwordPlain = if ($lines.Count -gt 0) { $lines[-1].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($passwordPlain)) {
        if ($NonInteractive) {
            throw "Bitwarden returned an empty password for item '$currentItemName'."
        }

        Write-Host "[WARNING] Bitwarden returned an empty password for item '$currentItemName'."
        $action = Resolve-BitwardenRetryAction
        if ($action -eq 'Retry') {
            $currentItemName = Read-BitwardenItemName -CurrentItemName $currentItemName
            continue
        }

        throw 'Bitwarden password retrieval canceled by user.'
    }

    $securePassword = ConvertTo-SecureString -String $passwordPlain -AsPlainText -Force
    $passwordPlain = $null

    Write-Host "[INFO] Password retrieved from Bitwarden item '$currentItemName'."
    return $securePassword
}
