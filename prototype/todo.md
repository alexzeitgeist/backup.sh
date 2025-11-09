# Prototype Assessment and TODO

## Summary Verdict
- Robustness: Significantly improved vs. original. Safer SSH command construction (no remote eval), config permission checks, stronger validation, and safer passphrase handling.
- Backward‑compatibility: Partial. A few CLI semantics differ (positional paths, missing `-i`, missing `-f`). Users relying on old patterns may be surprised.
- Everyday usability: Better. Quick Start examples, `--preview` + pre‑flight summary, and config defaults reduce cognitive load for routine backups.

## What’s More Robust Now
- SSH command is built as arrays and serialized, removing quoting/injection pitfalls from remote `eval`.
- Config files validated for unsafe permissions before `source`.
- Clearer validation: output dir writability, required paths for modes, and recipient/key checks.
- Passphrase handling supports stdin and avoids trailing newline issues.
- Array‑based SSH options (`--ssh-option`/`--ssh-extra`) reduce quoting bugs.

## Where Compatibility Diverges (Risks)
- Positional paths: Original interpreted extra paths as excludes (unless `-i`). Prototype interprets them as includes (include‑only). Breaking change for some users.
- Flag gaps: Original had `-i` (include‑only) and `-f` (treat next path as a file); prototype currently lacks both.
- Minor rename: Continue behavior is exposed as `--continue-on-change` (behavior equivalent, naming differs).

## Usability Impact (Day‑to‑Day)
- First‑run simplicity: Helpful Quick Start and embedded config example; less time reading terse short‑flag docs.
- Confidence: Pre‑flight “Plan Summary” and `--preview` prevent accidental long runs with the wrong options.
- Repeatability: Config absorbs routine choices (output dir, excludes, encryption, SSH opts) so daily commands are shorter and clearer.
- Small fix recommended: In `--mode home`, include `/home` (not `/home/*`) so recursive tar works without relying on shell glob expansion.

## High‑Priority Follow‑Ups (Back‑Compat + Polish)
- [ ] Add `-i` as an alias to `--include-only` (no behavior change, just compatibility).
- [ ] Reintroduce `-f` (one‑shot toggle) so the next path is treated as an exact file path for exclude in `full/custom` modes. Keep `--exclude` as the modern explicit form.
- [ ] Add `--compat` (or env `BACKUPSH_COMPAT=1`) to restore original semantics: positional paths → excludes unless include‑only is set.
- [ ] Change home mode default include to `/home` (not `/home/*`).
- [ ] Align help/README/config.example with the above (document `-i`, `-f`, and `--compat`).
- [ ] Extend `report` to state why checksum is skipped (already done) and optionally print verification advice.
- [ ] Add simple Makefile targets for the prototype (`fmt`, `lint`, `check`, `ci`) mirroring the repo root.

## Optional Enhancements (Nice‑to‑Have)
- [ ] Profiles: Allow `~/.config/backupsh/profiles.d/*.conf` and `--profile NAME` to source one.
- [ ] `--verify` flag: re‑read the just‑created archive to confirm readability and checksum.
- [ ] Disk‑space precheck in `--preview` (local and remote optional).
- [ ] `--output-dir` retention: `--keep N` prune older backups on success.

## Validation Plan
- Syntax & lint: `bash -n prototype/backup.sh` and `shellcheck -x prototype/backup.sh`.
- Config precedence: test `--config`, `BACKUPSH_CONFIG`, XDG, and default locations with `--preview`.
- Mode interaction: `--mode full --include /path` should error (by design); `--mode custom` requires includes or excludes.
- SSH options: `--ssh-option -p --ssh-option 2222 --preview host` should show the correct plan.
- Back‑compat: with `--compat`, positional paths should populate excludes (no include‑only) to mirror the original.

## Acceptance Criteria
- All high‑priority follow‑ups implemented; `--preview` reflects the intended behavior in each scenario.
- No regression in core features (encryption modes, checksum, sudo fallback, excludes).
- `shellcheck` clean; quick smoke tests demonstrate config precedence and mode logic.
- README/help reflect the exact CLI surface and contain copy‑pasteable examples for common cases.

## Risks & Mitigations
- Behavior changes surprising users → Provide `--compat` flag + migration notes in help/README; keep original script intact during transition.
- Config sourcing trust boundary → Keep strict permission checks and document `chmod 600` for configs.
- SSH option parsing edge cases → Prefer repeated `--ssh-option` over `--ssh-extra`; keep `--ssh-extra` as escape hatch.

---
Status: Most robustness upgrades are already implemented in the prototype. The items above close the compatibility gap and finalize the UX improvements without sacrificing functionality.
