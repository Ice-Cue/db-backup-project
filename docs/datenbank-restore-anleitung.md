# Anleitung: Datenbank-Backups wiederherstellen

Gilt für die Backups aus `/opt/db-backup/db-container-backup.sh`. Der Backup-Ordner liegt
automatisch im selben Verzeichnis wie das Skript (Unterordner `backup/`), also
`/opt/db-backup/backup/<containername>/` (wenn das Skript in `/opt/db-backup/` liegt).

---

## Empfohlener Weg: interaktives Restore über das Skript

Das Skript hat einen eingebauten Restore-Modus, der Container und Backup-Datei automatisch
aus dem Backup-Ordner auflistet – kein manueller Pfad nötig:

```bash
cd /opt/db-backup
./db-container-backup.sh restore
```

Ablauf:

1. Skript listet alle vorhandenen Datenbanken (Container-Unterordner) nummeriert auf → Nummer eingeben.
2. Skript listet alle Backup-Dateien für diese Datenbank auf (neueste zuerst, mit Größe) → Nummer eingeben.
3. Skript zeigt Container, Image und gewählte Backup-Datei an und warnt, dass bestehende Daten überschrieben werden.
4. Erst nach Bestätigung mit `ja` startet der eigentliche Restore. Der Datenbanktyp (MariaDB/MySQL, PostgreSQL, MongoDB, SQLite, Bitwarden) wird automatisch am Container-Image erkannt.

Container und/oder Backup-Datei können auch direkt als Argumente übergeben werden, um die
Auswahl zu überspringen (z. B. für eigene Automatisierung):

```bash
./db-container-backup.sh restore <containername>                      # nur Backup-Datei auswählen
./db-container-backup.sh restore <containername> <pfad-zur-backup-datei>   # vollständig manuell
```

**Wichtig, für alle Datenbanktypen:**

- Ein Restore überschreibt bestehende Daten. Vor jedem Restore ein frisches Backup des aktuellen Zustands erstellen.
- Wenn möglich vorher in einer Testumgebung/Testcontainer prüfen, nicht direkt live.
- Für ein garantiert sauberes Ergebnis: Anwendungscontainer, die auf die Datenbank zugreifen, vor dem Restore stoppen (`docker stop <containername>`) und danach wieder starten. Das Skript trennt bei PostgreSQL zwar automatisch aktive Verbindungen, laufende Anwendungen können sich aber sofort wieder neu verbinden und den Restore stören.
- Die manuellen Befehle in den folgenden Abschnitten sind als Referenz gedacht (z. B. falls das Skript nicht verfügbar ist) und spiegeln exakt das wider, was der Restore-Modus des Skripts automatisch macht.

---

## Überschreibverhalten beim Restore

MariaDB/MySQL, PostgreSQL (ab Backups mit `--clean --if-exists`), MongoDB (mit `--drop`) und SQLite/Bitwarden überschreiben die Zieldatenbank jeweils vollständig – Einträge, die nach dem Backup-Zeitpunkt hinzugekommen sind, werden beim Restore gelöscht. Ausnahme: PostgreSQL-Dumps, die **vor** der Umstellung auf `--clean --if-exists` erstellt wurden, enthalten keine DROP-Anweisungen und überschreiben nicht sauber (Fehler bei bereits vorhandenen Tabellen/Zeilen möglich) – betrifft nur alte Backup-Dateien, keine neuen.

---

## 1. MariaDB / MySQL

Dateiformat: `<dbname>-JJJJMMDDHHMM.sql.gz` (einzelne Datenbank) oder `all-databases-JJJJMMDDHHMM.sql.gz` (kompletter Dump aller Datenbanken).

```bash
CONTAINER=<mysql-containername>   # Containernamen anpassen (z. B. aus `docker ps`)

# Root-Passwort aus dem Container auslesen
MYSQL_PWD=$(docker exec "$CONTAINER" env | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -n1 | cut -d"=" -f2-)

# Client-Binary ermitteln (heißt je nach Image "mariadb" oder "mysql")
DB_CLIENT=$(docker exec "$CONTAINER" sh -c 'command -v mariadb || command -v mysql')
```

