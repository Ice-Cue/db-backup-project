# db-backup-project

Bash-Skript zum automatischen Backup und Restore von Datenbanken in Docker-Containern.
Unterstützt MariaDB/MySQL, PostgreSQL, MongoDB, SQLite3 und Bitwarden/Vaultwarden.

## Struktur

```
db-backup-project/
├── db-container-backup.sh   # Haupt-/einziges Skript (Backup + Restore)
├── backup/                  # Backup-Dateien, nach Container sortiert (wird automatisch angelegt)
├── docs/
│   └── datenbank-restore-anleitung.md   # Ausführliche Restore-Anleitung
└── CLAUDE.md                 # Kontext für Claude Code
```

## Verwendung

```bash
# Backup aller erkannten Container (z. B. per Cron)
./db-container-backup.sh

# Interaktiver Restore (Datenbank + Backup-Datei werden zur Auswahl aufgelistet)
./db-container-backup.sh restore
```

Details, Overwrite-Verhalten je Datenbanktyp und bekannte Einschränkungen: siehe
`docs/datenbank-restore-anleitung.md`.

## Installation auf dem Server

Diesen Ordner z. B. nach `/opt/db-backup/` kopieren und per Cron einplanen:

```bash
crontab -e
# Beispiel: täglich um 3 Uhr
0 3 * * * /opt/db-backup/db-container-backup.sh >> /opt/db-backup/backup.log 2>&1
```
