#!/bin/bash
# Backup-Skript für Datenbank-Container
# ---
# Dieses Skript kann verwendet werden, um automatisch Backups von Datenbanken in Docker-Containern zu erstellen.
# Es unterstützt derzeit MySQL, MariaDB, PostgreSQL, MongoDB und SQLite3 (in Containern) sowie
# SQLite-Dateien, die das Skript selbst auf dem Host findet (siehe unten, Abschnitt "SQLite-Dateien").
DAYS=1
# SQLite-Dateien auf dem Host automatisch suchen und sichern (jeweils per Umgebungsvariable änderbar):
#   SQLITE_SEARCH_PATHS  Suchordner, durch Leerzeichen getrennt (Standard: /opt/containers)
#   SQLITE_MAXDEPTH      maximale Suchtiefe (Standard: 6)
#   SQLITE_EXCLUDE       Ausschlussmuster (Shell-Glob), durch Doppelpunkt getrennt
SQLITE_SEARCH_PATHS="${SQLITE_SEARCH_PATHS:-/opt/containers}"
SQLITE_MAXDEPTH="${SQLITE_MAXDEPTH:-6}"
SQLITE_EXCLUDE="${SQLITE_EXCLUDE:-*/backup/*:*/.git/*:*/node_modules/*:*/duplicati/config/backup/*:*/duplicati/config/backup *:*/duplicati/config/[A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z].sqlite}"
# Backup-Ordner liegt immer im selben Verzeichnis wie dieses Skript (Unterordner "backup")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPDIR="$SCRIPT_DIR/backup"