**Einzelne Datenbank wiederherstellen:**

```bash
zcat /opt/db-backup/backup/$CONTAINER/<dbname>-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i -e MYSQL_PWD="$MYSQL_PWD" "$CONTAINER" "$DB_CLIENT" -u root <dbname>
```

**Kompletten `all-databases`-Dump wiederherstellen** (Dump enthält bereits `CREATE DATABASE`/`USE`, daher ohne Datenbanknamen einspielen):

```bash
zcat /opt/db-backup/backup/$CONTAINER/all-databases-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i -e MYSQL_PWD="$MYSQL_PWD" "$CONTAINER" "$DB_CLIENT" -u root
```

---

## 2. PostgreSQL

Dateiformat: `<dbname>-JJJJMMDDHHMM.sql.gz` (einzelne Datenbank, erzeugt mit `pg_dump --clean --if-exists`) oder `all-databases-JJJJMMDDHHMM.sql.gz` (kompletter Cluster-Dump, erzeugt mit `pg_dumpall --clean --if-exists`).

```bash
CONTAINER=<postgres-containername>   # Containernamen anpassen (z. B. aus `docker ps`)

POSTGRES_PWD=$(docker exec "$CONTAINER" env | grep -E '^POSTGRES_PASSWORD=' | head -n1 | cut -d"=" -f2-)
```

`pg_dumpall --clean` räumt nur auf Datenbank-Ebene auf (`DROP DATABASE`), nicht pro Tabelle. Bestehen noch aktive Verbindungen zur Zieldatenbank (z. B. von laufenden Anwendungscontainern), schlägt `DROP DATABASE` fehl und der Restore läuft gegen die alte, weiterhin existierende Datenbank statt gegen eine frische. Deshalb vor dem eigentlichen Restore aktive Verbindungen trennen:

```bash
# Bei all-databases-Restore: alle Nicht-System-Datenbanken
docker exec -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname NOT IN ('postgres','template0','template1');"

# Bei Einzeldatenbank-Restore: nur die Zieldatenbank
docker exec -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = '<dbname>';"
```

**Einzelne Datenbank wiederherstellen:**

```bash
zcat /opt/db-backup/backup/$CONTAINER/<dbname>-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d <dbname>
```

**Kompletten `all-databases`-Dump wiederherstellen** (enthält `\connect`-Befehle für jede Datenbank):

```bash
zcat /opt/db-backup/backup/$CONTAINER/all-databases-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres
```

### Bekannte Einschränkung: Datenbank mit nicht schema-qualifizierten Funktionen

Manche Anwendungsdatenbanken lassen sich mit einem Standard-Restore nicht vollständig einspielen. Typisches Fehlerbild beim Anlegen einer Tabelle:

```
ERROR:  function xyz(unknown, text) does not exist
CONTEXT:  SQL function "xyz_wrapper" during inlining
```

**Ursache:** `pg_dump` setzt zu Beginn jedes Datenbank-Abschnitts aus Sicherheitsgründen `search_path` auf leer (`SELECT pg_catalog.set_config('search_path', '', false);`). Ruft eine Funktion der Anwendung intern eine andere Funktion oder Erweiterung **ohne Schema-Präfix** auf (z. B. `xyz(...)` statt `public.xyz(...)`), findet Postgres sie bei leerem `search_path` nicht mehr. Besonders betroffen sind Tabellen mit generierten Spalten (`GENERATED ALWAYS AS ... STORED`), die die Funktion sofort beim `CREATE TABLE` prüfen. Alle abhängigen Views, Indizes und Trigger scheitern danach mit `relation "..." does not exist`.

