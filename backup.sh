#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# Capture the original command
original_command="$(basename "$0") $(
    IFS=" "
    echo "$*"
)"

# Displays help information.
display_help() {
    cat <<EOF
Usage: ${0} [-x] [-i] [-c] [-s] [-e] [-n] [-r recipient] [-p passphrase] host [[-f] path1] [[-f] path2] ...
Options:
   -x              Enable --one-file-system option for tar.
   -i              Only backup the given path(s).
   -c              Continue if tar returns 1 (files changed during archiving).
   -s              Skip SHA-256 checksum.
   -e              Enable PGP encryption.
   -n              Skip check for remote root privileges.
   -r recipient    Specify the recipient for PGP encryption.
   -p passphrase   Specify the passphrase for PGP encryption.
   host            user@hostname/IP of the remote server to backup.
   [-f] path       Path(s) to backup or exclude. Use -f before a path to treat it as a file. Multiple paths can be specified.
EOF
}

# Function to cleanup upon receiving SIGINT (Ctrl+C)
cleanup() {
    printf "Backup interrupted. Cleaning up...\n"
    rm -f "$backup_file"
    exit 1
}

# Trap SIGINT (Ctrl+C)
trap cleanup SIGINT

# Checks if GPG key exists.
key_exists() {
    if ! gpg --list-keys "$1" >/dev/null 2>&1; then
        echo "Recipient key not found."
        exit 1
    fi
}

# Checks for remote root access.
check_root_access() {
    # Check if we're root and store the result
    if ssh "$1" 'test "$(id -u)" -eq 0'; then
        is_root="yes"
        return 0
    fi
    # Not root, try sudo
    if ssh "$1" 'command -v sudo >/dev/null 2>&1 && sudo -n id -u >/dev/null 2>&1'; then
        is_root="no"
        return 0
    fi
    echo "Need either root access or sudo privileges on remote host."
    exit 1
}

# Variables
declare -a exclude_paths=("/dev/*" "/proc/*" "/sys/*" "/run/*" "/tmp/*" "/var/log/*")
declare -a include_paths=()
one_file_system=""
ignore_exclude=""
continue_on_tar_error=""
skip_checksum=""
encrypt=""
no_root_check=""
recipient=""
passphrase=""
is_root=""

# Parse options
while getopts ":xicsenr:p:h" opt; do
    case ${opt} in
    x)
        one_file_system="--one-file-system"
        ;;
    i)
        ignore_exclude="yes"
        ;;
    c)
        continue_on_tar_error="yes"
        ;;
    s)
        skip_checksum="yes"
        ;;
    e)
        encrypt="yes"
        ;;
    n)
        no_root_check="yes"
        ;;
    r)
        recipient="$OPTARG"
        encrypt="yes"
        ;;
    p)
        passphrase="$OPTARG"
        encrypt="yes"
        ;;
    h)
        display_help
        exit 0
        ;;
    \?)
        echo "Invalid option: $OPTARG" 1>&2
        display_help
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

# Check for the presence of the recipient's public key if PGP encryption is requested
if [[ "$encrypt" == "yes" && -n "$recipient" ]]; then
    key_exists "$recipient"
fi

# Check for remote host argument
if [[ -z "${1:-}" ]]; then
    echo "Specify a remote host."
    display_help
    exit 1
fi

host=$1
shift 1

# Check for remote root access if not disabled
if [[ "$no_root_check" != "yes" ]]; then
    check_root_access "$host"
fi

# Process paths (or files if -f was given)
is_file=false
for arg in "$@"; do
    if [[ "$arg" == "-f" ]]; then
        is_file=true
        continue
    fi

    path="${arg%/}" # Remove trailing slashes

    if [[ "$ignore_exclude" == "yes" ]]; then
        include_paths+=("$path")
    else
        if [[ "$is_file" == false ]]; then
            [[ "$path" != */'*' ]] && path="${path}/*"
        fi
        exclude_paths+=("$path")
    fi

    # Reset is_file flag for the next argument
    is_file=false
done

# Backup and measure time.
start=$(date +%s)
backup_file="$(echo "$host" | cut -d'@' -f2)_backup_${start}.tar.zst"

exit_status=""
use_sudo=""
[[ "$is_root" != "yes" ]] && use_sudo="sudo"

