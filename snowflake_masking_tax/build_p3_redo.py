#!/usr/bin/env python3
"""Generate /tmp/p3_redo_runs.sql: 3 fangraph rebuilds.
  cell 1: BASELINE (no policy)
  cell 2: HASH / READER (plaintext branch)
  cell 3: CONST / READER (plaintext branch)
"""
from __future__ import annotations
import re

RUN_ID = "20260611A"
WH = "FDE_DEVELOPER_3XL_WH"
BASE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_BASE_{RUN_ID}"
SNAP = f"FES_USERS.ALEX_SOTIS.MTAX_FG_SNAPSHOTS_{RUN_ID}"
RESULT = f"FES_USERS.ALEX_SOTIS.MTAX_FG_RESULT_{RUN_ID}"
READER = f"TEST_PII_READER_{RUN_ID}"

POL_HASH = {
    "STRING": f"FES_USERS.ALEX_SOTIS.P3_MASK_STR_{RUN_ID}",
    "NUMBER": f"FES_USERS.ALEX_SOTIS.P3_MASK_NUM_{RUN_ID}",
    "DATE":   f"FES_USERS.ALEX_SOTIS.P3_MASK_DATE_{RUN_ID}",
}
POL_CONST = {
    "STRING": f"FES_USERS.ALEX_SOTIS.P3_CONST_STR_{RUN_ID}",
    "NUMBER": f"FES_USERS.ALEX_SOTIS.P3_CONST_NUM_{RUN_ID}",
    "DATE":   f"FES_USERS.ALEX_SOTIS.P3_CONST_DATE_{RUN_ID}",
}

STR_COLS = [
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
NUM_COLS = ["AAIA_PHONE","COLLECT_PHONE","FANGRAPH_PHONE","TOPPS_COM_PHONE"]
DATE_COLS = ["FANGRAPH_DOB","TOPPS_COM_DOB"]
TABLES = [BASE, SNAP]
# Per-table type override for TOPPS_COM_PHONE
SNAP_OVERRIDE = {"TOPPS_COM_PHONE": "STRING"}

def fam(t, c):
    if t == SNAP and c in SNAP_OVERRIDE: return SNAP_OVERRIDE[c]
    if c in NUM_COLS: return "NUMBER"
    if c in DATE_COLS: return "DATE"
    return "STRING"

def detach():
    out = []
    for t in TABLES:
        for c in STR_COLS + NUM_COLS + DATE_COLS:
            out.append(f"ALTER TABLE {t} MODIFY COLUMN {c} UNSET MASKING POLICY;")
    return "\n".join(out)

def attach(policies):
    out = []
    for t in TABLES:
        for c in STR_COLS + NUM_COLS + DATE_COLS:
            pol = policies[fam(t, c)]
            out.append(f"ALTER TABLE {t} MODIFY COLUMN {c} SET MASKING POLICY {pol};")
    return "\n".join(out)

SUSPEND = f"""\
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE {WH} SUSPEND;
    RETURN 'suspended';
EXCEPTION WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;"""

# Load resolved fangraph SQL (built earlier for Phase 3 step 1)
with open("/tmp/p3_fangraph_ctas.sql") as f:
    ctas_tmpl = f.read().strip()
# That file referenced 20260610A clones — swap to 20260611A
ctas_tmpl = ctas_tmpl.replace("_20260610A", f"_{RUN_ID}")
# Also rebuild the HASH() with new column list (cleaner to reuse — cols are identical schema)
with open("/tmp/fg_base_cols_20260611A.txt") as f:
    cols = [c.strip() for c in f.read().split(",")]
hash_expr = "HASH(" + ", ".join(cols) + ")"
# The original CTAS already has HASH expanded for 20260610A's columns. Re-build cleanly by
# regenerating from the original fangraph.sql with new tables. Simpler: just reuse the existing
# CTAS — col list is identical between days (verified 496 cols both times).

def cell(variant, role, policies, role_label):
    tag = f"mtax|phase=p3|variant={variant}|q=fangraph_rebuild|role={role_label}|rep=01"
    target = f"{RESULT}_{variant}_{role_label}"
    body = re.sub(r"FES_USERS\.ALEX_SOTIS\.MTAX_FG_RESULT_20260611A",
                  target, ctas_tmpl, count=1)
    pre = []
    pre.append(f"-- ============================================================")
    pre.append(f"-- {variant} / {role_label}")
    pre.append(f"-- ============================================================")
    pre.append("USE ROLE ACCOUNTADMIN;")
    pre.append(detach())
    if policies:
        pre.append(attach(policies))
    pre.append(SUSPEND)
    pre.append("USE SECONDARY ROLES NONE;")
    pre.append(f"USE ROLE {role};")
    pre.append(f"USE WAREHOUSE {WH};")
    pre.append("ALTER SESSION SET USE_CACHED_RESULT = FALSE;")
    pre.append(f"ALTER SESSION SET QUERY_TAG = '{tag}';")
    pre.append(body)
    return "\n".join(pre)


HEADER = f"""\
USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE {WH};
ALTER WAREHOUSE {WH} SET WAREHOUSE_SIZE = '3X-LARGE';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;
"""

FOOTER = f"""\
USE ROLE ACCOUNTADMIN;
{detach()}
ALTER SESSION UNSET QUERY_TAG;
SELECT 'phase 3 redo complete' AS status;
"""

parts = [HEADER]
parts.append(cell("BASELINE", "ACCOUNTADMIN", None, "ADMIN"))
parts.append(cell("HASH",     READER,         POL_HASH,  "READER"))
parts.append(cell("CONST",    READER,         POL_CONST, "READER"))
parts.append(FOOTER)

with open("/tmp/p3_redo_runs.sql", "w") as f:
    f.write("\n\n".join(parts))
print("written")
