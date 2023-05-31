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
   -x Enable --one-file-system option for tar.
   -i Only backup the given path(s).
   -s Skip SHA-256 checksum.
   -e Enable PGP encryption.
   -n Skip check for remote root privileges.
   -r Specify the recipient for PGP encryption.
   -p Specify the passphrase for PGP encryption.
   host: user@hostname/IP of the remote server to backup.
   path: Path(s) to backup or exclude. Multiple paths can be specified.
EOF
}

# Function to cleanup upon receiving SIGINT (Ctrl+C)
cleanup() {
    echo "Backup interrupted. Cleaning up..."
    rm -f "$backup_file_name"
    exit 1
}

# Trap SIGINT (Ctrl+C)
trap cleanup SIGINT

check_key() {
    local key="$1"
    if ! gpg --list-keys "$key" >/dev/null 2>&1; then
        echo "Recipient key not found in the keychain."
        exit 1
    fi
}

check_remote_root() {
    local remote_host="$1"
    if ssh "$remote_host" 'test "$(id -u)" -eq 0'; then
        return 0
    else
        echo "You must have root privileges on the remote host to perform a complete backup."
        exit 1
    fi
}

# Variables
one_file_system_flag=""
ignore_exclude_flag=""
skip_checksum_flag=""
encrypt_flag=""
no_root_check_flag=""
recipient=""
passphrase=""
exclude_paths=("/dev/*" "/proc/*" "/sys/*" "/run/*" "/tmp/*" "/var/log/*")
include_paths=()

# Parse options
while getopts ":xisenr:p:h" opt; do
    case ${opt} in
    x)
        one_file_system_flag="--one-file-system"
        ;;
    i)
        ignore_exclude_flag="yes"
        ;;
    s)
        skip_checksum_flag="yes"
        ;;
    e)
        encrypt_flag="yes"
        ;;
    n)
        no_root_check_flag="yes"
        ;;
    r)
        recipient="$OPTARG"
        encrypt_flag="yes"
        ;;
    p)
        passphrase="$OPTARG"
        encrypt_flag="yes"
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
if [ "$encrypt_flag" == "yes" ] && [ -n "$recipient" ]; then
    check_key "$recipient"
fi

# Check for remote host argument
if [ -z "${1:-}" ]; then
  echo "Provide a remote host."
    display_help
    exit 1
fi

remote_host=$1
shift 1

# Check for remote root access if not disabled
if [ "$no_root_check_flag" != "yes" ]; then
    check_remote_root "$remote_host"
fi

# Process paths
for path in "$@"; do
    path="${path%/}" # Remove trailing slashes
    if [ "$ignore_exclude_flag" == "yes" ]; then
        include_paths+=("$path")
    else
        [[ "$path" != */'*' ]] && path="${path}/*"
        exclude_paths+=("$path")
    fi
done

timestamp=$(date +%s)
backup_file_name="$(echo "$remote_host" | cut -d'@' -f2)_backup_${timestamp}.tar.zst"

# Perform backup and measure time
start_time=$(date +%s)
if [ "$ignore_exclude_flag" == "yes" ]; then
    ssh "$remote_host" 'tar '"$one_file_system_flag"' -cvf - '"$(printf '%q ' "${include_paths[@]}")"'' | zstd -T0 -o "$backup_file_name"
else
    ssh "$remote_host" 'tar '"$one_file_system_flag"' '"$(printf ' --exclude=%q' "${exclude_paths[@]}")"' -cvf - /' | zstd -T0 -o "$backup_file_name"
fi
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

# Encrypt the backup file if encryption is enabled
if [ "$encrypt_flag" == "yes" ]; then
    if [ -n "$recipient" ]; then
        gpg --yes --batch -z 0 --recipient="$recipient" --output "${backup_file_name}.gpg" --encrypt "$backup_file_name" && rm "$backup_file_name"
        backup_file_name="${backup_file_name}.gpg"
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
        echo "$passphrase" | gpg --yes --batch -z 0 --passphrase-fd 0 --symmetric --output "${backup_file_name}.gpg" "$backup_file_name" && rm "$backup_file_name"
        backup_file_name="${backup_file_name}.gpg"
    fi
fi

# Create backup info file
backup_file_size=$(du -sh "$backup_file_name" | cut -f1)
backup_sha256sum=$([ "$skip_checksum_flag" == "yes" ] || sha256sum "$backup_file_name" | cut -d' ' -f1)
backup_info_file="${backup_file_name%.*}.txt"

{
    echo "======================================================="
    echo "                      BACKUP REPORT                    "
    echo "======================================================="
    echo
    echo "BACKUP SUMMARY"
    echo "--------------"
    echo "Hostname           : $(echo "$remote_host" | cut -d'@' -f2)"
    echo "Backup File        : $backup_file_name"
    echo "File Size          : $backup_file_size"
    echo "Elapsed Time       : $elapsed_time seconds"
    echo "Date & Time        : $(date)"
    [ "$skip_checksum_flag" == "yes" ] || echo "SHA-256 Checksum    : $backup_sha256sum"
    echo
    echo "BACKUP OPTIONS"
    echo "--------------"
    echo "One File System    : $([ "$one_file_system_flag" == "--one-file-system" ] && echo "Yes" || echo "No")"
    echo "Ignore Excludes    : $([ "$ignore_exclude_flag" == "yes" ] && echo "Yes" || echo "No")"
    echo "Skip Checksum      : $([ "$skip_checksum_flag" == "yes" ] && echo "Yes" || echo "No")"
    echo "Encryption         : $([ "$encrypt_flag" == "yes" ] && echo "Yes" || echo "No")"
    echo "Skip Root Check    : $([ "$no_root_check_flag" == "yes" ] && echo "Yes" || echo "No")"
    echo
    echo "BACKUP CONTENT"
    echo "--------------"
    if [ "$ignore_exclude_flag" == "yes" ]; then
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

echo "Backup completed successfully. See $backup_info_file for more details."
