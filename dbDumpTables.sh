#!/usr/bin/env bash
#
# dbDumpTables.sh — phase 2 of dbMapper: dump schemas for a known table set.
#
# Takes a list of table names (as arguments, via -f FILE, or on stdin) and
# dumps CREATE TABLE statements (and optionally data) for them, into a single
# file or one file per table. Also writes a Mermaid erDiagram (.mmd) showing
# the FK relations between the dumped tables — renders on GitHub, in VS Code,
# on mermaid.live, ... Runs through ddev: must be invoked from inside
# the ddev project root.
#
# Pairs with dbFindTables.sh:
#   ./.db/dbFindTables.sh -p 'cache' | ./.db/dbDumpTables.sh -o ./schemas
#
set -euo pipefail

#----------------------------- defaults -------------------------------------
LIST_FILE=""
OUTPUT_DIR="./schemas"
BASENAME="tables"
WITH_DATA=false
SINGLE_FILE=true

#----------------------------- helpers --------------------------------------
usage() {
    cat <<EOF
dbDumpTables.sh — dump CREATE TABLE for a given set of tables.

Usage:
  $0 [-f FILE | TABLE...] [options]

Input (one of):
  TABLE...       table names as positional arguments
  -f FILE        file with one table name per line
                (e.g. a *.tables.txt produced here, or dbFindTables.sh output)
  stdin          piped table list, one name per line

Options:
  -o DIR         Output directory (default: ./schemas)
  -b NAME        Base name for output files (default: tables)
  -d             Include INSERT statements (default: schema only)
  -s             Split into one file per table (default: single file)
  -h             Show this help

Output files (in -o DIR):
  <name>_<ts>.tables.txt    resolved table list, one per line
  <name>_<ts>.mmd           Mermaid erDiagram of the FK relations
  <name>_<ts>.sql           the dump (single file), or a per-table directory

Examples:
  ./.db/dbFindTables.sh -p 'cache' | $0 -b cache
  $0 -f ./schemas/cache_tables.txt -d
  $0 sales_order sales_order_grid -s
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

# Table names come from files or stdin as well as argv, so re-validate them
# before they reach mysqldump: letters, digits, underscore only.
validate_table() {
    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid table name '$1'"
}

#----------------------------- arg parsing ----------------------------------
while getopts ":f:o:b:dsh" opt; do
    case $opt in
        f) LIST_FILE="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        b) BASENAME="$OPTARG" ;;
        d) WITH_DATA=true ;;
        s) SINGLE_FILE=false ;;
        h) usage; exit 0 ;;
        \?) die "invalid option: -$OPTARG (use -h for help)" ;;
        :)  die "option -$OPTARG requires an argument" ;;
    esac
done
shift $((OPTIND - 1))

TABLES=()
if [[ -n "$LIST_FILE" ]]; then
    [[ -f "$LIST_FILE" ]] || die "list file not found: $LIST_FILE"
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        TABLES+=( "$t" )
    done < "$LIST_FILE"
