#!/bin/bash

# Function for displaying help
display_help() {
    cat <<EOF
Usage: $0 [-x] [-i] [-s] [-e] [-r recipient] [-p passphrase] remote_host [path1] [path2] ...
Options:
   -x              Enable --one-file-system option for tar (optional).
   -i              Ignore all pre-defined exclude paths and only backup the given path(s).
   -s              Skip generating SHA-256 checksum.
   -e              Encrypt the backup file using PGP.
   -r recipient    Specify the recipient for PGP encryption (optional).
   -p passphrase   Specify the passphrase for PGP encryption (optional).
   remote_host     The user@hostname or IP address of the remote server to backup.
   path            Path(s) to backup (optional) if -i option is used or to exclude from backup if -i is not used.
                   Multiple paths can be specified.

The script will create a tar archive of the remote server's filesystem,
excluding certain system directories and any additional paths specified.
If the -i option is used, only the given paths are backed up.
The archive will then be compressed using zstd and saved locally with the filename format:
<hostname>_backup_<timestamp>.tar.zst
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

# Variables
one_file_system_flag=""
ignore_exclude_flag=""
skip_checksum_flag=""
encrypt_flag=""
recipient=""
passphrase=""
exclude_paths=("/dev/*" "/proc/*" "/sys/*" "/run/*" "/tmp/*" "/var/log/*")
include_paths=()

# Parse options
while getopts ":xiser:p:h" opt; do
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

# Check for remote host argument
if [ -z "$1" ]; then
    echo "Please provide a remote host as the first argument."
    display_help
    exit 1
fi

remote_host=$1
shift 1

# Check for the presence of the recipient's public key if PGP encryption is requested
if [ "$encrypt_flag" == "yes" ] && [ -n "$recipient" ]; then
    check_key "$recipient"
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
    if [ "$skip_checksum_flag" != "yes" ]; then
        echo "SHA256 Checksum    : $backup_sha256sum"
    fi
    echo "Backup Time (secs) : $elapsed_time"
    echo "Date & Time        : $(date)"
    echo "Backup Options     : One-File-System $(if [ -z "$one_file_system_flag" ]; then echo 'NO'; else echo 'YES'; fi) | Skip Checksum $(if [ -z "$skip_checksum_flag" ]; then echo 'NO'; else echo 'YES'; fi) | Encryption $(if [ -z "$encrypt_flag" ]; then echo 'NO'; else echo 'YES'; fi)"
    echo
    echo "PATHS INFORMATION"
    echo "-----------------"
    if [ "$ignore_exclude_flag" == "yes" ]; then
        echo "Paths Included:"
        for path in "${include_paths[@]}"; do
            echo "  - $path"
        done
    else
        echo "Paths Excluded:"
        for path in "${exclude_paths[@]}"; do
            echo "  - $path"
        done
    fi
    echo "======================================================="
} >"$backup_info_file"

echo "Backup info saved to $backup_info_file."
