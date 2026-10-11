# db-backup-project

Bash-Skript zum automatischen Backup und Restore von Datenbanken in Docker-Containern.
Unterstützt MariaDB/MySQL, PostgreSQL, MongoDB, SQLite3 und Bitwarden/Vaultwarden in Containern. Zusätzlich sucht das Skript selbst nach SQLite-Dateien auf dem Host (z. B. die Datenbank eines Dashboards oder VPN-Containers) und sichert sie konsistent mit `sqlite3 .backup`.

## Struktur

```
db-backup-project/
├── db-container-backup.sh   # Haupt-/einziges Skript (Backup + Restore)
├── backup/                  # Backup-Dateien, nach Container sortiert (wird automatisch angelegt)
└── docs/
    └── datenbank-restore-anleitung.md   # Ausführliche Restore-Anleitung
```

## Verwendung

```bash
# Backup aller erkannten Container (z. B. per Cron)
./db-container-backup.sh

# Interaktiver Restore (Datenbank + Backup-Datei werden zur Auswahl aufgelistet).
# Findet das Skript weitere Container im selben Docker-Compose-Projekt, fragt es
# zusätzlich, ob diese vor dem Restore gestoppt und danach wieder gestartet werden sollen.
./db-container-backup.sh restore
```

Details, Overwrite-Verhalten je Datenbanktyp und bekannte Einschränkungen: siehe
`docs/datenbank-restore-anleitung.md`.

## SQLite-Dateien auf dem Host

Standardmäßig wird unter `/opt/containers` (Tiefe 6) nach `*.db`, `*.sqlite` und `*.sqlite3` mit echtem SQLite-Kopf gesucht. Die Sicherungen liegen unter `backup/_sqlite-dateien/<pfad-mit-__>/`. Suchordner, Tiefe und Ausschlüsse lassen sich per Umgebungsvariable ändern (`SQLITE_SEARCH_PATHS`, `SQLITE_MAXDEPTH`, `SQLITE_EXCLUDE`), Details und Restore siehe `docs/datenbank-restore-anleitung.md`. Voraussetzung: `sqlite3` auf dem Host.

## Installation auf dem Server

Diesen Ordner z. B. nach `/opt/db-backup/` kopieren (Skript ausführbar, am besten nur für root: `chmod 700`) und per Cron einplanen:

```bash
crontab -e
# Beispiel: alle 3 Stunden
0 */3 * * * /opt/db-backup/db-container-backup.sh >/dev/null 2>&1
```

Der Backup-Ordner liegt immer im Unterordner `backup/` neben dem Skript, je Container ein Verzeichnis
(`backup/<containername>/<dbname-oder-all-databases>-JJJJMMDDHHMM.sql.gz`). Schlägt ein Dump fehl, liegt daneben eine
`.err.log`-Datei mit der Fehlermeldung. Aufbewahrung: Dateien älter als `DAYS` Tage (Standard 1, oben im Skript) werden
nach jedem erfolgreichen Dump gelöscht.
