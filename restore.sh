#!/bin/bash

# Function for displaying help
display_help() {
	cat <<EOF
Usage: $0 [-s] backup_file [destination]

Options:
   -s              Extract the backup in the specified directory, not in a sub-directory.
   backup_file     The path of the backup file to restore.
   destination     The directory where the backup should be restored (optional, defaults to current directory).

The script will extract the backup into a subdirectory of the specified directory or the current directory if no directory is specified.
If the -s option is used, the backup will be extracted directly into the specified directory.
If the backup is encrypted, you will be prompted for the decryption key.
EOF
}

# Function to check SHA256 checksum
check_sha256_checksum() {
	info_file="${1%.*}.txt"
	if [ -f "$info_file" ]; then
		expected_sha256sum=$(awk -F': ' '/SHA256 Checksum/{print $2}' "$info_file")
		if [ -n "$expected_sha256sum" ]; then
			echo "Computing SHA256 checksum of the backup file. This may take a while for large files..."
			actual_sha256sum=$(sha256sum "$1" | cut -d' ' -f1)
			if [ "$expected_sha256sum" == "$actual_sha256sum" ]; then
				echo "SHA256 checksum verification passed."
			else
				echo "SHA256 checksum verification failed. Please ensure that the backup file has not been tampered with."
				exit 1
			fi
		fi
	fi
}

# Function to restore backup
restore_backup() {
	if [[ "$1" == *.gpg ]]; then
		echo "Backup file is encrypted. Decrypting..."
		gpg -d "$1" | zstdcat | tar xvf - -C "$2"
	else
		zstdcat "$1" | tar xvf - -C "$2"
	fi
	echo "Backup successfully restored to $2."
}

# Parse options
extract_in_subdir_flag="yes"
while getopts ":sh" opt; do
	case ${opt} in
	s)
		extract_in_subdir_flag="no"
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

# Check for backup file argument
if [ -z "$1" ]; then
	echo "Please provide a backup file as the first argument."
	display_help
	exit 1
fi

backup_file="$1"
shift 1

destination=${1:-.} # Default to current directory if no destination specified

check_sha256_checksum "$backup_file"

if [ "$extract_in_subdir_flag" == "yes" ]; then
	sub_directory=$(basename "$backup_file")
	sub_directory="${sub_directory%%.*}" # Remove extension
	destination="${destination}/${sub_directory}"
	mkdir -p "$destination"
fi

restore_backup "$backup_file" "$destination"
