#!/usr/bin/env python3
"""Generate the Phase 3 Step 2 runner: 5 more fangraph rebuilds interleaved.

Existing state: 1 baseline run already completed (tag has no rep number).
This script emits 5 more runs in this order:
    masked rep=01 -> baseline rep=02 -> masked rep=02 -> baseline rep=03 -> masked rep=03

For each run:
  - Attach or detach all 45 PII policies on BOTH source clones
  - Suspend WH (tolerant of already-suspended)
  - CREATE OR REPLACE TABLE ... AS <resolved fangraph SQL>

All runs use ACCOUNTADMIN + USE SECONDARY ROLES NONE. P_COND_ISR checks
for TEST_PII_READER in session; ACCOUNTADMIN is not in that role set, so
admin runs hit the masked branch. This makes admin equivalent to the
prod dbt service role for measurement purposes.
"""

from __future__ import annotations
import sys

RUN_ID = "20260610A"
WH = "FDE_DEVELOPER_3XL_WH"
BASE_CLONE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_BASE_{RUN_ID}"
SNAP_CLONE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_SNAPSHOTS_{RUN_ID}"
RESULT_TABLE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_{RUN_ID}"

POL_STR  = f"FES_USERS.ALEX_SOTIS.P3_MASK_STR_{RUN_ID}"
POL_NUM  = f"FES_USERS.ALEX_SOTIS.P3_MASK_NUM_{RUN_ID}"
POL_DATE = f"FES_USERS.ALEX_SOTIS.P3_MASK_DATE_{RUN_ID}"

# 45 PII columns split by type-family
STRING_COLS = [
    "AAIA_ADDRESS","AAIA_ADDR_STREET","AAIA_EMAIL","AAIA_FIRST_NAME","AAIA_LAST_NAME",
    "COLLECT_COUNTRY","COLLECT_EMAIL","COLLECT_FIRST_NAME","COLLECT_LAST_NAME","COLLECT_STATE",
    "COMMERCE_ACCOUNT_EMAIL","COMMERCE_BILLING_STREET_ADDRESS1","COMMERCE_BILLING_STREET_ADDRESS2",
    "COMMERCE_FIRST_NAME","COMMERCE_LAST_NAME","COMMERCE_MOBILE_NUMBER",
    "EVENTS_ADDRESS_1","EVENTS_ADDRESS_2","EVENTS_EMAIL","EVENTS_FIRST_NAME","EVENTS_LAST_NAME","EVENTS_PHONE",
    "FANGRAPH_ADDRESS_1","FANGRAPH_ADDRESS_2","FANGRAPH_EMAIL","FANGRAPH_FIRST_NAME","FANGRAPH_LAST_NAME",
    "FBG_ADDRESS1","FBG_ADDRESS2","FBG_EMAIL","FBG_FIRST_NAME","FBG_LAST_NAME","FBG_NAME",
    "TOPPS_COM_BILLING_ADDRESS1","TOPPS_COM_BILLING_ADDRESS2","TOPPS_COM_EMAIL",
    "TOPPS_COM_FIRST_NAME","TOPPS_COM_LAST_NAME","TOPPS_DIGITAL_EMAIL",
]
NUMERIC_COLS = ["AAIA_PHONE","COLLECT_PHONE","FANGRAPH_PHONE","TOPPS_COM_PHONE"]
DATE_COLS    = ["FANGRAPH_DOB","TOPPS_COM_DOB"]

# Per-table overrides: column→family. TOPPS_COM_PHONE is NUMBER on base
# but VARCHAR on snapshots — confirmed via INFORMATION_SCHEMA after a
# type mismatch errored out the initial Step 2 run. All other 44 cols
# match between the two tables.
TABLE_OVERRIDES = {
    SNAP_CLONE: {"TOPPS_COM_PHONE": "STRING"},  # treat as string on snapshots
}

TABLES = [BASE_CLONE, SNAP_CLONE]


def family_for(table: str, col: str) -> str:
    """Return STRING / NUMERIC / DATE for the (table, col)."""
    override = TABLE_OVERRIDES.get(table, {}).get(col)
    if override:
        return override
    if col in NUMERIC_COLS:
        return "NUMERIC"
    if col in DATE_COLS:
        return "DATE"
    return "STRING"


