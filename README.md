# dbTableMapper

Bash helpers to map a set of Magento database tables by `LIKE` pattern, walk
their foreign-key closure, and dump schemas plus a relations diagram.

All scripts run through **[ddev](https://ddev.com/)** and must be invoked from
the ddev project root. The target database is whatever `ddev mysql` connects
to (schema `db`, MariaDB).

## How it works

`dbMapper.sh` chains two phases, each of which is also usable on its own:

1. **`dbFindTables.sh`** — matches tables against a MySQL `LIKE` pattern, then
   walks the foreign-key closure recursively (forward, reverse, or both).
   Prints the resolved table names to **stdout** (one per line); progress logs
   go to **stderr**, so the output is pipeable.
2. **`dbDumpTables.sh`** — dumps `CREATE TABLE` statements (and optionally
   data) for a known table set, plus a Mermaid `erDiagram` of the FK relations
   among the dumped tables.

## Scripts

| File | Role |
|---|---|
| `dbMapper.sh` | Orchestrator: chains find → dump. Entry point for normal use. |
| `dbFindTables.sh` | Phase 1: match pattern, recursive FK-closure walk. |
| `dbDumpTables.sh` | Phase 2: dump schemas (+ optional data) and the Mermaid relations file. |

## Usage

```bash
./dbMapper.sh -p 'cache'                    # full run: find + dump to ./schemas
./dbMapper.sh -p 'sales_order%' -m forward -s   # per-table files, forward FKs only
./dbMapper.sh -p 'customer_entity' -n      # only print the resolved table list
./dbMapper.sh -p 'cache' -d                 # include INSERT statements
```

### Options (`dbMapper.sh`)

| Option | Description |
|---|---|
| `-p PATTERN` | MySQL `LIKE` pattern, **required**. If it contains no `%`, a trailing `%` is appended (`cache` → matches `cache`, `cache_tag`, …). |
| `-m MODE` | FK walk direction: `forward` / `reverse` / `both` (default `both`). `forward` = tables referenced by matches; `reverse` = tables referencing them. |
| `-o DIR` | Output directory (default `./schemas`). |
| `-d` | Include `INSERT` statements (default: schema only). |
| `-s` | One file per table (default: single dump file). |
| `-n` | List the resolved set only, no dump. |
| `-h` | Show help. |

### Running the phases separately

`dbFindTables.sh` takes the same `-p` / `-m` options and prints one table
name per line, so it pipes straight into `dbDumpTables.sh`:

```bash
./dbFindTables.sh -p 'cache'                                  # just list the tables
./dbFindTables.sh -p 'cache' | ./dbDumpTables.sh -b cache     # find → dump
./dbFindTables.sh -p 'customer_entity' > tables.txt           # save a list for later
```

`dbDumpTables.sh` accepts tables as positional arguments, via `-f FILE`, or
on stdin; `-b NAME` sets the base name for the output files:

```bash
./dbDumpTables.sh sales_order sales_order_grid -s     # explicit table names, per-table files
./dbDumpTables.sh -f ./schemas/cache_*.tables.txt -d  # re-dump a saved list, with data
```

| Option | Description |
|---|---|
| `-f FILE` | File with one table name per line (e.g. a `*.tables.txt` produced by this script). |
| `-o DIR` | Output directory (default `./schemas`). |
| `-b NAME` | Base name for output files (default `tables`). |
| `-d` | Include `INSERT` statements. |
| `-s` | One file per table. |
| `-h` | Show help. |

## Output files

Each run writes to `-o DIR` (default `./schemas`):

- `<base>_<ts>.tables.txt` — the resolved table list, one per line. Reusable
  later via `dbDumpTables.sh -f`.
- `<base>_<ts>.mmd` — a Mermaid `erDiagram` of the FK relations among the
  dumped tables. Renders on GitHub, in VS Code, and on
  [mermaid.live](https://mermaid.live).
- `<base>_<ts>.sql` — the dump itself (or a per-table directory with `-s`).

### Mermaid cardinality

```
parent ||--o{ child : "fk_column"
```

- Parent side: `||` = FK column is `NOT NULL` (each child row has exactly one
  parent); `|o` = nullable FK.
- Child side: `o{` = a parent row may have zero or more child rows.
- Composite FKs collapse onto one edge with the columns joined by `_`.
- Only edges where **both** endpoints are in the dumped set are included.

## Requirements

- A running [ddev](https://ddev.com/) project (`ddev start`) whose web
  container provides `mysql` / `mysqldump`.
- Bash with `set -euo pipefail` semantics (any modern Linux/macOS bash).