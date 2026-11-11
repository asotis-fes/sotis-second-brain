#!/usr/bin/env python3
"""Generate /tmp/p5_runs.sql: 5-cell Phase 5 runner.

Query: simplified imprint_fg_us_customers (PII projection + PII WHERE).
Warehouse: FDE_DEVELOPER_SM_WH (SMALL — matches model's dev profile).
"""
from __future__ import annotations

RUN_ID = "20260611A"
WH = "FDE_DEVELOPER_SM_WH"
FG = f"FES_USERS.ALEX_SOTIS.MTAX_IMP_FG_{RUN_ID}"
RESULT_PREFIX = f"FES_USERS.ALEX_SOTIS.MTAX_IMP_RESULT_{RUN_ID}"
READER = f"TEST_PII_READER_{RUN_ID}"

POL_HASH  = {"STRING": f"FES_USERS.ALEX_SOTIS.P3_MASK_STR_{RUN_ID}",
             "NUMBER": f"FES_USERS.ALEX_SOTIS.P3_MASK_NUM_{RUN_ID}",
             "DATE":   f"FES_USERS.ALEX_SOTIS.P3_MASK_DATE_{RUN_ID}"}
POL_CONST = {"STRING": f"FES_USERS.ALEX_SOTIS.P3_CONST_STR_{RUN_ID}",
             "NUMBER": f"FES_USERS.ALEX_SOTIS.P3_CONST_NUM_{RUN_ID}",
             "DATE":   f"FES_USERS.ALEX_SOTIS.P3_CONST_DATE_{RUN_ID}"}

# 45 PII cols (same set as Phase 3) — apply policies to all 45 on the
# clone; only 9 are actually touched by this query but the prod setup
# would have all 45 attached.
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
NUM_COLS  = ["AAIA_PHONE","COLLECT_PHONE","FANGRAPH_PHONE","TOPPS_COM_PHONE"]
DATE_COLS = ["FANGRAPH_DOB","TOPPS_COM_DOB"]

# On the final fangraph table, TOPPS_COM_PHONE is consistent NUMBER (no per-table override needed).

def fam(c):
    if c in NUM_COLS: return "NUMBER"
    if c in DATE_COLS: return "DATE"
    return "STRING"

def detach():
    return "\n".join(f"ALTER TABLE {FG} MODIFY COLUMN {c} UNSET MASKING POLICY;"
                     for c in STR_COLS + NUM_COLS + DATE_COLS)

def attach(policies):
    return "\n".join(f"ALTER TABLE {FG} MODIFY COLUMN {c} SET MASKING POLICY {policies[fam(c)]};"
                     for c in STR_COLS + NUM_COLS + DATE_COLS)

SUSPEND = f"""\
EXECUTE IMMEDIATE $$
BEGIN
    ALTER WAREHOUSE {WH} SUSPEND;
    RETURN 'suspended';
EXCEPTION WHEN OTHER THEN RETURN 'already suspended (ok)';
END;
$$;"""

def ctas(target):
    return f"""\
CREATE OR REPLACE TABLE {target} AS
SELECT
    fg.fangraph_id,
    fg.fangraph_email,
    fg.fangraph_first_name,
    fg.fangraph_last_name,
    fg.fangraph_address_1,
    fg.fangraph_address_2,
    fg.fangraph_city,
    fg.fangraph_state,
    fg.fangraph_zip,
    fg.fangraph_country,
    fg.fangraph_account_access_available,
    fg.fangraph_phone,
    fg.fangraph_dob,
    fg.fangraph_age_range,
    fg.fangraph_gender,
    fg.fangraph_account_creation_timestamp AS account_creation_time,
    fg.commerce_customer_indicator,
    fg.fbg_customer_indicator,
    fg.live_customer_indicator,
    fg.events_customer_indicator,
    fg.fanapp_customer_indicator,
    fg.topps_com_customer_indicator,
    fg.topps_digital_customer_indicator,
    fg.collect_customer_indicator,
    fg.commerce_nfl_only,
    fg.fanatics_one_current_tier
FROM {FG} AS fg
WHERE
    (
        (fg.commerce_customer_indicator = 1
         AND fg.fangraph_account_access_available = 1
         AND fg.commerce_nfl_only = 0)
        OR
        (fg.fbg_customer_indicator = 1
         OR fg.live_customer_indicator = 1
         OR fg.events_customer_indicator = 1
         OR fg.topps_digital_customer_indicator = 1
         OR fg.topps_com_customer_indicator = 1
         OR fg.collect_customer_indicator = 1)
    )
    AND fg.fangraph_last_name IS NOT NULL
    AND fg.fangraph_first_name != '***Masked***'
    AND fg.fangraph_country = 'US';
"""

def cell(variant, role, policies, role_label, detach_first):
    tag = f"mtax|phase=p5|variant={variant}|q=imprint_fg_us_customers|role={role_label}|rep=01"
    target = f"{RESULT_PREFIX}_{variant}_{role_label}"
    parts = [
        f"-- ============================================================",
        f"-- {variant} / {role_label}",
        f"-- ============================================================",
        "USE ROLE ACCOUNTADMIN;",
    ]
    if detach_first:
        parts.append(detach())
    if policies:
        parts.append(attach(policies))
    parts.append(SUSPEND)
    parts.append("USE SECONDARY ROLES NONE;")
    parts.append(f"USE ROLE {role};")
    parts.append(f"USE WAREHOUSE {WH};")
    parts.append("ALTER SESSION SET USE_CACHED_RESULT = FALSE;")
    parts.append(f"ALTER SESSION SET QUERY_TAG = '{tag}';")
    parts.append(ctas(target))
    return "\n".join(parts)

HEADER = f"""\
USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE {WH};
ALTER WAREHOUSE {WH} SET WAREHOUSE_SIZE = 'SMALL';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;
"""

FOOTER = f"""\
USE ROLE ACCOUNTADMIN;
{detach()}
ALTER SESSION UNSET QUERY_TAG;
SELECT 'phase 5 complete' AS status;
"""

parts = [HEADER]
parts.append(cell("BASELINE", "ACCOUNTADMIN", None,      "ADMIN",    detach_first=True))
parts.append(cell("HASH",     READER,         POL_HASH,  "READER",   detach_first=False))
parts.append(cell("HASH",     "ACCOUNTADMIN", None,      "EXCLUDED", detach_first=False))
parts.append(cell("CONST",    READER,         POL_CONST, "READER",   detach_first=True))
parts.append(cell("CONST",    "ACCOUNTADMIN", None,      "EXCLUDED", detach_first=False))
parts.append(FOOTER)

with open("/tmp/p5_runs.sql", "w") as f:
    f.write("\n\n".join(parts))
print("written")
