<#
.SYNOPSIS
Uploads a backup archive to a remote rclone destination.

.DESCRIPTION
Validates archive and rclone availability, uploads a single archive file to the
configured remote path, and optionally deletes the local archive on success.

.PARAMETER ArchivePath
Full path of the local archive to upload.

.PARAMETER RcloneDest
Target rclone destination path.

.PARAMETER KeepLocal
Keeps local archive after upload when set.

.EXAMPLE
.\Upload-GDrive.ps1 -ArchivePath 'C:\Backups\backup.7z' -RcloneDest 'gdrive:Backups'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$RcloneDest,

    [Parameter()]
    [switch]$KeepLocal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath 'Common.ps1')

if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Archive '$ArchivePath' does not exist."
}

if (-not (Get-Command -Name 'rclone' -ErrorAction SilentlyContinue)) {
    throw 'rclone is not available in PATH.'
}

Write-BackupDebug -Message "Upload step started (ArchivePath='$ArchivePath', RcloneDest='$RcloneDest', KeepLocal=$KeepLocal)."

$archiveName = Split-Path -Path $ArchivePath -Leaf
$normalizedDestination = $RcloneDest.TrimEnd('/')
$remoteFilePath = "$normalizedDestination/$archiveName"

Write-BackupLog -Level INFO -Message "Uploading archive to '$remoteFilePath'."
Invoke-BackupExternalCommand -FilePath 'rclone' -Arguments @('copyto', $ArchivePath, $remoteFilePath) -FriendlyName 'rclone'

if ($KeepLocal) {
    Write-BackupLog -Level INFO -Message "Keeping local archive: '$ArchivePath'."
}
else {
    Remove-Item -LiteralPath $ArchivePath -Force
    Write-BackupLog -Level INFO -Message 'Upload succeeded. Local archive deleted.'
}

Write-Output $remoteFilePath