Das ist ein Fehler im Schema der Anwendung, kein Fehler im Backup-Skript. Er träte bei jedem Standard-`pg_dump`/`psql`-Restore dieser Datenbank auf.

**Manueller Workaround, falls die Datenbank vollständig wiederhergestellt werden muss:**

```bash
# 1. Betroffene Funktion mit Schema-Präfix neu anlegen (Definition der Anwendung übernehmen,
#    nur den Aufruf von xyz(...) mit "public." qualifizieren)
docker exec -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d <dbname> -c \
  "CREATE OR REPLACE FUNCTION public.<funktionsname>(text) RETURNS text LANGUAGE sql IMMUTABLE AS \$\$ SELECT lower(public.xyz('xyz', \$1)) \$\$;"

# 2. Danach den kompletten Dump erneut einspielen (die Funktion existiert jetzt korrekt,
#    CREATE TABLE und alle abhängigen Objekte sollten diesmal durchlaufen)
zcat /opt/db-backup/backup/$CONTAINER/all-databases-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres
```

Dieser Workaround ist **nicht** automatisch ins Skript eingebaut (bewusste Entscheidung, um den Dump-Inhalt nicht automatisiert zu verändern) und muss bei Bedarf manuell ausgeführt werden.

---

## 3. MongoDB

Dateiformat: `mongo-JJJJMMDDHHMM.gz` (Binärarchiv von `mongodump --archive`, kein reines SQL).

```bash
CONTAINER=<mongo-containername>   # Containernamen anpassen

zcat /opt/db-backup/backup/$CONTAINER/mongo-<JJJJMMDDHHMM>.gz \
    | docker exec -i "$CONTAINER" mongorestore --archive --drop
```

`--drop` ist Standard im Restore-Befehl des Skripts: bestehende Collections werden vor dem Einspielen geleert, damit der Restore die Datenbank vollständig überschreibt statt nur zu ergänzen.

---

## 4. SQLite3

Dateiformat: `sqlite-JJJJMMDDHHMM.sql.gz` (reiner SQL-Dump von `sqlite3 .dump`).

Der `.dump`-Export enthält keine `DROP TABLE`-Anweisungen. Das Skript verschiebt die bestehende Datenbankdatei deshalb automatisch nach `.bak`, bevor der Dump in eine neue, leere Datenbank eingespielt wird:

```bash
CONTAINER=<sqlite-containername>   # Containernamen anpassen

# Bestehende Datenbankdatei im Container sichern
docker exec "$CONTAINER" sh -c 'test -f /data/database.db && mv /data/database.db /data/database.db.bak'

# Dump in eine neue, leere Datenbank einspielen
zcat /opt/db-backup/backup/$CONTAINER/sqlite-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i "$CONTAINER" sqlite3 /data/database.db
```

---

## 5. Bitwarden / Vaultwarden (bitwardenrs)

Gleiches Prinzip wie SQLite3, aber anderer (relativer) Pfad, wie im Backup-Skript verwendet.

```bash
CONTAINER=<bitwarden-containername>   # Containernamen anpassen

# Bestehende Datenbankdatei im Container sichern
docker exec "$CONTAINER" sh -c 'test -f data/db.sqlite3 && mv data/db.sqlite3 data/db.sqlite3.bak'

# Dump in eine neue, leere Datenbank einspielen
zcat /opt/db-backup/backup/$CONTAINER/bitwarden-<JJJJMMDDHHMM>.sql.gz \
    | docker exec -i "$CONTAINER" sqlite3 data/db.sqlite3
```

---

## Kurzreferenz: Backup-Verzeichnisstruktur

```
<Skript-Verzeichnis>/backup/<containername>/<dbname-oder-all-databases>-JJJJMMDDHHMM.sql.gz
```

Bei Fehlschlägen erzeugt das Backup-Skript zusätzlich eine `.err.log`-Datei im selben Verzeichnis mit der Fehlermeldung des jeweiligen Dump-Tools.