# Mariabackup
## @Documentation in progress :)

## Restauration d'un backup

### Décompression d'un backup réalisé par ce script
gunzip -c snapshot.stream.gz | mbstream -x

### Sources de documentation sur MariaDB, le backup, et la restauration hard
https://mariadb.com/kb/en/full-backup-and-restore-with-mariabackup/
https://mariadb.com/kb/en/incremental-backup-and-restore-with-mariabackup/