if [[ "$ignore_exclude" == "yes" ]]; then
    paths_str=$(printf '%q ' "${include_paths[@]}")
    # shellcheck disable=SC2029  # We want $use_sudo to expand on client side
    ssh "$host" "eval \"$use_sudo tar $one_file_system -cvf - $paths_str\"" | zstd -T0 -o "$backup_file" || exit_status=$?
else
    excludes_str=$(printf ' --exclude=%q' "${exclude_paths[@]}")
    # shellcheck disable=SC2029  # We want $use_sudo to expand on client side
    ssh "$host" "eval \"$use_sudo tar $one_file_system -cvf -$excludes_str /\"" | zstd -T0 -o "$backup_file" || exit_status=$?
fi

# Handle the exit status of tar
if [ -n "$exit_status" ]; then
    if [ $exit_status -eq 1 ]; then
        echo "tar returned 1. Some files were changed during archiving."
        if [ "$continue_on_tar_error" != "yes" ]; then
            kill -s SIGINT $$
        fi
    else
        # Handle other non-zero exit status if needed
        echo "An error occurred with exit status: $exit_status"
        kill -s SIGINT $$
    fi
fi

elapsed=$(($(date +%s) - start))

# Encrypt the backup file if encryption is enabled
if [[ "$encrypt" == "yes" ]]; then
    if [ -n "$recipient" ]; then
        gpg --yes --batch -z 0 --recipient="$recipient" --output "${backup_file}.gpg" --encrypt "$backup_file" && rm "$backup_file"
        backup_file="${backup_file}.gpg"
    else
        if [[ -z "$passphrase" ]]; then
            while true; do
                echo -n "Enter passphrase: "
                read -r -s passphrase
                echo
                echo -n "Re-enter passphrase: "
                read -r -s verify
                echo
                if [[ "$passphrase" == "$verify" ]]; then
                    break
                else
                    echo "Passphrases don't match. Try again."
                fi
            done
        fi
        echo "$passphrase" | gpg --yes --batch -z 0 --passphrase-fd 0 --symmetric --output "${backup_file}.gpg" "$backup_file" && rm "$backup_file"
        backup_file="${backup_file}.gpg"
    fi
fi

# Create backup info file
backup_file_size=$(du -sh "$backup_file" | cut -f1)
backup_sha256sum=$([[ "$skip_checksum" == "yes" ]] || sha256sum "$backup_file" | cut -d' ' -f1)
backup_info_file="${backup_file%.*}.txt"

{
    echo "======================================================="
    echo "                      BACKUP REPORT                    "
    echo "======================================================="
    echo
    echo "BACKUP SUMMARY"
    echo "--------------"
    echo "Hostname           : $(echo "$host" | cut -d'@' -f2)"
    echo "Backup File        : $backup_file"
    echo "File Size          : $backup_file_size"
    echo "Elapsed Time       : $elapsed seconds"
    echo "Date & Time        : $(date)"
    [[ "$skip_checksum" == "yes" ]] || echo "SHA-256 Checksum    : $backup_sha256sum"
    echo
    echo "BACKUP COMMAND"
    echo "--------------"
    echo "$original_command"
    echo
    echo "BACKUP OPTIONS"
    echo "--------------"
    echo "One File System    : $([ "$one_file_system" == "--one-file-system" ] && echo "Yes" || echo "No")"
    echo "Ignore Excludes    : $([ "$ignore_exclude" == "yes" ] && echo "Yes" || echo "No")"
    echo "Skip Checksum      : $([ "$skip_checksum" == "yes" ] && echo "Yes" || echo "No")"
    echo "Encryption         : $([ "$encrypt" == "yes" ] && echo "Yes" || echo "No")"
    echo "Skip Root Check    : $([ "$no_root_check" == "yes" ] && echo "Yes" || echo "No")"
    echo
    echo "BACKUP CONTENT"
    echo "--------------"
    if [[ "$ignore_exclude" == "yes" ]]; then
        echo "Included Paths:"
        for path in "${include_paths[@]}"; do
            echo "  - $path"
        done
    else
        echo "Excluded Paths:"
        for path in "${exclude_paths[@]}"; do
            echo "  - $path"
        done
    fi
} >"$backup_info_file"

# Cleans up.
trap - SIGINT

echo "Backup completed successfully. See $backup_info_file for more details."