# ---------------------------------------------------------------------------
# Restore-Funktion
# Aufruf: ./db-container-backup.sh restore
#   → wählt Datenbank (Container) und Backup-Datei interaktiv aus dem Backup-Ordner aus
# Aufruf: ./db-container-backup.sh restore <containername>
#   → Datenbank ist bereits bekannt, nur die Backup-Datei wird interaktiv ausgewählt
# Aufruf: ./db-container-backup.sh restore <containername> <pfad-zur-backup-datei>
#   → vollständig manuell, wie bisher (z. B. für eigene Skripte/Automatisierung)
#
# Erkennt den Datenbanktyp automatisch anhand des Container-Images und ruft
# das passende Restore-Kommando auf. Fragt vor dem eigentlichen Restore
# interaktiv nach Bestätigung, da bestehende Daten überschrieben werden.
# Findet das Skript über das Docker-Compose-Label "com.docker.compose.project"
# weitere Container im selben Compose-Projekt, fragt es zusätzlich, ob diese vor
# dem Restore gestoppt und danach wieder gestartet werden sollen.
# ---------------------------------------------------------------------------
restore_backup() {
    local CONTAINER="$1"
    local BACKUP_FILE="$2"
    local DEPENDENT_CONTAINERS=()

    # Schritt 1: Datenbank (Container) interaktiv auswählen, falls nicht übergeben
    if [ -z "$CONTAINER" ]; then
        local DBS=()
        local idx=1
        echo "Verfügbare Datenbanken (aus $BACKUPDIR):"
        while IFS= read -r dir; do
            DBS+=("$dir")
            echo "  $idx) $dir"
            idx=$((idx+1))
        done < <(find "$BACKUPDIR" -mindepth 1 -maxdepth 1 -type d ! -name '_*' -printf '%f\n' 2>/dev/null | sort)

        if [ ${#DBS[@]} -eq 0 ]; then
            echo "FEHLER: Keine Backups in $BACKUPDIR gefunden."
            exit 1
        fi

        read -p "Nummer der Datenbank auswählen: " DB_CHOICE
        if ! [[ "$DB_CHOICE" =~ ^[0-9]+$ ]] || [ "$DB_CHOICE" -lt 1 ] || [ "$DB_CHOICE" -gt ${#DBS[@]} ]; then
            echo "FEHLER: Ungültige Auswahl."
            exit 1
        fi
        CONTAINER="${DBS[$((DB_CHOICE-1))]}"
    fi

    # Schritt 2: Backup-Datei interaktiv auswählen, falls nicht übergeben
    if [ -z "$BACKUP_FILE" ]; then
        local FILES=()
        local idx=1
        echo ""
        echo "Verfügbare Backups für $CONTAINER:"
        while IFS= read -r f; do
            FILES+=("$f")
            local SIZE=$(du -h "$f" 2>/dev/null | cut -f1)
            echo "  $idx) $(basename "$f")  ($SIZE)"
            idx=$((idx+1))
        done < <(find "$BACKUPDIR/$CONTAINER" -maxdepth 1 -name "*.gz" 2>/dev/null | sort -r)

        if [ ${#FILES[@]} -eq 0 ]; then
            echo "FEHLER: Keine Backup-Dateien für $CONTAINER in $BACKUPDIR/$CONTAINER gefunden."
            exit 1
        fi

        read -p "Nummer des Backups auswählen: " FILE_CHOICE
        if ! [[ "$FILE_CHOICE" =~ ^[0-9]+$ ]] || [ "$FILE_CHOICE" -lt 1 ] || [ "$FILE_CHOICE" -gt ${#FILES[@]} ]; then
            echo "FEHLER: Ungültige Auswahl."
            exit 1
        fi
        BACKUP_FILE="${FILES[$((FILE_CHOICE-1))]}"
    fi

    if [ ! -f "$BACKUP_FILE" ]; then
        echo "FEHLER: Backup-Datei $BACKUP_FILE nicht gefunden."
        exit 1
    fi

    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
    if [ -z "$IMAGE" ]; then
        echo "FEHLER: Container $CONTAINER nicht gefunden oder nicht erreichbar."
        exit 1
    fi

    echo "Container:     $CONTAINER"
    echo "Image:         $IMAGE"
    echo "Backup-Datei:  $BACKUP_FILE"
    echo "Hinweis: Für ein garantiert sauberes Restore sollten Anwendungscontainer, die auf"
    echo "diese Datenbank zugreifen, vorher gestoppt werden (docker stop <containername>)."
    echo "Bei PostgreSQL werden aktive Verbindungen zwar automatisch getrennt, laufende"
    echo "Anwendungen können sich aber sofort wieder neu verbinden und den Restore stören."

    local PROJECT
    PROJECT=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$CONTAINER" 2>/dev/null)
    if [ -n "$PROJECT" ]; then
        while IFS= read -r NAME; do
            [ "$NAME" != "$CONTAINER" ] && DEPENDENT_CONTAINERS+=("$NAME")
        done < <(docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}')
    fi

    if [ ${#DEPENDENT_CONTAINERS[@]} -gt 0 ]; then
        echo ""
        echo "Folgende Container gehören zum selben Compose-Projekt ($PROJECT):"
        printf '  - %s\n' "${DEPENDENT_CONTAINERS[@]}"
        read -p "Diese Container jetzt stoppen und nach dem Restore wieder starten? (ja/nein): " STOP_CONFIRM
        if [ "$STOP_CONFIRM" = "ja" ]; then
            docker stop "${DEPENDENT_CONTAINERS[@]}" > /dev/null
            echo "Gestoppt."
        else
            echo "Container werden nicht gestoppt."
            DEPENDENT_CONTAINERS=()
        fi
    fi

    read -p "Restore wirklich durchführen? Bestehende Daten werden überschrieben! (ja/nein): " CONFIRM
    if [ "$CONFIRM" != "ja" ]; then
        echo "Abgebrochen."
        if [ ${#DEPENDENT_CONTAINERS[@]} -gt 0 ]; then
            echo "Starte zuvor gestoppte Container wieder..."
            docker start "${DEPENDENT_CONTAINERS[@]}" > /dev/null
        fi
        exit 0
    fi

    case "$IMAGE" in
        *mariadb*|*mysql*)
            MYSQL_PWD=$(docker exec "$CONTAINER" env | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -n1 | cut -d"=" -f2-)
            if [ -z "$MYSQL_PWD" ]; then
                echo "FEHLER: Kein Root-Passwort im Container gefunden."
                exit 1
            fi
            DB_CLIENT=$(docker exec "$CONTAINER" sh -c 'command -v mariadb || command -v mysql')
            if [ -z "$DB_CLIENT" ]; then
                echo "FEHLER: Weder mariadb- noch mysql-Client im Container gefunden."
                exit 1
            fi
            echo "Starte MySQL/MariaDB-Restore..."
            if [[ "$BACKUP_FILE" == *all-databases* ]]; then
                zcat "$BACKUP_FILE" | docker exec -i -e MYSQL_PWD="$MYSQL_PWD" "$CONTAINER" "$DB_CLIENT" -u root
            else
                DB_NAME=$(basename "$BACKUP_FILE" | sed -E 's/-[0-9]{12}\.sql\.gz$//')
                echo "Zieldatenbank: $DB_NAME"
                zcat "$BACKUP_FILE" | docker exec -i -e MYSQL_PWD="$MYSQL_PWD" "$CONTAINER" "$DB_CLIENT" -u root "$DB_NAME"
            fi
            ;;
        *postgres*)
            POSTGRES_PWD=$(docker exec "$CONTAINER" env | grep -E '^POSTGRES_PASSWORD=' | head -n1 | cut -d"=" -f2-)
            if [ -z "$POSTGRES_PWD" ]; then
                echo "FEHLER: Kein POSTGRES_PASSWORD im Container gefunden."
                exit 1
            fi
            echo "Starte PostgreSQL-Restore..."
            # pg_dumpall --clean räumt nur auf Datenbank-Ebene auf (DROP DATABASE).
            # Bestehen noch aktive Verbindungen (z. B. von laufenden Anwendungscontainern),
            # schlägt DROP DATABASE fehl und der Restore läuft gegen die alte Datenbank statt
            # gegen eine frische. Deshalb vorher aktive Verbindungen zur Zieldatenbank trennen.
            if [[ "$BACKUP_FILE" == *all-databases* ]]; then
                echo "Trenne aktive Verbindungen zu allen Nicht-System-Datenbanken..."
                docker exec -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres -c \
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname NOT IN ('postgres','template0','template1');" \
                    > /dev/null
                zcat "$BACKUP_FILE" | docker exec -i -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres
            else
                DB_NAME=$(basename "$BACKUP_FILE" | sed -E 's/-[0-9]{12}\.sql\.gz$//')
                echo "Zieldatenbank: $DB_NAME"
                echo "Trenne aktive Verbindungen zu $DB_NAME..."
                docker exec -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d postgres -c \
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = '$DB_NAME';" \
                    > /dev/null
                zcat "$BACKUP_FILE" | docker exec -i -e PGPASSWORD="$POSTGRES_PWD" "$CONTAINER" psql -U postgres -d "$DB_NAME"
            fi
            ;;
        *mongo*)
            echo "Starte MongoDB-Restore..."
            echo "Hinweis: --drop ist aktiv, bestehende Collections werden vor dem Restore geleert."
            zcat "$BACKUP_FILE" | docker exec -i "$CONTAINER" mongorestore --archive --drop
            ;;
        *bitwardenrs*)
            echo "Starte Bitwarden-Restore..."
            echo "Hinweis: bestehende data/db.sqlite3 wird nach data/db.sqlite3.bak verschoben."
            docker exec "$CONTAINER" sh -c 'test -f data/db.sqlite3 && mv data/db.sqlite3 data/db.sqlite3.bak'
            zcat "$BACKUP_FILE" | docker exec -i "$CONTAINER" sqlite3 data/db.sqlite3
            ;;
        *sqlite*)
            echo "Starte SQLite3-Restore..."
            echo "Hinweis: bestehende /data/database.db wird nach /data/database.db.bak verschoben."
            docker exec "$CONTAINER" sh -c 'test -f /data/database.db && mv /data/database.db /data/database.db.bak'
            zcat "$BACKUP_FILE" | docker exec -i "$CONTAINER" sqlite3 /data/database.db
            ;;
        *)
            echo "FEHLER: Datenbanktyp für Image '$IMAGE' nicht erkannt."
            echo "Unterstützt: mysql, mariadb, postgres, mongo, sqlite, bitwardenrs."
            exit 1
            ;;
    esac
    local RESTORE_STATUS=$?

    if [ ${#DEPENDENT_CONTAINERS[@]} -gt 0 ]; then
        echo "Starte zuvor gestoppte Container wieder..."
        docker start "${DEPENDENT_CONTAINERS[@]}" > /dev/null
    fi

    if [ $RESTORE_STATUS -eq 0 ]; then
        echo "Restore abgeschlossen."
    else
        echo "FEHLER: Restore fehlgeschlagen."
        exit 1
    fi
}

if [ "$1" = "restore" ]; then
    restore_backup "$2" "$3"
    exit $?
fi

# Sicherstellen, dass das Backup-Verzeichnis existiert
if [ ! -d $BACKUPDIR ]; then
    mkdir -p $BACKUPDIR
fi
# Backup für MySQL/MariaDB-Container
CONTAINER=$(docker ps --format '{{.Names}}:{{.Image}}' | grep 'mysql\|mariadb' | cut -d":" -f1)
[ -n "$CONTAINER" ] && echo "Erstelle Backup für MySQL/MariaDB-Container: $CONTAINER"
for i in $CONTAINER; do
    # Deckt sowohl alte (MYSQL_*) als auch neue (MARIADB_*) Variablennamen ab
    MYSQL_DATABASE=$(docker exec "$i" env | grep -E '^(MYSQL_DATABASE|MARIADB_DATABASE)=' | head -n1 | cut -d"=" -f2-)
    MYSQL_PWD=$(docker exec "$i" env | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -n1 | cut -d"=" -f2-)

    CONTAINER_BACKUP_DIR="$BACKUPDIR/$i"
    mkdir -p "$CONTAINER_BACKUP_DIR"

    if [ -z "$MYSQL_PWD" ]; then
        echo "WARNUNG: Kein Root-Passwort für Container $i gefunden (weder MYSQL_ROOT_PASSWORD noch MARIADB_ROOT_PASSWORD) – Backup übersprungen."
        continue
    fi

    # Dump-Binary im Container ermitteln: neuere MariaDB-Images nennen es "mariadb-dump",
    # ältere MariaDB- und MySQL-Images "mysqldump". Fallback deckt beide Fälle ab.
    DUMP_BIN=$(docker exec "$i" sh -c 'command -v mariadb-dump || command -v mysqldump' 2>/dev/null)
    if [ -z "$DUMP_BIN" ]; then
        echo "FEHLER: Weder mariadb-dump noch mysqldump im Container $i gefunden – Backup übersprungen."
        continue
    fi

    # Wenn kein einzelner DB-Name bekannt ist, alle Datenbanken sichern statt leeren Dump zu erzeugen
    if [ -n "$MYSQL_DATABASE" ]; then
        DUMP_TARGET="$MYSQL_DATABASE"
        OUT_NAME="$MYSQL_DATABASE"
    else
        DUMP_TARGET="--all-databases"
        OUT_NAME="all-databases"
    fi

    BACKUP_FILE="$CONTAINER_BACKUP_DIR/$OUT_NAME-$(date +"%Y%m%d%H%M").sql.gz"
    ERROR_LOG="$CONTAINER_BACKUP_DIR/$OUT_NAME-$(date +"%Y%m%d%H%M").err.log"

    docker exec -e MYSQL_PWD="$MYSQL_PWD" \
        "$i" "$DUMP_BIN" -u root $DUMP_TARGET 2>"$ERROR_LOG" \
        | gzip > "$BACKUP_FILE"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "FEHLER: mysqldump für Container $i fehlgeschlagen, siehe $ERROR_LOG"
    else
        rm -f "$ERROR_LOG"
        find "$CONTAINER_BACKUP_DIR" -name "*.gz" -daystart -mtime +$DAYS -delete
    fi
done
# Backup für PostgreSQL-Container
PG_CONTAINER=$(docker ps --format '{{.Names}}:{{.Image}}' | grep 'postgres' | cut -d":" -f1)
[ -n "$PG_CONTAINER" ] && echo "Erstelle Backup für PostgreSQL-Container: $PG_CONTAINER"
for i in $PG_CONTAINER; do
    POSTGRES_DB=$(docker exec "$i" env | grep -E '^POSTGRES_DB=' | head -n1 | cut -d"=" -f2-)
    POSTGRES_USER=$(docker exec "$i" env | grep -E '^POSTGRES_USER=' | head -n1 | cut -d"=" -f2-)
    POSTGRES_PWD=$(docker exec "$i" env | grep -E '^POSTGRES_PASSWORD=' | head -n1 | cut -d"=" -f2-)

    # POSTGRES_USER hat im offiziellen Image den Default "postgres", falls nicht gesetzt
    if [ -z "$POSTGRES_USER" ]; then
        POSTGRES_USER="postgres"
    fi

    CONTAINER_BACKUP_DIR="$BACKUPDIR/$i"
    mkdir -p "$CONTAINER_BACKUP_DIR"

    if [ -z "$POSTGRES_PWD" ]; then
        echo "WARNUNG: Kein POSTGRES_PASSWORD für Container $i gefunden – Backup übersprungen."
        continue
    fi

    # Wenn kein einzelner DB-Name bekannt ist (z. B. Multi-Datenbank-Setups), alle Datenbanken sichern
    # --clean --if-exists sorgt dafür, dass der Dump DROP-Anweisungen enthält und ein Restore
    # die Zieldatenbank(en) vollständig überschreibt statt nur zu ergänzen.
    if [ -n "$POSTGRES_DB" ]; then
        OUT_NAME="$POSTGRES_DB"
        DUMP_CMD="pg_dump -U $POSTGRES_USER --clean --if-exists $POSTGRES_DB"
    else
        OUT_NAME="all-databases"
        DUMP_CMD="pg_dumpall -U $POSTGRES_USER --clean --if-exists"
    fi

    BACKUP_FILE="$CONTAINER_BACKUP_DIR/$OUT_NAME-$(date +"%Y%m%d%H%M").sql.gz"
    ERROR_LOG="$CONTAINER_BACKUP_DIR/$OUT_NAME-$(date +"%Y%m%d%H%M").err.log"

    docker exec -e PGPASSWORD="$POSTGRES_PWD" "$i" $DUMP_CMD 2>"$ERROR_LOG" \
        | gzip > "$BACKUP_FILE"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "FEHLER: pg_dump/pg_dumpall für Container $i fehlgeschlagen, siehe $ERROR_LOG"
    else
        rm -f "$ERROR_LOG"
        find "$CONTAINER_BACKUP_DIR" -name "*.gz" -daystart -mtime +$DAYS -delete
    fi
done
# Backup für MongoDB-Container
MONGO_CONTAINER=$(docker ps --format '{{.Names}}:{{.Image}}' | grep 'mongo' | cut -d":" -f1)
[ -n "$MONGO_CONTAINER" ] && echo "Erstelle Backup für MongoDB-Container: $MONGO_CONTAINER"
for i in $MONGO_CONTAINER; do
    CONTAINER_BACKUP_DIR="$BACKUPDIR/$i"
    mkdir -p "$CONTAINER_BACKUP_DIR"

    docker exec $i mongodump --archive | gzip > "$CONTAINER_BACKUP_DIR/mongo-$(date +"%Y%m%d%H%M").gz"

    find "$CONTAINER_BACKUP_DIR" -name "*.gz" -daystart -mtime +$DAYS -delete
done
# Backup für SQLite3-Container
SQLITE_CONTAINERS=$(docker ps --format '{{.Names}}:{{.Image}}' | grep 'sqlite' | cut -d":" -f1)
[ -n "$SQLITE_CONTAINERS" ] && echo "Erstelle Backup für SQLite3-Container: $SQLITE_CONTAINERS"
for i in $SQLITE_CONTAINERS; do
    SQLITE_BACKUP_DIR="$BACKUPDIR/$i"
    mkdir -p "$SQLITE_BACKUP_DIR"

    docker exec $i /usr/bin/sqlite3 /data/database.db .dump \
        | gzip > "$SQLITE_BACKUP_DIR/sqlite-$(date +"%Y%m%d%H%M").sql.gz"

    find "$SQLITE_BACKUP_DIR" -name "*.gz" -daystart -mtime +$DAYS -delete
done
# Backup für Bitwarden-Container
BITWARDEN_CONTAINERS=$(docker ps --format '{{.Names}}:{{.Image}}' | grep 'bitwardenrs' | cut -d":" -f1)
[ -n "$BITWARDEN_CONTAINERS" ] && echo "Erstelle Backup für Bitwarden-Container: $BITWARDEN_CONTAINERS"
for i in $BITWARDEN_CONTAINERS; do
    BITWARDEN_BACKUP_DIR="$BACKUPDIR/$i"
    mkdir -p "$BITWARDEN_BACKUP_DIR"

    docker exec $i /usr/bin/sqlite3 data/db.sqlite3 .dump \
        | gzip > "$BITWARDEN_BACKUP_DIR/bitwarden-$(date +"%Y%m%d%H%M").sql.gz"

    find "$BITWARDEN_BACKUP_DIR" -name "*.gz" -daystart -mtime +$DAYS -delete
done
# SQLite-Dateien auf dem Host (z. B. von Dashboards, VPN- oder Monitoring-Containern, die ihre Datenbank als Datei in
# einem gemounteten Ordner ablegen und deshalb von keiner der Container-Suchen oben erfasst werden).
# Gesucht wird in $SQLITE_SEARCH_PATHS nach *.db, *.sqlite und *.sqlite3; als Datenbank gilt eine Datei nur, wenn sie
# den SQLite-Kopf ("SQLite format 3") hat. Gesichert wird mit "sqlite3 .backup" (konsistent auch bei laufender Anwendung,
# WAL-Dateien eingeschlossen) und danach mit "PRAGMA quick_check" geprüft.
sqlite_ausgeschlossen() {
    local f="$1" muster
    local -a MUSTER
    IFS=: read -ra MUSTER <<< "$SQLITE_EXCLUDE"
    for muster in "${MUSTER[@]}"; do
        [[ "$f" == $muster ]] && return 0
    done
    return 1
}
SQLITE_BIN=$(command -v sqlite3)
SQLITE_DATEIEN=()
for suchpfad in $SQLITE_SEARCH_PATHS; do
    [ -d "$suchpfad" ] || continue
    while IFS= read -r -d '' datei; do
        sqlite_ausgeschlossen "$datei" && continue
        [ "$(head -c 15 "$datei" 2>/dev/null | tr -d '\0')" = "SQLite format 3" ] || continue
        SQLITE_DATEIEN+=("$datei")
    done < <(find "$suchpfad" -maxdepth "$SQLITE_MAXDEPTH" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -size +0 -print0 2>/dev/null)
done
if [ ${#SQLITE_DATEIEN[@]} -gt 0 ]; then
    echo "Erstelle Backup für SQLite-Dateien auf dem Host: ${#SQLITE_DATEIEN[@]} gefunden"
    if [ -z "$SQLITE_BIN" ]; then
        echo "WARNUNG: sqlite3 ist nicht installiert (apt install sqlite3) – SQLite-Dateien übersprungen."
    else
        for datei in "${SQLITE_DATEIEN[@]}"; do
            # Zielordner: vollständiger Pfad mit "__" statt "/", damit gleiche Dateinamen sich nicht überschneiden
            ZIELNAME=$(echo "${datei#/}" | sed 's|/|__|g')
            SQLITE_BACKUP_DIR="$BACKUPDIR/_sqlite-dateien/$ZIELNAME"
            mkdir -p "$SQLITE_BACKUP_DIR"
            STAMP=$(date +"%Y%m%d%H%M")
            BASIS=$(basename "$datei")
            ERROR_LOG="$SQLITE_BACKUP_DIR/$BASIS-$STAMP.err.log"
            TMP_DB=$(mktemp "$SQLITE_BACKUP_DIR/.tmp.XXXXXX")
            if "$SQLITE_BIN" "$datei" ".backup '$TMP_DB'" 2>"$ERROR_LOG" \
                && [ "$("$SQLITE_BIN" "$TMP_DB" 'PRAGMA quick_check;' 2>>"$ERROR_LOG" | head -n1)" = "ok" ]; then
                gzip -c "$TMP_DB" > "$SQLITE_BACKUP_DIR/$BASIS-$STAMP.gz"
                rm -f "$ERROR_LOG"
                find "$SQLITE_BACKUP_DIR" -name "*.gz" -daystart -mtime +$DAYS -delete
            else
                echo "FEHLER: Backup der SQLite-Datei $datei fehlgeschlagen, siehe $ERROR_LOG"
            fi
            rm -f "$TMP_DB"
        done
    fi
fi
echo "$(date +"%Y-%m-%d %H:%M:%S") Backup der Datenbanken abgeschlossen"
