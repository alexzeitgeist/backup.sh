# Prototype Backup How-To

## Overview
This guide walks through the refreshed `prototype/backup.sh` workflow so you can run encrypted, verifiable backups with fewer ad-hoc flags. The prototype keeps every feature of `backup.sh`, adds safer defaults, and introduces configuration-driven modes. Follow the steps below the first time, then rely on the Quick Start section for daily jobs.

## Requirements
- Local tools: `bash`, `ssh`, `tar`, `zstd`, `gpg`, `sha256sum`, `shfmt`, `shellcheck`.
- Remote host: passwordless SSH plus `tar`, `sudo` (optional when running as root).
- Permissions: config files must be `chmod 600` or stricter; the script refuses group/world-writable configs.

## Quick Start
```bash
# Dry run to inspect the plan
prototype/backup.sh --preview user@host

# Encrypted full backup (defaults plus config)
prototype/backup.sh --encrypt --recipient KEYID user@host

# Home-mode backup with explicit label
prototype/backup.sh --mode home --label nightly user@host
```
Use `--compat` (or `BACKUPSH_COMPAT=1`) if you need the legacy behavior where positional paths act as excludes instead of includes.

## Common Command Patterns
```bash
# Custom include-only run for /etc and /var/www with encryption + checksum
prototype/backup.sh --include-only --include /etc --include /var/www --encrypt --recipient OPS user@host

# Legacy-style excludes (compat mode) with the legacy literal marker (-f)
prototype/backup.sh --compat user@host -f /etc/fstab /home /var/log

# Use a specific config file and skip checksum generation
prototype/backup.sh --config ~/.config/backupsh/profiles/db.conf --skip-checksum user@dbhost

# Provide SSH port and control options via repeated --ssh-option
prototype/backup.sh --ssh-option -p --ssh-option 2222 --ssh-option -o --ssh-option "StrictHostKeyChecking no" user@host

# Preview a custom mode run and ensure checksum is kept
prototype/backup.sh --mode custom --include /srv/data --exclude /srv/data/tmp --preview user@storage

# Passphrase-based symmetric encryption, reading from a file
prototype/backup.sh --passphrase-file ~/.secrets/backup.pass user@host /home/alex /srv/projects

# Skip remote root probing when you know tar can run as the SSH user
prototype/backup.sh --skip-root-check --mode home user@host

# Run with explicit output directory and label for staging
prototype/backup.sh --output-dir /mnt/backups --label staging user@host

# Combine preview + compat to double-check legacy automation before execution
prototype/backup.sh --compat --preview user@host /var/www /etc

# Verify archive readability right after creation
prototype/backup.sh --mode home --verify user@host
```

## Step-by-Step Workflow
1. **Copy the script** – Keep `prototype/backup.sh` alongside the legacy `backup.sh` so you can switch back instantly if needed.
2. **Create a config** – Copy `prototype/config.example` to `~/.config/backupsh/config`, tighten permissions (`chmod 600`), and edit any `DEFAULT_*` values you want. CLI flags always override config defaults.
3. **Choose a mode** – `full` (entire filesystem with default excludes), `home` (include `/home` by default), or `custom` (requires `--include`/`--exclude`). Positional paths automatically switch to include-only mode unless `--compat` is enabled.
4. **Preview before running** – `--preview` prints the resolved host, includes/excludes, encryption settings, output path, and config file in use. This is safe to run repeatedly.
5. **Run the backup** – The script handles SSH sudo detection, streams `tar` output through `zstd`, and optionally encrypts with GPG (recipient or passphrase). Add `--verify` when you want the script to immediately decompress (and decrypt) the finished archive to confirm it is readable.
6. **Review the report** – Each backup writes `<archive>.txt` with host, mode, include/exclude sets, encryption status, checksum, verification result, and an explanation if checksum generation was skipped. Follow the report’s `Checksum note` to re-run `sha256sum` after copying archives.

## Configuration Cheatsheet
- `DEFAULT_INCLUDE_PATHS`, `DEFAULT_EXCLUDE_PATTERNS`, `DEFAULT_OUTPUT_DIR`, `DEFAULT_LABEL`, and `DEFAULT_SSH_OPTIONS` remove the need for repetitive flags.
- `DEFAULT_COMPAT_MODE="yes"` keeps positional paths behaving like the legacy script until you intentionally migrate.
- Per-run overrides: `--config /path/to/file`, `BACKUPSH_CONFIG=/tmp/custom.conf`, or `BACKUPSH_COMPAT=1`.