def policy_setup() -> str:
    return f"""\
-- Policies: per-type, conditional on TEST_PII_READER_{RUN_ID} via IS_ROLE_IN_SESSION
CREATE OR REPLACE MASKING POLICY {POL_STR} AS
    (val STRING) RETURNS STRING ->
    CASE WHEN IS_ROLE_IN_SESSION('TEST_PII_READER_{RUN_ID}') THEN val
         ELSE SHA2(val, 256) END;

CREATE OR REPLACE MASKING POLICY {POL_NUM} AS
    (val NUMBER) RETURNS NUMBER ->
    CASE WHEN IS_ROLE_IN_SESSION('TEST_PII_READER_{RUN_ID}') THEN val
         ELSE HASH(val) END;

CREATE OR REPLACE MASKING POLICY {POL_DATE} AS
    (val DATE) RETURNS DATE ->
    CASE WHEN IS_ROLE_IN_SESSION('TEST_PII_READER_{RUN_ID}') THEN val
         ELSE DATE_TRUNC('YEAR', val) END;
"""


def attach_block() -> str:
    lines = ["-- Attach all 45 policies on both clones (per-table family map)"]
    policy_for = {"STRING": POL_STR, "NUMERIC": POL_NUM, "DATE": POL_DATE}
    all_cols = STRING_COLS + NUMERIC_COLS + DATE_COLS
    for table in TABLES:
        for c in all_cols:
            pol = policy_for[family_for(table, c)]
            lines.append(f"ALTER TABLE {table} MODIFY COLUMN {c} SET MASKING POLICY {pol};")
    return "\n".join(lines)


def detach_block() -> str:
    lines = ["-- Detach all 45 policies on both clones"]
    for table in TABLES:
        for c in STRING_COLS + NUMERIC_COLS + DATE_COLS:
            lines.append(f"ALTER TABLE {table} MODIFY COLUMN {c} UNSET MASKING POLICY;")
    return "\n".join(lines)


def suspend_block() -> str:
    return f"""\
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE {WH} SUSPEND;
    RETURN 'suspended';
EXCEPTION
    WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;"""


def ctas_block(variant: str, rep: int, fangraph_sql_path: str) -> str:
    """Emit a CTAS run with the right tag. fangraph_sql_path is read inline."""
    with open(fangraph_sql_path) as f:
        sql = f.read()
    tag = f"mtax|phase=p3|variant={variant}|q=fangraph_rebuild|rep={rep:02d}"
    return f"""\
USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES NONE;
USE WAREHOUSE {WH};
ALTER SESSION SET QUERY_TAG = '{tag}';
{sql.strip()}
"""


HEADER = f"""\
-- ============================================================
-- PHASE 3 STEP 2: 5 fangraph rebuilds, interleaved
-- Run ID: {RUN_ID}
-- WH: {WH} (3X-LARGE)
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE {WH};
ALTER WAREHOUSE {WH} SET WAREHOUSE_SIZE = '3X-LARGE';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;

{policy_setup()}
"""


FOOTER = f"""\
-- Final state: detach everything so cleanup is straightforward
USE ROLE ACCOUNTADMIN;
{detach_block()}

ALTER SESSION UNSET QUERY_TAG;
SELECT 'phase 3 step 2 complete' AS status;
"""


def main():
    # The resolved fangraph CTAS lives in /tmp/p3_fangraph_ctas.sql
    # which is the inner statement of /tmp/p3_baseline.sql without the
    # session-setup wrapper.
    ctas_path = "/tmp/p3_fangraph_ctas.sql"

    schedule = [
        ("MASKED",   1, True),   # attach, then run
        ("BASELINE", 2, False),  # detach, then run
        ("MASKED",   2, True),
        ("BASELINE", 3, False),
        ("MASKED",   3, True),
    ]

    parts = [HEADER]
    for variant, rep, attach in schedule:
        parts.append(f"\n-- ============================================================\n"
                     f"-- {variant} rep={rep:02d}\n"
                     f"-- ============================================================")
        parts.append(attach_block() if attach else detach_block())
        parts.append(suspend_block())
        parts.append(ctas_block(variant, rep, ctas_path))
    parts.append(FOOTER)
    print("\n".join(parts))


if __name__ == "__main__":
    main()
