<#
.SYNOPSIS
Creates an encrypted 7-Zip archive from a source directory.

.DESCRIPTION
Builds a timestamped archive under the configured output root, optionally filtering
files with exclude patterns, and returns the full archive path on success.

.PARAMETER SourcePath
Directory to archive.

.PARAMETER OutputRoot
Root directory where archive output is written.

.PARAMETER ArchivePrefix
Prefix used in the generated archive file name.

.PARAMETER CompressionLevel
7-Zip compression level from 0 to 9.

.PARAMETER ExcludePattern
Wildcard patterns for files or directories to exclude.

.PARAMETER ArchivePassword
Secure string password used for archive encryption.

.EXAMPLE
.\Archive-Local.ps1 -SourcePath 'D:\Data' -ArchivePassword $securePassword
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PCOps\Backups'),

    [Parameter()]
    [string]$ArchivePrefix,

    [Parameter()]
    [ValidateRange(0, 9)]
    [int]$CompressionLevel = 9,

    [Parameter()]
    [string[]]$ExcludePattern,

    [Parameter(Mandatory = $true)]
    [System.Security.SecureString]$ArchivePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath 'Common.ps1')

function Test-BackupMatchesExcludePattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    $relativePathNormalized = $RelativePath -replace '/', '\\'
    $leafName = Split-Path -Path $relativePathNormalized -Leaf
    $segments = $relativePathNormalized -split '\\'

    foreach ($rawPattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($rawPattern)) {
            continue
        }

        $pattern = $rawPattern -replace '/', '\\'

        if ($relativePathNormalized -like $pattern) {
            return $true
        }

        if ($leafName -like $pattern) {
            return $true
        }

        foreach ($segment in $segments) {
            if ($segment -like $pattern) {
                return $true
            }
        }
    }

    return $false
}

function New-ArchiveIncludeListFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootFolder,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    $files = Get-ChildItem -LiteralPath $RootFolder -Recurse -File -Force
    $includeList = New-Object System.Collections.Generic.List[string]

    foreach ($file in $files) {
        $relativePath = [System.IO.Path]::GetRelativePath($RootFolder, $file.FullName)
        $relativePath = $relativePath -replace '/', '\\'

        if (-not (Test-BackupMatchesExcludePattern -RelativePath $relativePath -Patterns $Patterns)) {
            $includeList.Add($relativePath)
        }
    }

    if ($includeList.Count -eq 0) {
        throw 'No files remain to archive after applying ExcludePattern filters.'
    }

    Write-BackupDebug -Message "Archive include list built with $($includeList.Count) files after applying exclude filters."

    $listFilePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("pcops-7z-include-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $listFilePath -Value $includeList -Encoding utf8
    return $listFilePath
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "Source path '$SourcePath' does not exist or is not a directory."
}

Write-BackupDebug -Message "Archive creation started (SourcePath='$SourcePath', CompressionLevel=$CompressionLevel, ExcludePatternCount=$(@($ExcludePattern).Count))."

$passwordPtr = [System.IntPtr]::Zero
try {
    $passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ArchivePassword)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)

    if ([string]::IsNullOrWhiteSpace($password)) {
        throw 'ArchivePassword is empty.'
    }

    $sourceFolder = (Resolve-Path -LiteralPath $SourcePath).Path
    $sevenZipPath = Get-Backup7ZipPath
    $safeFolderName = Get-BackupSafeFolderName -Path $sourceFolder

    if ([string]::IsNullOrWhiteSpace($ArchivePrefix)) {
        $ArchivePrefix = $safeFolderName
    }

    $targetOutputDir = Join-Path -Path $OutputRoot -ChildPath $safeFolderName
    New-Item -ItemType Directory -Path $targetOutputDir -Force | Out-Null
    Write-BackupDebug -Message "Archive output directory resolved to '$targetOutputDir'."

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $archiveName = "$ArchivePrefix-$timestamp.7z"
    $archivePath = Join-Path -Path $targetOutputDir -ChildPath $archiveName

    $listFilePath = $null
    $archiveInputs = @('.\\*')

    if ($ExcludePattern -and $ExcludePattern.Count -gt 0) {
        $listFilePath = New-ArchiveIncludeListFile -RootFolder $sourceFolder -Patterns $ExcludePattern
        $archiveInputs = @("@$listFilePath")
    }
    else {
        Write-BackupDebug -Message 'No exclude patterns provided; archiving all files under source path.'
    }

    $args = @(
        'a',
        '-t7z',
        "-mx=$CompressionLevel",
        '-mhe=on',
        "-p$password",
        '-y',
        $archivePath
    )

    $args += $archiveInputs

    Push-Location -Path $sourceFolder
    try {
        Write-BackupLog -Level INFO -Message "Creating encrypted archive at '$archivePath'."
        Invoke-BackupExternalCommand -FilePath $sevenZipPath -Arguments $args -FriendlyName '7-Zip'
    }
    finally {
        Pop-Location

        if ($null -ne $listFilePath -and (Test-Path -LiteralPath $listFilePath)) {
            Remove-Item -LiteralPath $listFilePath -Force -ErrorAction SilentlyContinue
        }
    }

    $password = $null
    Write-Output $archivePath
}
finally {
    if ($passwordPtr -ne [System.IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    }
}
