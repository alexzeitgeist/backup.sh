#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# Defaults; config files can override these variables/arrays.
declare -a DEFAULT_EXCLUDE_PATTERNS=(
  "/dev/*"
  "/proc/*"
  "/sys/*"
  "/run/*"
  "/tmp/*"
  "/var/log/*"
)
declare -a DEFAULT_INCLUDE_PATHS=()
declare -a DEFAULT_SSH_OPTIONS=()
DEFAULT_MODE="full"
DEFAULT_OUTPUT_DIR="$PWD"
DEFAULT_LABEL=""
DEFAULT_RECIPIENT=""
DEFAULT_ENCRYPT="no"
DEFAULT_ONE_FILE_SYSTEM="no"
DEFAULT_SKIP_CHECKSUM="no"
DEFAULT_CONTINUE_ON_CHANGE="no"
DEFAULT_COMPAT_MODE="no"
DEFAULT_SKIP_ROOT_CHECK="no"
DEFAULT_VERIFY="no"

CONFIG_FILE_USED=""

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

normalize_bool() {
  local value="${1:-}"
  case "${value,,}" in
    yes | true | 1 | on)
      printf 'yes\n'
      ;;
    *)
      printf 'no\n'
      ;;
  esac
}

ensure_secure_config() {
  local path="$1"
  local perm=""
  if perm=$(stat -c '%a' "$path" 2>/dev/null); then
    :
  elif perm=$(stat -f '%Lp' "$path" 2>/dev/null); then
    :
  else
    return
  fi
  local len=${#perm}
  local group=""
  local other=""
  if ((len >= 2)); then
    group=${perm:len-2:1}
  fi
  if ((len >= 1)); then
    other=${perm:len-1:1}
  fi
  if [[ $group =~ [2367] || $other =~ [2367] ]]; then
    die "Config file $path is writable by group/others; refusing to load"
  fi
}

load_config() {
  local explicit="$1"
  local search_paths=()
  if [[ -n "$explicit" ]]; then
    search_paths+=("$explicit")
  fi
  if [[ -n "${BACKUPSH_CONFIG:-}" ]]; then
    search_paths+=("$BACKUPSH_CONFIG")
  fi
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    search_paths+=("$XDG_CONFIG_HOME/backupsh/config")
  fi
  search_paths+=("$HOME/.config/backupsh/config" "$HOME/.backupshrc")
  for path in "${search_paths[@]}"; do
    if [[ -f "$path" ]]; then
      ensure_secure_config "$path"
      # shellcheck disable=SC1090
      source "$path"
      CONFIG_FILE_USED="$path"
      return 0
    fi
  done
  return 0
}

show_help() {
  cat <<'EOF'
Usage: backup.sh [options] user@host [paths ...]

Quick Start
  backup.sh user@host                 # full system backup with default excludes
  backup.sh --mode home user@host     # home directories only
  backup.sh --encrypt -r KEY host     # encrypted full backup

Key Options
  --mode MODE, -m            full | home | custom (defaults to config)
  --include PATH             repeatable path to include (implies include-only)
  --exclude PATH             repeatable path to exclude (for full/custom)
  --include-only, -i         legacy toggle to force include-only mode
  --output-dir DIR           directory for archives (default: config or cwd)
  --label LABEL              suffix for filenames (e.g. nightly)
  --encrypt, -e              enable encryption (config can default to yes)
  --recipient KEY, -r        GPG recipient; enables encryption automatically
  --passphrase PASS, -p      symmetric encryption with given passphrase
  --passphrase-file FILE     read passphrase from file/stdin (use - for stdin)
  --skip-checksum, -s        skip SHA-256 calculation
  --continue-on-change, -c   do not abort when tar returns 1 (files changed)
  --skip-root-check, -n      assume remote tar can run without sudo/root
  --no-skip-root-check       force the remote root check even if skipped by default
  --preview                  print the resolved plan then exit
  --verify / --no-verify     decompress (and decrypt) the archive post-run to confirm readability, or disable when defaulted on
  --ssh-option OPT           repeatable, pass raw option to ssh (e.g. "-p" "2222")
  --ssh-extra STRING         alias for --ssh-option
  --config FILE              explicit config file (sourced bash)
  --compat / --no-compat     toggle legacy positional-path semantics (or set BACKUPSH_COMPAT)
  --help, -h                 show extended help

Config File (~/.config/backupsh/config)
  DEFAULT_MODE="home"
  DEFAULT_INCLUDE_PATHS=("/home/user" "/etc/fstab")
  DEFAULT_OUTPUT_DIR="$HOME/backups"
  DEFAULT_RECIPIENT="KEYID"
  DEFAULT_ENCRYPT="yes"
  DEFAULT_ONE_FILE_SYSTEM="yes"
  DEFAULT_SSH_OPTIONS=("-p" "2222")
  DEFAULT_SKIP_CHECKSUM="yes"

Plan Summary
  The script prints a pre-flight summary (host, mode, includes/excludes, encryption,
  output file) before running tar. Use --preview to view this summary without writing.

Compatibility Notes
  Positional paths default to "include-only" mode. Enable --compat (or set
  BACKUPSH_COMPAT=1) to restore the legacy behavior where positional paths become
  excludes unless --include-only (-i) is provided. When --compat is on, the legacy "-f" marker can
  precede a path to treat it as a single file rather than appending /*.
EOF
}

cleanup() {
  local file="$1"
  if [[ -n "$file" && -f "$file" ]]; then
    rm -f "$file"
  fi
}

key_exists() {
  local recipient="$1"
  if ! gpg --list-keys "$recipient" >/dev/null 2>&1; then
    die "Recipient key $recipient not found"
  fi
}

check_root_access() {
  local host="$1"
  local -n ssh_opts_ref=$2
  local -a cmd=(ssh)
  if [[ ${#ssh_opts_ref[@]} -gt 0 ]]; then
    cmd+=("${ssh_opts_ref[@]}")
  fi
  cmd+=("$host")
  # shellcheck disable=SC2016  # remote shell should expand $(id -u)
  if "${cmd[@]}" 'test "$(id -u)" -eq 0'; then
    echo "yes"
    return 0
  fi
  # shellcheck disable=SC2016
  if "${cmd[@]}" 'command -v sudo >/dev/null 2>&1 && sudo -n id -u >/dev/null 2>&1'; then
    echo "no"
    return 0
  fi
  die "Need root or passwordless sudo on remote host"
}

print_summary() {
  local host="$1"
  local mode="$2"
  local include_only="$3"
  local -n includes_ref=$4
  local -n excludes_ref=$5
  local encrypt="$6"
  local recipient="$7"
  local output_file="$8"
  local includes_display="(none)"
  local excludes_display="(none)"
  if [[ ${#includes_ref[@]} -gt 0 ]]; then
    includes_display="${includes_ref[*]}"
  fi
  if [[ ${#excludes_ref[@]} -gt 0 ]]; then
    excludes_display="${excludes_ref[*]}"
  fi
  printf '\nPlan Summary\n------------\n'
  printf 'Host:          %s\n' "$host"
  printf 'Mode:          %s\n' "$mode"
  printf 'Include only:  %s\n' "$include_only"
  printf 'Includes:      %s\n' "$includes_display"
  printf 'Excludes:      %s\n' "$excludes_display"
  printf 'Encryption:    %s\n' "$encrypt"
  if [[ "$encrypt" == "yes" && -n "$recipient" ]]; then
    printf 'Recipient:     %s\n' "$recipient"
  fi
  printf 'Output file:   %s\n\n' "$output_file"
}

run_remote_command() {
  local host="$1"
  shift
  local -a ssh_cmd=(ssh)
  if [[ ${#ssh_options[@]} -gt 0 ]]; then
    ssh_cmd+=("${ssh_options[@]}")
  fi
  ssh_cmd+=("$host")
  local command_string
  command_string=$(printf '%q ' "$@")
  "${ssh_cmd[@]}" "$command_string"
}

verify_archive() {
  local file="$1"
  if [[ "$encrypt" == "yes" ]]; then
    if [[ -n "$recipient" ]]; then
      gpg --batch --quiet --decrypt "$file" | zstd -d --stdout | tar -tf - >/dev/null
    else
      if [[ -z "$passphrase" ]]; then
        die "--verify with symmetric encryption requires --passphrase or --passphrase-file"
      fi
      printf '%s' "$passphrase" \
        | gpg --batch --quiet --yes --passphrase-fd 0 --decrypt "$file" \
        | zstd -d --stdout \
        | tar -tf - >/dev/null
    fi
  else
    zstd -d --stdout "$file" | tar -tf - >/dev/null
  fi
}

apply_positional_args() {
  local token path
  if [[ ${#positional_args[@]} -eq 0 ]]; then
    return
  fi

  if [[ "$include_only" == "yes" ]]; then
    local added="no"
    for token in "${positional_args[@]}"; do
      if [[ "$token" == "-f" ]]; then
        continue
      fi
      include_paths+=("${token%/}")
      added="yes"
    done
    if [[ "$added" == "yes" ]]; then
      include_paths_specified="yes"
    fi
    return
  fi

  if [[ "$compat_mode" == "yes" ]]; then
    local next_literal="no"
    for token in "${positional_args[@]}"; do
      if [[ "$token" == "-f" ]]; then
        next_literal="yes"
        continue
      fi
      path="${token%/}"
      if [[ -z "$path" ]]; then
        continue
      fi
      if [[ "$next_literal" == "yes" ]]; then
        next_literal="no"
      else
        if [[ "$path" != *'*'* ]]; then
          path+="/*"
        fi
      fi
      exclude_paths+=("$path")
    done
    return
  fi

  local added="no"
  for token in "${positional_args[@]}"; do
    if [[ "$token" == "-f" ]]; then
      die "-f is only supported with --compat or BACKUPSH_COMPAT=1"
    fi
    include_paths+=("${token%/}")
    added="yes"
  done
  if [[ "$added" == "yes" ]]; then
    include_paths_specified="yes"
    include_only="yes"
  fi
}

# -----------------
# Argument handling
# -----------------

orig_args=("$@")
config_override=""
filtered_args=()
i=0
while ((i < ${#orig_args[@]})); do
  token="${orig_args[i]}"
  case "$token" in
    --config)
      ((i++))
      ((i < ${#orig_args[@]})) || die "--config requires a value"
      config_override="${orig_args[i]}"
      ;;
    --config=*)
      config_override="${token#*=}"
      ;;
    --)
      filtered_args+=("${orig_args[@]:i}")
      break
      ;;
    *)
      filtered_args+=("$token")
      ;;
  esac
  ((i++))
done

if [[ ${#filtered_args[@]} -gt 0 ]]; then
  set -- "${filtered_args[@]}"
else
  set --
fi

load_config "$config_override"

mode="${DEFAULT_MODE:-full}"
one_file_system=$(normalize_bool "${DEFAULT_ONE_FILE_SYSTEM:-no}")
output_dir="${DEFAULT_OUTPUT_DIR:-$PWD}"
label="${DEFAULT_LABEL:-}"
encrypt=$(normalize_bool "${DEFAULT_ENCRYPT:-no}")
recipient="${DEFAULT_RECIPIENT:-}"
passphrase=""
passphrase_file=""
skip_checksum=$(normalize_bool "${DEFAULT_SKIP_CHECKSUM:-no}")
continue_on_change=$(normalize_bool "${DEFAULT_CONTINUE_ON_CHANGE:-no}")
skip_root_check=$(normalize_bool "${DEFAULT_SKIP_ROOT_CHECK:-no}")
preview="no"
verify=$(normalize_bool "${DEFAULT_VERIFY:-no}")
compat_mode=$(normalize_bool "${DEFAULT_COMPAT_MODE:-no}")
if [[ -n "${BACKUPSH_COMPAT:-}" ]]; then
  compat_mode=$(normalize_bool "${BACKUPSH_COMPAT:-}")
fi
declare -a include_paths=()
if [[ ${#DEFAULT_INCLUDE_PATHS[@]} -gt 0 ]]; then
  include_paths=("${DEFAULT_INCLUDE_PATHS[@]}")
fi
declare -a exclude_paths=()
if [[ ${#DEFAULT_EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
  exclude_paths=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
fi
include_only="no"
include_paths_specified="no"
declare -a positional_args=()
declare -a ssh_options=()
if [[ ${#DEFAULT_SSH_OPTIONS[@]} -gt 0 ]]; then
  ssh_options=("${DEFAULT_SSH_OPTIONS[@]}")
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m | --mode)
      mode="$2"
      shift 2
      ;;
    --include)
      [[ $# -ge 2 ]] || die "--include requires a path"
      include_paths+=("${2%/}")
      include_paths_specified="yes"
      include_only="yes"
      shift 2
      ;;
    --exclude)
      exclude_paths+=("${2%/}")
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --label)
      label="$2"
      shift 2
      ;;
    -e | --encrypt)
      encrypt="yes"
      shift 1
      ;;
    -r | --recipient)
      recipient="$2"
      encrypt="yes"
      shift 2
      ;;
    -p | --passphrase)
      passphrase="$2"
      encrypt="yes"
      shift 2
      ;;
    --passphrase-file)
      passphrase_file="$2"
      encrypt="yes"
      shift 2
      ;;
    -i | --include-only)
      include_only="yes"
      include_paths_specified="yes"
      shift 1
      ;;
    -x | --one-file-system)
      one_file_system="yes"
      shift 1
      ;;
    -c | --continue-on-change)
      continue_on_change="yes"
      shift 1
      ;;
    -s | --skip-checksum)
      skip_checksum="yes"
      shift 1
      ;;
    -n | --skip-root-check)
      skip_root_check="yes"
      shift 1
      ;;
    --no-skip-root-check)
      skip_root_check="no"
      shift 1
      ;;
    --preview)
      preview="yes"
      shift 1
      ;;
    --verify)
      verify="yes"
      shift 1
      ;;
    --no-verify)
      verify="no"
      shift 1
      ;;
    --compat)
      compat_mode="yes"
      shift 1
      ;;
    --no-compat)
      compat_mode="no"
      shift 1
      ;;
    --ssh-option)
      [[ $# -ge 2 ]] || die "--ssh-option requires a value"
      ssh_options+=("$2")
      shift 2
      ;;
    --ssh-extra)
      [[ $# -ge 2 ]] || die "--ssh-extra requires a value"
      extra_raw="$2"
      IFS=' ' read -r -a extra_parts <<<"$extra_raw"
      if [[ ${#extra_parts[@]} -eq 0 ]]; then
        die "--ssh-extra needs at least one token"
      fi
      ssh_options+=("${extra_parts[@]}")
      shift 2
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ -z "${host:-}" ]]; then
          host="$1"
        else
          positional_args+=("$1")
        fi
        shift
      done
      ;;
    -*)
      if [[ -n "${host:-}" ]]; then
        positional_args+=("$1")
        shift 1
        continue
      fi
      die "Unknown option $1"
      ;;
    *)
      if [[ -z "${host:-}" ]]; then
        host="$1"
      else
        positional_args+=("$1")
      fi
      shift 1
      ;;
  esac
done

if [[ -z "${host:-}" ]]; then
  die "Specify remote host (user@host)"
fi

apply_positional_args

case "$mode" in
  full)
    if [[ "$include_paths_specified" == "yes" ]]; then
      die "Mode full cannot be combined with include paths; omit --mode full or use --mode custom"
    fi
    include_only="no"
    ;;
  home)
    include_only="yes"
    if [[ ${#include_paths[@]} -eq 0 ]]; then
      include_paths=("/home")
    fi
    ;;
  custom)
    if [[ ${#include_paths[@]} -eq 0 && ${#exclude_paths[@]} -eq 0 ]]; then
      die "Mode custom requires --include or --exclude paths"
    fi
    ;;
  *)
    die "Unknown mode $mode"
    ;;
esac

if [[ "$include_only" == "yes" && ${#include_paths[@]} -eq 0 ]]; then
  die "Include-only mode selected but no include paths found"
fi

if [[ "$encrypt" == "yes" && -n "$recipient" ]]; then
  key_exists "$recipient"
fi

remote_host="$host"
remote_name="${host#*@}"
timestamp="$(date +%Y%m%d-%H%M%S)"
base_name="${remote_name}-${timestamp}"
if [[ -n "$label" ]]; then
  base_name+="-${label}"
fi
mkdir -p "$output_dir"
[[ -w "$output_dir" ]] || die "Output directory $output_dir is not writable"
backup_file="$output_dir/${base_name}.tar.zst"

if [[ "$preview" == "yes" ]]; then
  print_summary "$host" "$mode" "$include_only" include_paths exclude_paths "$encrypt" "$recipient" "$backup_file"
  exit 0
fi

if [[ "$skip_root_check" != "yes" ]]; then
  is_root="$(check_root_access "$remote_host" ssh_options)"
else
  is_root="unknown"
fi

use_sudo=""
if [[ "$is_root" == "no" ]]; then
  use_sudo="sudo"
fi
if [[ "$is_root" == "unknown" ]]; then
  use_sudo=""
fi

print_summary "$host" "$mode" "$include_only" include_paths exclude_paths "$encrypt" "$recipient" "$backup_file"

trap 'cleanup "$backup_file"' INT TERM

start=$(date +%s)
exit_status=""
one_fs_flag=""
if [[ "$one_file_system" == "yes" ]]; then
  one_fs_flag="--one-file-system"
fi

if [[ "$include_only" == "yes" ]]; then
  if [[ ${#include_paths[@]} -eq 0 ]]; then
    die "Include mode selected but no paths provided"
  fi
  remote_cmd=()
  if [[ -n "$use_sudo" ]]; then
    remote_cmd+=("$use_sudo")
  fi
  remote_cmd+=(tar)
  if [[ -n "$one_fs_flag" ]]; then
    remote_cmd+=("$one_fs_flag")
  fi
  remote_cmd+=(-cvf -)
  remote_cmd+=("${include_paths[@]}")
  run_remote_command "$remote_host" "${remote_cmd[@]}" | zstd -T0 -o "$backup_file" || exit_status=$?
else
  remote_cmd=()
  if [[ -n "$use_sudo" ]]; then
    remote_cmd+=("$use_sudo")
  fi
  remote_cmd+=(tar)
  if [[ -n "$one_fs_flag" ]]; then
    remote_cmd+=("$one_fs_flag")
  fi
  remote_cmd+=(-cvf -)
  if [[ ${#exclude_paths[@]} -gt 0 ]]; then
    for pattern in "${exclude_paths[@]}"; do
      remote_cmd+=("--exclude=$pattern")
    done
  fi
  remote_cmd+=("/")
  run_remote_command "$remote_host" "${remote_cmd[@]}" | zstd -T0 -o "$backup_file" || exit_status=$?
fi

if [[ -n "$exit_status" ]]; then
  if [[ "$exit_status" -eq 1 ]]; then
    log "tar reported changed files"
    if [[ "$continue_on_change" != "yes" ]]; then
      die "Aborting due to tar exit 1"
    fi
  else
    die "tar exited with status $exit_status"
  fi
fi

if [[ "$encrypt" == "yes" ]]; then
  if [[ -n "$recipient" ]]; then
    gpg --yes --batch -z 0 --recipient="$recipient" --output "${backup_file}.gpg" --encrypt "$backup_file"
    rm "$backup_file"
    backup_file+=".gpg"
  else
    if [[ -n "$passphrase_file" ]]; then
      if [[ "$passphrase_file" == "-" ]]; then
        IFS= read -r passphrase
      else
        [[ -f "$passphrase_file" ]] || die "Passphrase file $passphrase_file not found"
        IFS= read -r passphrase <"$passphrase_file"
      fi
    elif [[ -z "$passphrase" ]]; then
      printf 'Enter passphrase: '
      read -r -s passphrase
      printf '\nConfirm passphrase: '
      read -r -s verify
      printf '\n'
      [[ "$passphrase" == "$verify" ]] || die "Passphrases do not match"
    fi
    printf '%s' "$passphrase" | gpg --yes --batch -z 0 --passphrase-fd 0 --symmetric --output "${backup_file}.gpg" "$backup_file"
    rm "$backup_file"
    backup_file+=".gpg"
  fi
fi

verify_status="skipped (--verify not set)"
if [[ "$verify" == "yes" ]]; then
  log "Verifying archive integrity..."
  if verify_archive "$backup_file"; then
    verify_status="passed"
  else
    die "Verification failed for $backup_file"
  fi
fi

backup_file_size=$(du -sh "$backup_file" | cut -f1)
checksum="skipped (--skip-checksum)"
checksum_note="Skipped via --skip-checksum; run: sha256sum \"$backup_file\" > \"${backup_file}.sha256\" when ready."
if [[ "$skip_checksum" != "yes" ]]; then
  checksum=$(sha256sum "$backup_file" | cut -d' ' -f1)
  checksum_note="Re-run sha256sum \"$backup_file\" after copying to verify integrity."
fi
elapsed=$(($(date +%s) - start))

report_file="${backup_file%.*}.txt"
cat >"$report_file" <<EOF
BACKUP REPORT
Host:            $remote_host
Mode:            $mode
Include only:    $include_only
Includes:        ${include_paths[*]:-(defaults)}
Excludes:        ${exclude_paths[*]:-(none)}
Encryption:      $encrypt
Recipient:       $recipient
Output file:     $backup_file
File size:       $backup_file_size
Elapsed seconds: $elapsed
SHA256 Checksum: $checksum
Checksum note:   $checksum_note
Config file:     ${CONFIG_FILE_USED:-none}
Verification:    $verify_status
EOF

trap - INT TERM
log "Backup completed: $backup_file"
log "Report: $report_file"
