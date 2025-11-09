# Prototype Backup UX Refresh

## Goals
- Keep every existing capability of `backup.sh` while reducing the number of flags a person must remember.
- Mirror other mature CLIs (borg, restic, aws) by separating persistent defaults (config) from ad-hoc overrides (CLI).
- Provide confidence before a long-running backup starts (preview + plan summary).

## Key Changes
1. **Config Loader** – Sources the first available file from `--config`, `$BACKUPSH_CONFIG`, `$XDG_CONFIG_HOME/backupsh/config`, `~/.config/backupsh/config`, or `~/.backupshrc`. Any variable defined there (e.g., `DEFAULT_INCLUDE_PATHS`, `DEFAULT_SSH_OPTIONS`) becomes the baseline, but CLI flags still override per-run. This keeps commands short for habitual backups without hiding advanced switches.
2. **Modes + Includes** – Added a `--mode` flag (`full`, `home`, `custom`) plus clearer `--include/--exclude` semantics. Positional paths default to include-only (the same outcome as `--include-only`, which still has a `-i` alias), but `--compat` or `BACKUPSH_COMPAT=1` restores the legacy behavior where they become excludes and `-f` marks literal files.
3. **Plan Summary + Preview** – Every run prints host, mode, include/exclude sets, encryption status, and output path before work begins. `--preview` surfaces the same information without touching the remote host, acting as a dry-run sanity check.
4. **SSH Options as Arrays** – Instead of free-form strings, SSH tweaks live in `DEFAULT_SSH_OPTIONS` or repeated `--ssh-option` flags, so quoting is explicit and safer. The legacy `--ssh-extra` flag maps to the new system for familiarity.

## Config Example
See `prototype/config.example` for a drop-in file. Each variable matches the `DEFAULT_*` names in the script (including `DEFAULT_COMPAT_MODE`). Arrays let contributors express multiple include paths, exclude patterns, or SSH options cleanly.

## Migration Tips
- Drop `prototype/backup.sh` next to the current script and run `./prototype/backup.sh --preview user@host` to confirm paths before touching the remote machine.
- Move any recurring flags into `~/.config/backupsh/config`, ensure the file is `chmod 600`, and rely on the CLI only for one-off overrides.
- Need older semantics? Set `BACKUPSH_COMPAT=1` (or add `DEFAULT_COMPAT_MODE="yes"` to the config) so positional paths keep acting as excludes until you toggle the new workflow.
- The original `backup.sh` remains unchanged, so you can flip back instantly if the workflow needs more bake time.

## Profiles & Multi-Host Setups
- Keep multiple configs under `~/.config/backupsh/profiles/` and launch with `BACKUPSH_CONFIG=~/.config/backupsh/profiles/prod.conf ./prototype/backup.sh user@prod`
- For ad-hoc runs, pass `--config /path/to/config` directly; explicit paths beat env vars which beat the default discoverability order.

## Restore / Decryption Notes
- Restoring does not change: continue using the existing `restore.sh` or `prototype/restore.sh` workflow. Example: `./restore.sh -l host-20250101-0000.tar.zst.gpg` to inspect contents, `./restore.sh -r backup.gpg /tmp/restore` to extract with sudo.
- When encryption is enabled, the backup output filename gains `.gpg` just like today, so downstream tooling (restore, checksum compare) stays compatible.

## Legacy Compatibility Cheatsheet
- `--include-only` (alias `-i`) mirrors the old toggle that said “treat following paths as the include set.”
- `--compat` flips positional paths back to excludes and re-enables the legacy `-f` marker for literal paths. `--no-compat` or `BACKUPSH_COMPAT=0` switches to the new include-centric UX.
- Set `DEFAULT_COMPAT_MODE="yes"` inside the config for hosts that must stay on the legacy behavior until their automation is updated.

## Developer Commands
- Run `make -C prototype fmt` (or `cd prototype && make fmt`) to apply shfmt with the repo’s 2-space style.
- `make -C prototype lint` wraps shellcheck with `-x`, so sourced configs are resolved.
- `make -C prototype check` executes `bash -n` for quick syntax validation.
- `make -C prototype ci` chains `fmt-check`, `lint`, and `check`; it’s the quickest way to mirror CI locally.

## Open Questions / Next Steps
- Should modes be expanded (e.g., `db-only`, `webroot` presets) or should users rely solely on config profiles?
- Do we need a unified `profiles.d/` loader to mirror `ssh` host entries, or is a single config sufficient?
- Preview mode currently prints the plan; a future revision could also evaluate available disk space or dry-run tar via `--checkpoint` for added safety.
