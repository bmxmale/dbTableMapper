#!/usr/bin/env bash
#
# dbFindTables.sh — phase 1 of dbMapper: resolve the table set.
#
# Matches tables against a MySQL LIKE pattern, then walks the foreign-key
# closure recursively (forward, reverse, or both).
#
# Resolved table names are printed to stdout, one per line, so the output
# can be piped straight into dbDumpTables.sh. All progress output goes to
# stderr. Runs through ddev: must be invoked from inside the ddev project
# root.
#
# Usage:
#   ./dbFindTables.sh -p 'cache'
#   ./dbFindTables.sh -p 'sales_order%' -m forward
#   ./dbFindTables.sh -p 'customer_entity' > tables.txt
#
set -euo pipefail

#----------------------------- defaults -------------------------------------
PATTERN=""
DIRECTION="both"     # forward | reverse | both

#----------------------------- helpers --------------------------------------
usage() {
    cat <<EOF
dbFindTables.sh — resolve tables matching a pattern plus their FK closure.

Usage:
  $0 -p <pattern> [options]

Options:
  -p PATTERN     MySQL LIKE pattern for initial tables (required)
                 e.g. 'sales_%', 'customer_entity'
                 If the pattern contains no '%', a trailing '%' is appended,
                 so 'cache' matches 'cache', 'cache_tag', ...
  -m MODE        FK walk direction: forward | reverse | both (default: both)
                   forward  - tables referenced BY matched tables
                   reverse  - tables that REFERENCE matched tables
                   both     - both directions
  -h             Show this help

Output: one table name per line on stdout; progress on stderr.

Examples:
  $0 -p 'sales_order%'
  $0 -p 'cache' > tables.txt
  $0 -p 'cache' | ./dbDumpTables.sh -o ./schemas
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

# Validate a MySQL LIKE pattern:
#   - non-empty
#   - first char is letter or underscore
#   - only contains ASCII letters, digits, underscore, or '%'
# Anything else (quotes, semicolons, spaces, control chars, dashes) is rejected
# so a malformed -p value can never become a query or a filename fragment.
validate_pattern() {
    local p="$1"
    [[ -n "$p" ]] || die "pattern is required (-p); see -h for help"
    [[ "$p" =~ ^[A-Za-z_][A-Za-z0-9_%]*$ ]] \
        || die "invalid pattern '$p' — use only letters, digits, '_' and '%' (first char must be a letter or '_')"
}

#----------------------------- arg parsing ----------------------------------
while getopts ":p:m:h" opt; do
    case $opt in
        p) PATTERN="$OPTARG" ;;
        m) DIRECTION="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) die "invalid option: -$OPTARG (use -h for help)" ;;
        :)  die "option -$OPTARG requires an argument" ;;
    esac
done
shift $((OPTIND - 1))

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

validate_pattern "$PATTERN"
case "$DIRECTION" in forward|reverse|both) ;; *) die "direction must be forward|reverse|both" ;; esac

# A bare pattern with no '%' means "prefix match": 'cache' → 'cache%',
# so it picks up suffix variants like cache_tag as well.
[[ "$PATTERN" != *%* ]] && PATTERN="${PATTERN}%"

#----------------------------- preflight ------------------------------------
command -v ddev >/dev/null 2>&1    || die "ddev not found in PATH"
ddev status >/dev/null 2>&1        || die "ddev project is not running (start with: ddev start)"
ddev mysql -e "SELECT 1" >/dev/null 2>&1 \
                                     || die "cannot reach the database via 'ddev mysql'"

#----------------------------- 1. match pattern ------------------------------
log "Matching pattern: $PATTERN"
# ddev's wrapper runs `printf` over the args, so any literal '%' in PATTERN
# gets eaten as a format specifier. Escape '%' → '%%' here; mysql sees '%'.
SAFE_PATTERN=${PATTERN//%/%%}
INITIAL_TABLES=$(ddev mysql -Nse "SHOW TABLES LIKE '${SAFE_PATTERN}'")
if [[ -z "$INITIAL_TABLES" ]]; then
    die "no tables matched pattern '$PATTERN'"
fi

log "Initial tables:"
printf '    - %s\n' $INITIAL_TABLES >&2

#----------------------------- 2. fetch FK map -------------------------------
log "Fetching foreign-key map..."
FK_MAP=$(ddev mysql -Nse "
    SELECT TABLE_NAME, REFERENCED_TABLE_NAME
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
    WHERE TABLE_SCHEMA = DATABASE()
      AND REFERENCED_TABLE_NAME IS NOT NULL
")

declare -A FWD=() REV=()
while IFS=$'\t' read -r SRC DST; do
    [[ -z "$SRC" || -z "$DST" ]] && continue
    FWD[$SRC]="${FWD[$SRC]:-} $DST"
    REV[$DST]="${REV[$DST]:-} $SRC"
done <<< "$FK_MAP"

#----------------------------- 3. BFS closure --------------------------------
log "Walking FK closure (direction: $DIRECTION)..."
declare -A SEEN=()
VISITED=()
QUEUE=( $INITIAL_TABLES )

while [[ ${#QUEUE[@]} -gt 0 ]]; do
    CUR=${QUEUE[0]}
    QUEUE=( "${QUEUE[@]:1}" )
    [[ -n "${SEEN[$CUR]:-}" ]] && continue
    SEEN[$CUR]=1
    VISITED+=( "$CUR" )

    NEXT=""
    case "$DIRECTION" in
        forward) NEXT="${FWD[$CUR]:-}" ;;
        reverse) NEXT="${REV[$CUR]:-}" ;;
        both)    NEXT="${FWD[$CUR]:-} ${REV[$CUR]:-}" ;;
    esac

    for n in $NEXT; do
        [[ -n "${SEEN[$n]:-}" ]] && continue
        QUEUE+=( "$n" )
    done
done

log "Resolved ${#VISITED[@]} tables."

#----------------------------- 4. emit list (stdout) --------------------------
printf '%s\n' "${VISITED[@]}"