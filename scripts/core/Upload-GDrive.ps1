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
