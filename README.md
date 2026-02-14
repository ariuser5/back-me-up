# back-me-up

This repository is intended to live inside the location you want to back up regularly.

## Repository scope

The repo provides a PowerShell-based backup workflow that:
- creates an encrypted `.7z` archive of a configured source location,
- uploads it to a configured `rclone` destination,
- optionally keeps or deletes the local archive,
- supports password retrieval from Bitwarden or direct password injection.

The recommended layout is to clone this repo at the top level of the folder/drive you want to back up, then rename the cloned folder to `.ctrl` (hidden-style control folder).

## Recommended workflow

1. Clone this repo into the location to protect.
2. Rename the repo folder to `.ctrl`.
3. Initialize local config once:

```powershell
pwsh -File .\Initialize.ps1
```

4. Run backups from `.ctrl` with:

```powershell
pwsh -File .\Create-Backup.ps1
```

With this setup, `Create-Backup.ps1` defaults to backing up the parent folder of `.ctrl`.

## Local config (git-ignored)

`backup.config.json` is a machine-local config file created by `Initialize.ps1` and ignored by git.

Default generated values:

```json
{
  "SourcePath": "<parent-of-.ctrl>",
  "KeepLocal": false,
  "RcloneDest": "gdrive:Backups/{SourceFolderName}"
}
```

You can adjust this file per machine/location without affecting commits.

### Precedence rules

`Create-Backup.ps1` resolves values in this order:
- explicit script parameters,
- `backup.config.json` values,
- built-in defaults.

So you can keep stable defaults in config and override ad-hoc when needed.

## Initialization script

`Initialize.ps1` creates `backup.config.json` for the current clone location.

Examples:

```powershell
pwsh -File .\Initialize.ps1
pwsh -File .\Initialize.ps1 -Force
```

## Main scripts

- `Create-Backup.ps1`: top-level wrapper for daily use.
- `Initialize.ps1`: creates local default config for this clone.
- `scripts/Backup-Create.ps1`: orchestration pipeline.
- `scripts/core/Archive-Local.ps1`: encrypted local archive creation.
- `scripts/core/Upload-GDrive.ps1`: upload + optional local cleanup.
- `scripts/core/Bitwarden-Session.ps1`: Bitwarden acquire/cleanup session logic.
- `scripts/core/Common.ps1`: shared helpers.

## Prerequisites

- `7z` (7-Zip) available in `PATH` or standard install location.
- `rclone` available in `PATH` and configured.
- Bitwarden CLI (`bw`) in `PATH` if not supplying `-ArchivePassword` manually.

## Useful command examples

Run with config defaults:

```powershell
pwsh -File .\Create-Backup.ps1
```

Override source once:

```powershell
pwsh -File .\Create-Backup.ps1 -SourcePath "D:\Projects"
```

Keep local archive for this run only:

```powershell
pwsh -File .\Create-Backup.ps1 -KeepLocal
```

Override remote destination for this run:

```powershell
pwsh -File .\Create-Backup.ps1 -RcloneDest "gdrive:Backups/{SourceFolderName}"
```

Skip Bitwarden and provide password directly:

```powershell
$pw = Read-Host "Archive password" -AsSecureString
pwsh -File .\Create-Backup.ps1 -ArchivePassword $pw
```