#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# Displays help information.
function display_help() {
    cat <<EOF
Usage: ${0} [-x] [-i] [-s] [-e] [-n] [-r recipient] [-p passphrase] host [path1] [path2] ...
Options:
   -x              Enable --one-file-system option for tar.
   -i              Only backup the given path(s).
   -s              Skip SHA-256 checksum.
   -e              Enable PGP encryption.
   -n              Skip check for remote root privileges.
   -r recipient    Specify the recipient for PGP encryption.
   -p passphrase   Specify the passphrase for PGP encryption.
   host            user@hostname/IP of the remote server to backup.
   path            Path(s) to backup or exclude. Multiple paths can be specified.
EOF
}

# Function to cleanup upon receiving SIGINT (Ctrl+C)
function cleanup() {
    echo "Backup interrupted. Cleaning up..."
    rm -f "$backup_file"
    exit 1
}

# Trap SIGINT (Ctrl+C)
trap cleanup SIGINT

# Checks if GPG key exists.
function key_exists() {
    if ! gpg --list-keys "$1" >/dev/null 2>&1; then
        echo "Recipient key not found."
        exit 1
    fi
}

# Checks for remote root access.
function check_root_access() {
    if ! ssh "$1" 'test "$(id -u)" -eq 0'; then
        echo "Need root privileges on remote host."
        exit 1
    fi
}

# Variables
declare -a exclude_paths=("/dev/*" "/proc/*" "/sys/*" "/run/*" "/tmp/*" "/var/log/*")
declare -a include_paths=()
one_file_system=""
ignore_exclude=""
skip_checksum=""
encrypt=""
no_root_check=""
recipient=""
passphrase=""

# Parse options
while getopts ":xisenr:p:h" opt; do
    case ${opt} in
    x)
        one_file_system="--one-file-system"
        ;;
    i)
        ignore_exclude="yes"
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
if [ "$encrypt" == "yes" ] && [ -n "$recipient" ]; then
    key_exists "$recipient"
fi

# Check for remote host argument
if [ -z "${1:-}" ]; then
    echo "Specify a remote host."
    display_help
    exit 1
fi

host=$1
shift 1

# Check for remote root access if not disabled
if [ "$no_root_check" != "yes" ]; then
    check_root_access "$host"
fi

# Process paths
for path in "$@"; do
    path="${path%/}" # Remove trailing slashes
    if [ "$ignore_exclude" == "yes" ]; then
        include_paths+=("$path")
    else
        [[ "$path" != */'*' ]] && path="${path}/*"
        exclude_paths+=("$path")
    fi
done

# Backup and measure time.
start=$(date +%s)
backup_file="$(echo "$host" | cut -d'@' -f2)_backup_${start}.tar.zst"

if [ "$ignore_exclude" == "yes" ]; then
    ssh "$host" 'tar '"$one_file_system"' -cvf - '"$(printf '%q ' "${include_paths[@]}")"'' | zstd -T0 -o "$backup_file"
else
    ssh "$host" 'tar '"$one_file_system"' -cvf - '"$(printf ' --exclude=%q' "${exclude_paths[@]}")"' /' | zstd -T0 -o "$backup_file"
fi

# todo: if backup fails, perhaps due to access right issues, the rest is not executed. We should somehow catch errors

elapsed=$(($(date +%s) - start))

# Encrypt the backup file if encryption is enabled
if [ "$encrypt" == "yes" ]; then
    if [ -n "$recipient" ]; then
        gpg --yes --batch -z 0 --recipient="$recipient" --output "${backup_file}.gpg" --encrypt "$backup_file" && rm "$backup_file"
        backup_file="${backup_file}.gpg"
    else
        if [ -z "$passphrase" ]; then
            while true; do
                echo -n "Please enter encryption passphrase: "
                read -r -s passphrase
                echo
                echo -n "Please re-enter encryption passphrase: "
                read -r -s passphrase_verify
                echo
                if [ "$passphrase" == "$passphrase_verify" ]; then
                    break
                else
                    echo "Passphrases do not match. Please try again."
                fi
            done
        fi
        echo "$passphrase" | gpg --yes --batch -z 0 --passphrase-fd 0 --symmetric --output "${backup_file}.gpg" "$backup_file" && rm "$backup_file"
        backup_file="${backup_file}.gpg"
    fi
fi

# Create backup info file
backup_file_size=$(du -sh "$backup_file" | cut -f1)
backup_sha256sum=$([ "$skip_checksum" == "yes" ] || sha256sum "$backup_file" | cut -d' ' -f1)
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
    [ "$skip_checksum" == "yes" ] || echo "SHA-256 Checksum    : $backup_sha256sum"
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
    if [ "$ignore_exclude" == "yes" ]; then
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
