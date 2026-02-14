<#
.SYNOPSIS
Manages Bitwarden password acquisition and cleanup flow.

.DESCRIPTION
Provides Acquire and Cleanup actions for backup workflows. Acquire ensures an
authenticated and unlocked Bitwarden session, retrieves the requested password,
and emits state used later by Cleanup to restore previous session conditions.

.PARAMETER Action
Action to perform: Acquire or Cleanup.

.PARAMETER BwItemName
Bitwarden item name used to retrieve a password.

.PARAMETER BwItemId
Bitwarden item id used to retrieve a password.

.PARAMETER BwSession
Optional pre-existing BW_SESSION token to inject for acquisition.

.PARAMETER CleanupStateJson
Serialized cleanup state returned by the Acquire action.

.EXAMPLE
.\Bitwarden-Session.ps1 -Action Acquire -BwItemId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Acquire', 'Cleanup')]
    [string]$Action = 'Acquire',

    [Parameter()]
    [string]$BwItemName,

    [Parameter()]
    [string]$BwItemId,

    [Parameter()]
    [string]$BwSession,

    [Parameter()]
    [string]$CleanupStateJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath 'Common.ps1')

function Get-BwStatusInternal {
    try {
        $raw = & bw status 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Set-BwSessionInternal {
    param([string]$InjectedSession)

    $state = [ordered]@{
        InitialStatus     = $null
        DidLogin          = $false
        DidUnlock         = $false
        UsedInjectedToken = $false
        SetSessionToken   = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($InjectedSession)) {
        $env:BW_SESSION = $InjectedSession
        $state.UsedInjectedToken = $true
        $state.SetSessionToken = $true
        $state.InitialStatus = 'session-injected'
        return [pscustomobject]$state
    }

    $initial = Get-BwStatusInternal
    $state.InitialStatus = if ($null -ne $initial) { [string]$initial.status } else { 'unknown' }

    switch ($state.InitialStatus) {
        'unlocked' { return [pscustomobject]$state }
        'locked' {
            Write-BackupLog -Level INFO -Message 'Bitwarden vault is locked. Unlocking...'
            $session = (& bw unlock --raw)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($session)) { throw 'Failed to unlock Bitwarden vault.' }
            $env:BW_SESSION = $session.Trim()
            $state.DidUnlock = $true
            $state.SetSessionToken = $true
            return [pscustomobject]$state
        }
        'unauthenticated' {
            Write-BackupLog -Level INFO -Message 'Bitwarden is not logged in. Starting login...'
            & bw login | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Bitwarden login failed.' }

            $state.DidLogin = $true
            Write-BackupLog -Level INFO -Message 'Login successful. Unlocking vault...'
            $session = (& bw unlock --raw)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($session)) { throw 'Failed to unlock Bitwarden vault after login.' }
            $env:BW_SESSION = $session.Trim()
            $state.DidUnlock = $true
            $state.SetSessionToken = $true
            return [pscustomobject]$state
        }
        default {
            Write-BackupLog -Level WARNING -Message 'Could not determine Bitwarden status. Attempting unlock...'
            $session = (& bw unlock --raw)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($session)) {
                $env:BW_SESSION = $session.Trim()
                $state.DidUnlock = $true
                $state.SetSessionToken = $true
                return [pscustomobject]$state
            }
            throw 'Unable to establish a usable Bitwarden session.'
        }
    }
}

function Get-BwPasswordInternal {
    param([string]$ItemName, [string]$ItemId)

    if (-not [string]::IsNullOrWhiteSpace($ItemId)) {
        $password = (& bw get password $ItemId)
    }
    else {
        $password = (& bw get password $ItemName)
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($password)) {
        if (-not [string]::IsNullOrWhiteSpace($ItemId)) { throw "Failed to retrieve password from Bitwarden item id '$ItemId'." }
        throw "Failed to retrieve password from Bitwarden item '$ItemName'."
    }

    return $password.TrimEnd("`r", "`n")
}