elif [[ $# -gt 0 ]]; then
    TABLES=( "$@" )
elif [[ ! -t 0 ]]; then
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        TABLES+=( "$t" )
    done
else
    die "no tables given — pass names as arguments, use -f FILE, or pipe a list on stdin (see -h)"
fi

[[ ${#TABLES[@]} -gt 0 ]] || die "table list is empty"
for t in "${TABLES[@]}"; do validate_table "$t"; done

#----------------------------- preflight ------------------------------------
command -v ddev >/dev/null 2>&1    || die "ddev not found in PATH"
ddev status >/dev/null 2>&1        || die "ddev project is not running (start with: ddev start)"
ddev mysql -e "SELECT 1" >/dev/null 2>&1 \
                                     || die "cannot reach the database via 'ddev mysql'"

# mysqldump interprets its first non-option argument as the DATABASE name,
# tables follow it. Resolve the schema so tables can never be mistaken
# for a database name.
DB=$(ddev mysql -Nse "SELECT DATABASE()")
[[ -n "$DB" ]] || die "could not determine the current database"

mkdir -p "$OUTPUT_DIR"

#----------------------------- dump schemas ----------------------------------
SAFE=$(echo "$BASENAME" | tr -c '[:alnum:]_' '-' | sed 's/^-*//; s/-*$//')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Always keep the table list next to the dump for later reference
LIST_FILE="$OUTPUT_DIR/${SAFE}_${TIMESTAMP}.tables.txt"
printf '%s\n' "${TABLES[@]}" > "$LIST_FILE"
log "Table list saved to: $LIST_FILE"

#----------------------------- relations (mermaid) ----------------------------
# Describe the FK relations among the dumped tables as a Mermaid erDiagram.
# Cardinality, e.g. `parent |o--o{ child : "fk_column"`:
#   parent side : || = FK column NOT NULL (each child has exactly one parent)
#                 |o = FK column nullable
#   child side  : o{ = a parent row may have zero or more children
log "Fetching FK relations among the ${#TABLES[@]} tables..."
FK_MAP=$(ddev mysql -Nse "
    SELECT k.TABLE_NAME, k.COLUMN_NAME, c.IS_NULLABLE, k.CONSTRAINT_NAME, k.REFERENCED_TABLE_NAME
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE k
    JOIN INFORMATION_SCHEMA.COLUMNS c
      ON  c.TABLE_SCHEMA = k.TABLE_SCHEMA
      AND c.TABLE_NAME   = k.TABLE_NAME
      AND c.COLUMN_NAME  = k.COLUMN_NAME
    WHERE k.TABLE_SCHEMA = DATABASE()
      AND k.REFERENCED_TABLE_NAME IS NOT NULL
")

declare -A IN_SET=()
for t in "${TABLES[@]}"; do IN_SET[$t]=1; done

# One entry per FK constraint; composite FKs span several rows in
# KEY_COLUMN_USAGE, so collapse them onto one edge with the columns
# joined by '_'.
declare -A EDGE_NULLABLE=() EDGE_LABEL=()
while IFS=$'\t' read -r SRC COL NULLABLE CONSTRAINT DST; do
    [[ -z "$SRC" || -z "$DST" ]] && continue
    [[ -n "${IN_SET[$SRC]:-}" && -n "${IN_SET[$DST]:-}" ]] || continue
    KEY="${DST}"$'\t'"${SRC}"$'\t'"${CONSTRAINT}"
    EDGE_NULLABLE[$KEY]="$NULLABLE"
    EDGE_LABEL[$KEY]="${EDGE_LABEL[$KEY]:-}${EDGE_LABEL[$KEY]:+_}$COL"
done <<< "$FK_MAP"

MERMAID_FILE="$OUTPUT_DIR/${SAFE}_${TIMESTAMP}.mmd"
{
    echo "%% FK relations for tables dumped by dbDumpTables.sh"
    echo "erDiagram"
    while IFS=$'\t' read -r DST SRC CONSTRAINT; do
        [[ -z "$DST" ]] && continue
        KEY="${DST}"$'\t'"${SRC}"$'\t'"${CONSTRAINT}"
        LEFT="||"
        [[ "${EDGE_NULLABLE[$KEY]}" == "YES" ]] && LEFT="|o"
        printf '    %s %s--o{ %s : "%s"\n' \
            "$DST" "$LEFT" "$SRC" "${EDGE_LABEL[$KEY]}"
    done < <(printf '%s\n' "${!EDGE_LABEL[@]}" | sort)
} > "$MERMAID_FILE"
log "Relations graph saved to: $MERMAID_FILE"

DUMP_FLAGS=( --no-create-db --skip-lock-tables --skip-add-locks )
[[ "$WITH_DATA" == false ]] && DUMP_FLAGS+=( --no-data )

if [[ "$SINGLE_FILE" == true ]]; then
    OUT="$OUTPUT_DIR/${SAFE}_${TIMESTAMP}.sql"
    log "Dumping schema to $OUT"
    ddev mysqldump "${DUMP_FLAGS[@]}" "$DB" "${TABLES[@]}" > "$OUT"
else
    OUT_DIR="$OUTPUT_DIR/${SAFE}_${TIMESTAMP}"
    mkdir -p "$OUT_DIR"
    log "Dumping per-table schemas to $OUT_DIR"
    for t in "${TABLES[@]}"; do
        log "    - $t"
        ddev mysqldump "${DUMP_FLAGS[@]}" "$DB" "$t" > "$OUT_DIR/${t}.sql"
    done
fi

log "Done."