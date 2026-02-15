<#
.SYNOPSIS
Uploads an archive file to an rclone remote destination.

.DESCRIPTION
Uses rclone to copy a local archive file to a configured remote and returns
its remote destination path on success.

.PARAMETER ArchivePath
Full path to the local archive file.

.PARAMETER RemoteRoot
Rclone destination root, for example gdrive:Documents/some/path.

.PARAMETER ContainerName
Subfolder name under RemoteRoot where the file should be uploaded.

.EXAMPLE
.\scripts\Upload-Rclone.ps1 -ArchivePath 'C:\Temp\backup.7z' -RemoteRoot 'gdrive:Documents/backups' -ContainerName 'MyDrive'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RemoteRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath 'Common.ps1')

if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Archive path '$ArchivePath' does not exist or is not a file."
}

$rcloneCommand = Get-Command -Name 'rclone' -ErrorAction SilentlyContinue
if ($null -eq $rcloneCommand) {
    throw 'rclone executable was not found. Install rclone and ensure it is available in PATH.'
}

$archiveFileName = [System.IO.Path]::GetFileName($ArchivePath)
$normalizedRemoteRoot = $RemoteRoot.TrimEnd('/')
$targetRemotePath = "$normalizedRemoteRoot/$ContainerName/$archiveFileName"

Write-BackupLog -Level INFO -Message "Uploading archive to '$targetRemotePath' via rclone."
Invoke-BackupExternalCommand -FilePath $rcloneCommand.Source -Arguments @('copyto', $ArchivePath, $targetRemotePath) -FriendlyName 'rclone'

Write-Output $targetRemotePath
