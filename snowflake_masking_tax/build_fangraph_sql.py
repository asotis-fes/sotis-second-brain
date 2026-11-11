#!/usr/bin/env python3
"""Build a runnable, dbt-free version of dags/dbt/models/fangraph/fangraph/fangraph.sql.

- Expand {{ ref('...') }} → our clone FQNs.
- Expand {{ column_intersection_row_hash(...) }} → HASH(col1, col2, ..., col496).
- Replace the compile-time `statement('get_max_snapshot_ts', ...)` block
  with an inline scalar subquery.
- Wrap as CREATE OR REPLACE TABLE for materialization timing.
"""

from __future__ import annotations
import re
import sys

RUN_ID = "20260610A"
BASE_CLONE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_BASE_{RUN_ID}"
SNAP_CLONE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_SNAPSHOTS_{RUN_ID}"
RESULT_TABLE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_{RUN_ID}"

FANGRAPH_SQL = "/Users/alex.sotis/repos/fes-airflow/dags/dbt/models/fangraph/fangraph/fangraph.sql"
COLS_FILE = "/tmp/fg_base_cols.txt"


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("baseline", "masked"):
        print("usage: build_fangraph_sql.py {baseline|masked} > out.sql", file=sys.stderr)
        sys.exit(1)
    variant = sys.argv[1]

    with open(FANGRAPH_SQL) as f:
        sql = f.read()
    with open(COLS_FILE) as f:
        cols = [c.strip() for c in f.read().split(",")]

    hash_expr = "HASH(" + ", ".join(cols) + ")"

    # Strip the get_max_snapshot_ts call+set blocks entirely.
    # The original embeds the result as a string literal in WHERE; we'll
    # replace that with an inline subquery instead.
    sql = re.sub(
        r"\{%-?\s*call statement.*?endcall\s*-?%\}",
        "",
        sql,
        flags=re.DOTALL,
    )
    sql = re.sub(
        r"\{%-?\s*set max_snapshot_ts.*?-?%\}",
        "",
        sql,
        flags=re.DOTALL,
    )
    # The literal interpolation in WHERE → inline subquery
    sql = re.sub(
        r"WHERE snapshot_ts\s*=\s*'\{\{\s*max_snapshot_ts\s*\}\}'::TIMESTAMP",
        f"WHERE snapshot_ts = (SELECT MAX(snapshot_ts) FROM {SNAP_CLONE})",
        sql,
    )

    # Expand the two row-hash macro calls.
    sql = sql.replace(
        "{{ column_intersection_row_hash('fangraph_base', 'fangraph_snapshots') }}",
        hash_expr,
    )

    # Substitute the two refs.
    sql = sql.replace("{{ ref('fangraph_base') }}", BASE_CLONE)
    sql = sql.replace("{{ ref('fangraph_snapshots') }}", SNAP_CLONE)

    # Sanity: no remaining Jinja
    if "{{" in sql or "{%" in sql:
        print("ERROR: unresolved Jinja remaining in SQL", file=sys.stderr)
        print(sql[:2000], file=sys.stderr)
        sys.exit(2)

    sql = sql.strip()

    # Wrap as CREATE OR REPLACE TABLE for the test
    tag = f"mtax|phase=p3|variant={variant.upper()}|q=fangraph_rebuild"
    out = f"""-- ============================================================
-- PHASE 3 STEP 1: fangraph model rebuild, variant={variant}
-- ============================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE FDE_DEVELOPER_3XL_WH;
ALTER WAREHOUSE FDE_DEVELOPER_3XL_WH SET WAREHOUSE_SIZE = '3X-LARGE';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;
ALTER SESSION SET QUERY_TAG = '{tag}';

CREATE OR REPLACE TABLE {RESULT_TABLE} AS
{sql};

ALTER SESSION UNSET QUERY_TAG;
SELECT 'variant={variant} done' AS status,
       (SELECT COUNT(*) FROM {RESULT_TABLE}) AS row_count;
"""
    print(out)


if __name__ == "__main__":
    main()
