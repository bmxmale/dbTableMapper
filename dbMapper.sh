#!/usr/bin/env bash
#
# dbMapper.sh — orchestrator: resolve a table set, then dump it.
#
# Phase 1 (dbFindTables.sh): match tables against a MySQL LIKE pattern and
# walk the foreign-key closure recursively (forward, reverse, or both).
# Phase 2 (dbDumpTables.sh): dump CREATE TABLE statements (and optionally
# data) for the resolved set, plus a Mermaid erDiagram (.mmd) of the FK
# relations between them.
#
# The two phases are usable on their own, e.g.:
#   ./dbFindTables.sh -p 'cache'                 # just list tables
#   ./dbFindTables.sh -p 'cache' | ./dbDumpTables.sh -b cache -o ./out
#
# Runs through ddev: must be invoked from inside the ddev project root.
#
# Usage:
#   ./dbMapper.sh -p 'sales_order%'
#   ./dbMapper.sh -p 'customer_entity' -o ./schemas -d
#   ./dbMapper.sh -p 'catalog_product%' -m forward -s
#   ./dbMapper.sh -p 'sales_order%' -n   # preview the resolved set only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIND="$SCRIPT_DIR/dbFindTables.sh"
DUMP="$SCRIPT_DIR/dbDumpTables.sh"

#----------------------------- defaults -------------------------------------
PATTERN=""
OUTPUT_DIR="./schemas"
WITH_DATA=false
DIRECTION="both"     # forward | reverse | both
SINGLE_FILE=true
LIST_ONLY=false

#----------------------------- helpers --------------------------------------
usage() {
    cat <<EOF
dbMapper.sh — dump CREATE TABLE for tables matching a pattern and all FK-related tables.

Usage:
  $0 -p <pattern> [options]

Options:
  -p PATTERN     MySQL LIKE pattern for initial tables (required)
                 e.g. 'sales_%', 'customer_entity'
                 If the pattern contains no '%', a trailing '%' is appended,
                 so 'cache' matches 'cache', 'cache_tag', ...
  -o DIR         Output directory (default: ./schemas)
  -d             Include INSERT statements (default: schema only)
  -m MODE        FK walk direction: forward | reverse | both (default: both)
                   forward  - tables referenced BY matched tables
                   reverse  - tables that REFERENCE matched tables
                   both     - both directions
  -s             Split into one file per table (default: single file)
  -n             List resolved tables only, do not dump
  -h             Show this help

Examples:
  $0 -p 'sales_order%'
  $0 -p 'customer_entity' -o ./schemas -d
  $0 -p 'catalog_product%' -m forward -s
  $0 -p 'sales_order%' -n
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

#----------------------------- arg parsing ----------------------------------
while getopts ":p:o:dm:snh" opt; do
    case $opt in
        p) PATTERN="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        d) WITH_DATA=true ;;
        m) DIRECTION="$OPTARG" ;;
        s) SINGLE_FILE=false ;;
        n) LIST_ONLY=true ;;
        h) usage; exit 0 ;;
        \?) die "invalid option: -$OPTARG (use -h for help)" ;;
        :)  die "option -$OPTARG requires an argument" ;;
    esac
done

# If -p was omitted, OPTIND never advances past it: $PATTERN is empty
# AND the next positional "$@" starts with a flag-like token. Catch both.
if [[ -z "$PATTERN" ]]; then
    if [[ "${1:-}" == -* && "${1:-}" != -- ]]; then
        die "option -p requires an argument (you passed '${1}' instead)"
    fi
    die "pattern is required (-p); see -h for help"
fi
# If -p was passed as bare "-p" (next arg starts with -), getopts ":" will set
# PATTERN to "" — the block above handles it. But if a user passes -p --foo or
# -p -x by mistake, $PATTERN would be "-foo"/"-x"; treat those as bad input.
[[ "$PATTERN" == -* ]] && die "option -p requires an argument (got '$PATTERN')"

[[ -x "$FIND" ]] || die "missing helper: $FIND"
[[ -x "$DUMP" ]] || die "missing helper: $DUMP"

#----------------------------- phase 1: find tables ---------------------------
TABLES=$("$FIND" -p "$PATTERN" -m "$DIRECTION")

echo ""
echo "==> Resolved tables:"
while IFS= read -r t; do
    printf '    - %s\n' "$t"
done <<< "$TABLES"

[[ "$LIST_ONLY" == true ]] && exit 0

#----------------------------- phase 2: dump ----------------------------------
DUMP_ARGS=( -o "$OUTPUT_DIR" )
[[ "$WITH_DATA" == true ]] && DUMP_ARGS+=( -d )
[[ "$SINGLE_FILE" == false ]] && DUMP_ARGS+=( -s )

# basename for output files: derived from the pattern
SAFE=$(echo "$PATTERN" | tr -c '[:alnum:]_' '-' | sed 's/^-*//; s/-*$//')
DUMP_ARGS+=( -b "$SAFE" )

printf '%s\n' "$TABLES" | "$DUMP" "${DUMP_ARGS[@]}"