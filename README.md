# back-me-up

This repository is intended to live inside the location you want to back up regularly.

## Repository scope

The repo provides a PowerShell workflow that creates `.7z` backups from a configured source path and stores them either locally or in an rclone remote.

Recommended layout:
1. Create a `.ctrl` folder in the root of the directory you want to back up.
2. Keep `.ctrl` as the control folder.
3. Clone this repo under `.ctrl/back-me-up`.
4. Run backups from `.ctrl/back-me-up` using `Run.ps1`.

## Main workflow

Initialize local config once:

```powershell
pwsh -File .\Initialize.ps1
```

Run backup (interactive by default):

```powershell
pwsh -File .\Run.ps1
```

In interactive mode, values are loaded from config and prompted one-by-one. You can press Enter to keep each value or edit it before continuing. Any value provided explicitly as a parameter is not prompted again.

## Config file

`backup.config.json` is machine-local and ignored by git.

Default generated config:

```json
{
  "SourcePath": "<parent-of-.ctrl>",
  "BackupLocation": "%LOCALAPPDATA%\\PCOps\\Backups",
  "ExcludePattern": ["back-me-up*", ".ctrl*", "System Volume Information*", "$RECYCLE.BIN*", "[[]no-sync[]]*"],
  "EncryptionEnabled": false
}
```

In this layout, `SourcePath` defaults to the parent directory of `.ctrl`.

`BackupLocation` supports:
- Local paths, for example `C:\Backups`
- rclone remotes, for example `gdrive:Documents/some/path`

## Interactivity model

- Default: interactive prompts (config-backed values shown and editable).
- `-NonInteractive`: no prompts; resolves values from params, then config, then defaults.

Encryption is opt-in only (off by default). If enabled interactively without `ArchivePassword`, the script prompts for password and confirmation.

## Scripts

- `Run.ps1`: main entrypoint.
- `Initialize.ps1`: initializes local config for this clone.
- `scripts/Archive-Local.ps1`: archive creation (encrypted only when password provided).
- `scripts/Upload-Rclone.ps1`: upload archives to rclone remotes.
- `scripts/Common.ps1`: shared helpers.

## Prerequisites

- `7z` (7-Zip) available in `PATH` or standard install path.
- `rclone` in `PATH` when `BackupLocation` uses a remote format like `name:path`.

## Examples

Interactive run:

```powershell
pwsh -File .\Run.ps1
```

Non-interactive with config/default fallback:

```powershell
pwsh -File .\Run.ps1 -NonInteractive
```

Non-interactive with rclone remote destination:

```powershell
pwsh -File .\Run.ps1 -NonInteractive -BackupLocation "gdrive:Documents/some/path"
```

Unattended run with explicit values:

```powershell
$pw = Read-Host "Archive password" -AsSecureString
pwsh -File .\Run.ps1 -NonInteractive -SourcePath "S:\" -BackupLocation "D:\Backups" -ExcludePattern "[[]no-sync[]]*" -Encrypt -ArchivePassword $pw
```