function Invoke-BwCleanupCommandInternal {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$ActionName)

    $oldErrorAction = $ErrorActionPreference
    $hadNativePreference = $null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)
    if ($hadNativePreference) { $oldNativePreference = $PSNativeCommandUseErrorActionPreference }

    try {
        $ErrorActionPreference = 'Continue'
        if ($hadNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }

        & bw @Arguments 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-BackupLog -Level WARNING -Message "Bitwarden cleanup action '$ActionName' failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
        if ($hadNativePreference) { $PSNativeCommandUseErrorActionPreference = $oldNativePreference }
    }
}

if ($Action -eq 'Acquire') {
    Write-BackupDebug -Message 'Bitwarden acquire flow started.'

    if (-not (Get-Command -Name 'bw' -ErrorAction SilentlyContinue)) { throw 'Bitwarden CLI (bw) is not available in PATH.' }
    if ([string]::IsNullOrWhiteSpace($BwItemName) -and [string]::IsNullOrWhiteSpace($BwItemId)) { throw 'Either BwItemName or BwItemId must be provided.' }

    $itemSelectorMessage = if ([string]::IsNullOrWhiteSpace($BwItemId)) {
        "Using Bitwarden item name '$BwItemName'."
    }
    else {
        "Using Bitwarden item id '$BwItemId'."
    }
    Write-BackupDebug -Message $itemSelectorMessage

    $originalBwSession = $env:BW_SESSION
    $bwState = Set-BwSessionInternal -InjectedSession $BwSession | Select-Object -Last 1
    if ($null -eq $bwState -or -not ($bwState.PSObject.Properties.Name -contains 'UsedInjectedToken')) {
        throw 'Failed to establish internal Bitwarden session state.'
    }

    $password = Get-BwPasswordInternal -ItemName $BwItemName -ItemId $BwItemId
    $cleanupState = @{ BwState = $bwState; OriginalBwSession = $originalBwSession } | ConvertTo-Json -Compress -Depth 6

    Write-BackupDebug -Message "Bitwarden session state captured (InitialStatus=$($bwState.InitialStatus), DidLogin=$($bwState.DidLogin), DidUnlock=$($bwState.DidUnlock))."

    [pscustomobject]@{
        Password         = $password
        CleanupStateJson = $cleanupState
    }
    return
}

if ([string]::IsNullOrWhiteSpace($CleanupStateJson)) {
    Write-BackupDebug -Message 'Bitwarden cleanup skipped (no cleanup state provided).'
    return
}

Write-BackupDebug -Message 'Bitwarden cleanup flow started.'

$cleanupState = $null
try {
    $cleanupState = $CleanupStateJson | ConvertFrom-Json
}
catch {
    Write-BackupLog -Level WARNING -Message 'Unable to parse saved Bitwarden cleanup state.'
}

if ($null -eq $cleanupState -or $null -eq $cleanupState.BwState) {
    return
}

$bwState = $cleanupState.BwState
$originalBwSession = [string]$cleanupState.OriginalBwSession

if ($bwState.UsedInjectedToken) {
    Write-BackupLog -Level INFO -Message 'Bitwarden session was injected; leaving auth state unchanged.'
    return
}

if ($bwState.DidLogin) {
    Write-BackupLog -Level INFO -Message 'Logging out of Bitwarden (script performed login).'
    try { Invoke-BwCleanupCommandInternal -Arguments @('logout') -ActionName 'logout' } catch { Write-BackupLog -Level WARNING -Message "Bitwarden logout cleanup threw: $($_.Exception.Message)" }
}
elseif ($bwState.DidUnlock) {
    Write-BackupLog -Level INFO -Message 'Locking Bitwarden vault (script unlocked it).'
    try { Invoke-BwCleanupCommandInternal -Arguments @('lock') -ActionName 'lock' } catch { Write-BackupLog -Level WARNING -Message "Bitwarden lock cleanup threw: $($_.Exception.Message)" }
}

if ($bwState.SetSessionToken) {
    try {
        if ([string]::IsNullOrWhiteSpace($originalBwSession)) {
            Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
        }
        else {
            $env:BW_SESSION = $originalBwSession
        }
    }
    catch {
        Write-BackupLog -Level WARNING -Message "Failed to restore BW_SESSION variable: $($_.Exception.Message)"
    }
}
