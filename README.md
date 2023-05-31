# Remote Server Backup and Restore Scripts

Two bash scripts for creating and restoring a backup of a remote server's filesystem are included:

1. `backup.sh`: Creates a backup of a remote server's file system.
2. `restore.sh`: Restores a backup created by the `backup.sh` script.

## Usage

### Backup Script (`backup.sh`)

```bash
./backup.sh [-x] [-i] [-s] [-e] [-n] [-r recipient] [-p passphrase] host [path1] [path2] ...
```

Options include: `-x`, `-i`, `-s`, `-e`, `-n`, `-r recipient`, `-p passphrase`, `host`, `path`.

The script creates a tar archive, optionally compresses, and encrypts it. Outputs are `<hostname>_backup_<timestamp>.tar.zst` and `<hostname>_backup_<timestamp>.tar.zst.txt`.

### Restore Script (`restore.sh`)

```bash
./restore.sh [-s] [-r] backup_file [destination]
```

Options include: `-s`, `-r`, `backup_file`, `destination`.

The script decrypts (if necessary) and extracts the backup. If the backup is encrypted, you will be prompted for the decryption key. It verifies the SHA256 checksum before restoring.

## Requirements

Scripts require `tar`, `zstd`, `gpg`, `ssh`, `awk` and `sha256sum`. Backup script uses SSH to connect to the remote server and GPG for encryption.
