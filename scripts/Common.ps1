<#
.SYNOPSIS
Shared helper functions for backup scripts.

.DESCRIPTION
Contains reusable logging, command invocation, naming, and dependency discovery
helpers used by the local backup scripts.

.EXAMPLE
. .\scripts\Common.ps1
#>

function Write-BackupLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$timestamp] [$Level] $Message"
}

function Write-BackupDebug {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Verbose "[DEBUG] $Message"
}

function Invoke-BackupExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$FriendlyName
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "$FriendlyName failed with exit code $exitCode."
        }
        throw "$FriendlyName failed (exit code: $exitCode). $message"
    }

    return $output
}

function Get-BackupSafeFolderName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $pathRoot = [System.IO.Path]::GetPathRoot($resolved)
    $normalizedResolved = $resolved.TrimEnd([char]'\', [char]'/')
    $normalizedRoot = $pathRoot.TrimEnd([char]'\', [char]'/')
    $isRootPath = -not [string]::IsNullOrWhiteSpace($normalizedRoot) -and [string]::Equals($normalizedResolved, $normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $leaf = Split-Path -Path $resolved -Leaf

    if ([string]::IsNullOrWhiteSpace($leaf) -or $isRootPath) {
        $driveToken = ($pathRoot.TrimEnd('\\')).TrimEnd(':')
        $volumeLabel = $null

        if (-not [string]::IsNullOrWhiteSpace($driveToken) -and $driveToken.Length -eq 1) {
            try {
                $volume = Get-Volume -DriveLetter $driveToken -ErrorAction Stop
                $volumeLabel = [string]$volume.FileSystemLabel
            }
            catch {
                try {
                    $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $driveToken) -ErrorAction Stop
                    $volumeLabel = [string]$logicalDisk.VolumeName
                }
                catch {
                    $volumeLabel = $null
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($volumeLabel)) {
            $leaf = $volumeLabel
        }
        else {
            $leaf = ($pathRoot -replace '[:\\/\s]+', '_').Trim('_')
            if ([string]::IsNullOrWhiteSpace($leaf)) {
                $leaf = 'backup'
            }
            $leaf = "${leaf}_root"
        }
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $invalidCharsPattern = '[{0}]' -f [regex]::Escape(($invalidChars -join ''))
    $safe = ($leaf -replace $invalidCharsPattern, '_').Trim()
    $safe = ($safe -replace '\s+', '_').Trim('_')

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'backup'
    }

    return $safe
}

function Get-Backup7ZipPath {
    $cmd = Get-Command -Name '7z', '7za' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    foreach ($path in @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw '7-Zip executable was not found. Install 7-Zip and ensure 7z.exe is available in PATH.'
}