## Options & Arguments
- `user@host` *(required positional)* – Remote SSH target; the username determines whether sudo is needed.
- `paths ...` *(optional positional)* – Additional paths. By default they trigger include-only mode. With `--compat` (or `DEFAULT_COMPAT_MODE="yes"`), they behave like the legacy excludes list, and `-f` marks the next path as a literal file.
- `--mode, -m {full|home|custom}` – Preset include/exclude plans; `custom` requires explicit `--include`/`--exclude`.
- `--include PATH` – Repeatable include list; automatically enables include-only mode.
- `--exclude PATH` – Repeatable exclude list used by `full`/`custom` modes.
- `--include-only, -i` – Legacy toggle forcing include-only behavior even without positional paths.
- `--one-file-system, -x` – Passes `--one-file-system` to `tar` so the backup doesn’t cross mountpoints.
- `--output-dir DIR` – Where archives and reports are written (defaults to config or current directory).
- `--label LABEL` – Appended to the archive filename (e.g., `nightly`, `pre-upgrade`).
- `--encrypt, -e` – Enables GPG encryption; also implied by `--recipient` or `--passphrase`.
- `--recipient, -r KEYID` – Recipient-based encryption (recommended); fails fast if the public key is missing.
- `--passphrase, -p PASS` – Symmetric encryption using the supplied passphrase.
- `--passphrase-file FILE` – Read the passphrase from a file or stdin (`-`).
- `--skip-checksum, -s` – Skip the SHA-256 calculation (report suggests how to run it later).
- `--continue-on-change, -c` – Do not abort when `tar` returns exit code 1 because files changed mid-backup.
- `--skip-root-check, -n` – Skip the remote sudo/root capability probe (use only when confident `tar` can run unprivileged).
- `--preview` – Print the resolved plan (host, includes/excludes, output file, encryption) and exit without touching the remote host.
- `--verify` – After the backup completes, decompress (and decrypt if needed) the archive and list it with `tar -t` to confirm readability.
- `--ssh-option TOKEN` – Repeatable; each invocation passes an additional token to the SSH command (e.g., `--ssh-option -p --ssh-option 2222`).
- `--ssh-extra STRING` – Legacy string that is split on spaces and appended to the SSH command.
- `--config FILE` – Source an explicit config file before parsing CLI arguments.
- `--compat / --no-compat` – Toggle legacy positional-path semantics for the current run (environment variable `BACKUPSH_COMPAT` mirrors this).
- `--help, -h` – Display the built-in usage guide.

## Safety & Verification
- **Root detection**: The script checks remote root access; add `--skip-root-check` (alias `-n`) only when you are certain `tar` can run without sudo.
- **Preview + `--mode` sanity**: The script errors if you combine `--mode full` with includes, preventing partial backups by mistake.
- **Checksums & verification**: By default a SHA-256 hash is generated. When skipping checksums (`--skip-checksum` / `-s`), the report clearly states how to compute one later. Add `--verify` to stream the final archive back through `zstd`/`tar -t` so you know it can be read before leaving the terminal.
- **Encryption**: `--recipient` (alias `-r`) enables recipient-based GPG; `--passphrase` (alias `-p`) or `--passphrase-file` handles symmetric mode. Passphrases read from files strip trailing newlines to match interactive entry.

## Compatibility Tips
- `--include-only` (alias `-i`) mirrors the old “only backup these paths” switch.
- `-f` (when `--compat` or `DEFAULT_COMPAT_MODE="yes"`) treats the next positional path as a literal file instead of appending `/*`.
- Use `--no-compat` (or `BACKUPSH_COMPAT=0`) to return to the modern include-only default once scripts are updated.

## Developer Commands
Inside the `prototype/` folder:
```bash
make fmt        # shfmt -w prototype/backup.sh
make fmt-check  # display formatting diff
make lint       # shellcheck -x prototype/backup.sh
make check      # bash -n prototype/backup.sh
make ci         # run fmt-check + lint + check
```
Run `make ci` before opening a PR to catch formatting and lint issues early.
