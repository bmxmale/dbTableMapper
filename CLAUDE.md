# .db tools

Bash helpers to map a set of Magento database tables by LIKE pattern, walk
their foreign-key closure, and dump schemas plus a relations diagram.
All scripts run through **ddev** and must be invoked from the ddev project
root. Target DB is whatever `ddev mysql` connects to (schema `db`, MariaDB).

## Scripts

| File | Role |
|---|---|
| `dbMapper.sh` | Orchestrator: chains find → dump. Entry point for normal use. |
| `dbFindTables.sh` | Phase 1: match pattern, recursive FK-closure walk. Prints table names to **stdout** (one per line), progress logs to **stderr** — pipeable. |
| `dbDumpTables.sh` | Phase 2: dump CREATE TABLE (+ optional data) for a table set, plus a Mermaid relations file. |

## Typical usage

```bash
./.db/dbMapper.sh -p 'cache'                    # full run: find + dump to ./schemas
./.db/dbMapper.sh -p 'sales_order%' -m forward -s   # per-table files, forward FKs only
./.db/dbMapper.sh -p 'customer_entity' -n      # only print the resolved table list
./.db/dbMapper.sh -p 'cache' -d                 # include INSERT statements

# phases on their own
./.db/dbFindTables.sh -p 'cache'                                  # just list
./.db/dbFindTables.sh -p 'cache' | ./.db/dbDumpTables.sh -b cache # find → dump
./.db/dbDumpTables.sh -f ./schemas/cache_*.tables.txt            # re-dump a saved list
```

## Options (dbMapper.sh)

- `-p PATTERN` — MySQL LIKE pattern, **required**. If it contains no `%`,
  a trailing `%` is appended (`cache` → matches `cache`, `cache_tag`, ...).
- `-m forward|reverse|both` — FK walk direction (default `both`):
  forward = tables referenced by matches; reverse = tables referencing them.
- `-o DIR` — output directory (default `./schemas`).
- `-d` — include INSERT statements (default: schema only).
- `-s` — one file per table (default: single dump file).
- `-n` — list the resolved set only, no dump.

`dbDumpTables.sh` takes tables as positional args, via `-f FILE`, or on stdin;
`-b NAME` sets the base name for output files.

## Output files (in `-o DIR`)

- `<base>_<ts>.tables.txt` — resolved table list, one per line (reusable via `-f`).
- `<base>_<ts>.mmd` — Mermaid `erDiagram` of FK relations among the dumped
  tables (renders on GitHub / VS Code / mermaid.live). Cardinality:
  `||` = NOT NULL FK, `|o` = nullable; composite FKs collapse to one edge
  with columns joined by `_`; only edges where both endpoints are in the set
  are included.
- `<base>_<ts>.sql` — the dump (or a per-table directory with `-s`).

## Gotchas / conventions when editing these scripts

- **mysqldump needs the DB name first**: `ddev mysqldump "$DB" <tables>` — the
  first non-flag argument is the database, so never pass a bare table list.
  `$DB` is resolved via `SELECT DATABASE()`.
- **Escape `%` for ddev**: ddev's wrapper runs args through `printf`, so literal
  `%` in a query must be sent as `%%` (`SAFE_PATTERN=${PATTERN//%/%%}`).
- **Validate all user input** against `^[A-Za-z0-9_%]+$` (patterns) or
  `^[A-Za-z0-9_]+$` (table names, including anything read from a list file or
  stdin) before it reaches a query or a filename.
- `INFORMATION_SCHEMA.KEY_COLUMN_USAGE` has **no IS_NULLABLE column** — join
  `INFORMATION_SCHEMA.COLUMNS` to get FK nullability.
- ddev mysql output is tab-separated; parse with `IFS=$'\t' read -r`.
- Scripts use `set -euo pipefail`; progress logging on **stderr** so stdout
  stays machine-readable.