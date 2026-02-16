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
  "PasswordManager": "",
  "PasswordManagers": {
    "Bitwarden": {
      "ItemName": ""
    }
  },
  "NamePattern": "backup-{SourceName}-{Now()}",
  "ExcludePattern": ["back-me-up*", ".ctrl*", "System Volume Information*", "$RECYCLE.BIN*", "[[]no-sync[]]*"],
  "EncryptionEnabled": false
}
```

In this layout, `SourcePath` defaults to the parent directory of `.ctrl`.

`BackupLocation` supports:
- Local paths, for example `C:\Backups`
- rclone remotes, for example `gdrive:Documents/some/path`

`DestinationName` supports:
- Omitted: defaults to source folder name (current behavior)
- Non-empty value: uses the provided nested folder name
- Empty or whitespace: no nested folder, archive is written at destination root

`NamePattern` supports placeholders:
- `{DestinationName}`
- `{SourceName}`
- `{Now()}`

Default: `backup-{SourceName}-{Now()}`

`PasswordManager` supports:
- Empty string: disabled (default)
- `Bitwarden`: retrieves password using Bitwarden CLI and `PasswordManagers.Bitwarden.ItemName`

Password source precedence when encryption is enabled:
- Explicit `-Password` wins
- Then `PasswordManager` retrieval
- In interactive mode only: fallback prompt when manager retrieval fails

In `-NonInteractive`, manager retrieval must succeed without prompts. For Bitwarden this means CLI must already be logged in and unlocked.
If Bitwarden retrieval fails in interactive mode, the Bitwarden provider flow first offers retry with a different `ItemName`; if retrieval still fails or is canceled, `Run.ps1` then offers manual password entry, continue without encryption, or cancel.

## Interactivity model

- Default: interactive prompts (config-backed values shown and editable).
- `-NonInteractive`: no prompts; resolves values from params, then config, then defaults.

Encryption is opt-in only (off by default). If enabled interactively without `Password`, the script prompts for password and confirmation.
When encryption is enabled in interactive mode and `Password` is not explicitly provided, the script asks whether to use a manual password or retrieve it from a password manager.

## Scripts

- `Run.ps1`: main entrypoint.
- `Initialize.ps1`: initializes local config for this clone.
- `scripts/Archive-Local.ps1`: archive creation (encrypted only when password provided).
- `scripts/Upload-Rclone.ps1`: upload archives to rclone remotes.
- `scripts/Get-PasswordFromBitwarden.ps1`: retrieves archive password from Bitwarden CLI.
- `scripts/Common.ps1`: shared helpers.

## Prerequisites

- `7z` (7-Zip) available in `PATH` or standard install path.
- `rclone` in `PATH` when `BackupLocation` uses a remote format like `name:path`.
- `bw` (Bitwarden CLI) in `PATH` when `PasswordManager` is set to `Bitwarden`.

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

Non-interactive with custom nested destination folder:

```powershell
pwsh -File .\Run.ps1 -NonInteractive -DestinationName "my-custom-name-I-wish"
```

Non-interactive with archive at destination root (no nested folder):

```powershell
pwsh -File .\Run.ps1 -NonInteractive -DestinationName ""
```

Non-interactive with custom archive naming expression:

```powershell
pwsh -File .\Run.ps1 -NonInteractive -NamePattern "backup-{DestinationName}-{Now()}"
```

Non-interactive using Bitwarden password manager:

```powershell
pwsh -File .\Run.ps1 -NonInteractive -Encrypt -PasswordManager "Bitwarden"
```

Unattended run with explicit values:

```powershell
$pw = Read-Host "Archive password" -AsSecureString
pwsh -File .\Run.ps1 -NonInteractive -SourcePath "S:\" -BackupLocation "D:\Backups" -ExcludePattern "[[]no-sync[]]*" -Encrypt -Password $pw
```

## Extending Password Managers

When adding support for another password manager, keep the behavior and safety model consistent:

- Add a dedicated provider script under `scripts/` (for example `scripts/Get-PasswordFrom<Provider>.ps1`).
- Keep provider-specific config under `PasswordManagers.<Provider>` in `backup.config.json`.
- `Run.ps1` exports `PasswordManagers` config to process environment variables using the pattern `BACKMEUP_PM_<PROVIDER>_<KEY...>` and calls provider scripts by convention (`scripts/Get-PasswordFrom<Provider>.ps1`).

Key requirements:

- Non-interactive behavior:
  - In `-NonInteractive`, provider retrieval must never rely on interactive prompts.
  - If provider auth/unlock/login is missing, fail fast with a clear actionable error.
- Secret handling:
  - Never print, log, or include plaintext passwords in exceptions.
  - Return passwords as `SecureString` to `Run.ps1`.
  - Clear temporary plaintext variables as soon as possible.
- Precedence and flow:
  - Preserve precedence: explicit `-Password` wins over provider retrieval.
  - Preserve interactive fallback behavior when manager retrieval fails.
- Provider UX:
  - Keep errors specific to the provider and required setup state.
  - Validate required provider values (for example from env vars) before attempting retrieval.

Recommended checklist:

- Add provider script in `scripts/`.
- Add config defaults in `Initialize.ps1` and sample config docs.
- Add provider option handling in `Run.ps1`.
- Add README examples and prerequisites for the provider CLI/tooling.
- Validate both interactive and `-NonInteractive` paths.
