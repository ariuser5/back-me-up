# back-me-up

This repository is intended to live inside the location you want to back up regularly.

## Repository scope

The repo provides a PowerShell workflow that creates local `.7z` backups from a configured source path.

Recommended layout:
1. Clone this repo into the location you want to protect.
2. Rename the repo folder to `.ctrl`.
3. Run backups from `.ctrl` using `Run.ps1`.

## Main workflow

Initialize local config once:

```powershell
pwsh -File .\Initialize.ps1
```

Run backup (interactive by default):

```powershell
pwsh -File .\Run.ps1
```

In interactive mode, values are loaded from config and prompted one-by-one. You can press Enter to keep each value or edit it before continuing.

## Config file

`backup.config.json` is machine-local and ignored by git.

Default generated config:

```json
{
  "SourcePath": "<parent-of-.ctrl>",
  "BackupLocation": "%LOCALAPPDATA%\\PCOps\\Backups",
  "ExcludePattern": ["[[]no-sync[]]*", "back-me-up*",".ctrl*", "System Volume Information*", "$RECYCLE.BIN*"],
  "EncryptionEnabled": false
}
```

## Interactivity model

- Default: interactive prompts (config-backed values shown and editable).
- `-NonInteractive`: no prompts; resolves values from params, then config, then defaults.
- `-NonInteractive -Strict`: requires explicit `SourcePath`, `BackupLocation`, `ExcludePattern`, and `Encrypt` parameters. Missing imposed params fail fast.

Encryption is opt-in only (off by default). If enabled interactively without `ArchivePassword`, the script prompts for password and confirmation.

## Scripts

- `Run.ps1`: main entrypoint.
- `Initialize.ps1`: initializes local config for this clone.
- `scripts/Archive-Local.ps1`: archive creation (encrypted only when password provided).
- `scripts/Common.ps1`: shared helpers.

## Prerequisites

- `7z` (7-Zip) available in `PATH` or standard install path.

## Examples

Interactive run:

```powershell
pwsh -File .\Run.ps1
```

Non-interactive with config/default fallback:

```powershell
pwsh -File .\Run.ps1 -NonInteractive
```

Strict unattended run with explicit values:

```powershell
$pw = Read-Host "Archive password" -AsSecureString
pwsh -File .\Run.ps1 -NonInteractive -Strict -SourcePath "S:\" -BackupLocation "D:\Backups" -ExcludePattern "[[]no-sync[]]*" -Encrypt -ArchivePassword $pw
```