#!/usr/bin/env python3
"""Generate run_20260610a_phase2_stage_b.sql from the matrix spec.

Each cell pattern: detach old policy → attach new policy (if any) →
suspend WH (error-tolerantly) → switch role → harness loop of 10 reps.
"""

from __future__ import annotations
from textwrap import dedent

import os

RUN_ID = "20260610A"
WH = "FDE_DEVELOPER_SM_WH"
TABLE = f"FES_USERS.ALEX_SOTIS.MTAX_FG_{RUN_ID}"
COL = "FANGRAPH_EMAIL"
MC_COLS = ["FANGRAPH_EMAIL", "FANGRAPH_FIRST_NAME", "FANGRAPH_LAST_NAME", "FANGRAPH_ADDRESS_1"]
N_REPS = 10

# Cell-range filter: emit only cells in [START_CELL, END_CELL].
# Defaults to the full matrix. Override via env to resume after a partial run.
START_CELL = int(os.environ.get("START_CELL", "1"))
END_CELL   = int(os.environ.get("END_CELL", "99"))


def _esc(s: str) -> str:
    """Escape single quotes for embedding inside an EXECUTE IMMEDIATE '<sql>' wrapper."""
    return s.replace("'", "''")

QUERIES = {
    "Q1": f"SELECT MAX(LENGTH({COL})) FROM {TABLE}",
    "Q2": f"SELECT COUNT(DISTINCT {COL}) FROM {TABLE}",
    "Q3": f"SELECT COUNT(*) FROM {TABLE} WHERE {COL} = 'NEVER_MATCH_FOR_MTAX_TEST@example.com'",
    "Q4": f"SELECT MAX(LENGTH(FANGRAPH_STATE)) FROM {TABLE}",
}

POLICY_FQN = {
    "BASELINE":   None,
    "P_NULL":     f"FES_USERS.ALEX_SOTIS.P_NULL_{RUN_ID}",
    "P_HASH":     f"FES_USERS.ALEX_SOTIS.P_HASH_{RUN_ID}",
    "P_COND":     f"FES_USERS.ALEX_SOTIS.P_COND_{RUN_ID}",
    "P_COND_ISR": f"FES_USERS.ALEX_SOTIS.P_COND_ISR_{RUN_ID}",
}

ROLE_LABELS = {
    "ADMIN":    "ACCOUNTADMIN",
    "READER":   f"TEST_PII_READER_{RUN_ID}",
    "EXCLUDED": f"TEST_PII_EXCLUDED_{RUN_ID}",
}


def cell(idx: int, variant: str, q: str, role_label: str) -> str:
    """Emit one cell."""
    role_name = ROLE_LABELS[role_label]
    policy_fqn = POLICY_FQN[variant]
    tag = f"mtax|phase=p2|variant={variant}|q={q}|role={role_label}"
    query_sql = QUERIES[q]

    attach = (
        f"ALTER TABLE {TABLE} MODIFY COLUMN {COL} UNSET MASKING POLICY;"
        if policy_fqn is None
        else (
            f"ALTER TABLE {TABLE} MODIFY COLUMN {COL} UNSET MASKING POLICY;\n"
            f"ALTER TABLE {TABLE} MODIFY COLUMN {COL} SET MASKING POLICY {policy_fqn};"
        )
    )

    return dedent(f"""\
    -- ============================================================
    -- CELL {idx:02d}: variant={variant} q={q} role={role_label}
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    {attach}

    -- Suspend WH to clear local cache (tolerant of 'already suspended')
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE {WH} SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE {role_name};
    USE WAREHOUSE {WH};

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT {N_REPS};
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT '{tag}';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE '{_esc(query_sql)}';
            i := i + 1;
        END WHILE;
        RETURN 'cell {idx:02d} done';
    END;
    $$;
    """)


def multi_column_cells(start_idx: int) -> str:
    """The two MC cells: baseline 4-col scan, then P_HASH on 4 cols."""
    cols_proj = ", ".join(f"MAX(LENGTH({c}))" for c in MC_COLS)
    mc_query = f"SELECT {cols_proj} FROM {TABLE}"
    out = []

    # MC1: baseline (no policies on any of the 4)
    out.append(dedent(f"""\
    -- ============================================================
    -- CELL {start_idx:02d}: variant=BASELINE_4COL q=Q_MC role=ADMIN
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    """))
    for c in MC_COLS:
        out.append(f"ALTER TABLE {TABLE} MODIFY COLUMN {c} UNSET MASKING POLICY;\n")
    out.append(dedent(f"""\
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE {WH} SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE ACCOUNTADMIN;
    USE WAREHOUSE {WH};

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT {N_REPS};
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=BASELINE_4COL|q=Q_MC|role=ADMIN';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE '{_esc(mc_query)}';
            i := i + 1;
        END WHILE;
        RETURN 'cell {start_idx:02d} done';
    END;
    $$;
    """))

    # MC2: P_HASH on all 4 cols
    p_hash = POLICY_FQN["P_HASH"]
    out.append(dedent(f"""\
    -- ============================================================
    -- CELL {start_idx + 1:02d}: variant=P_HASH_4COL q=Q_MC role=ADMIN
    -- ============================================================
    USE ROLE ACCOUNTADMIN;
    """))
    for c in MC_COLS:
        out.append(f"ALTER TABLE {TABLE} MODIFY COLUMN {c} SET MASKING POLICY {p_hash};\n")
    out.append(dedent(f"""\
    EXECUTE IMMEDIATE $$
    BEGIN
        ALTER WAREHOUSE {WH} SUSPEND;
        RETURN 'suspended';
    EXCEPTION
        WHEN OTHER THEN RETURN 'already suspended (ok)';
    END;
    $$;

    USE SECONDARY ROLES NONE;
    USE ROLE ACCOUNTADMIN;
    USE WAREHOUSE {WH};

    EXECUTE IMMEDIATE $$
    DECLARE
        n INTEGER DEFAULT {N_REPS};
        i INTEGER DEFAULT 1;
        base_tag STRING DEFAULT 'mtax|phase=p2|variant=P_HASH_4COL|q=Q_MC|role=ADMIN';
        rep_tag STRING;
    BEGIN
        WHILE (i <= n) DO
            rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
            EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
            EXECUTE IMMEDIATE '{_esc(mc_query)}';
            i := i + 1;
        END WHILE;
        RETURN 'cell {start_idx + 1:02d} done';
    END;
    $$;
    """))

    # Detach for cleanup
    out.append(dedent(f"""\
    -- Detach MC policies before cleanup
    USE ROLE ACCOUNTADMIN;
    """))
    for c in MC_COLS:
        out.append(f"ALTER TABLE {TABLE} MODIFY COLUMN {c} UNSET MASKING POLICY;\n")
    out.append("\n")

    return "".join(out)


def matrix() -> list[tuple[str, str, str]]:
    """Build the (variant, q, role_label) list in interleaved order."""
    cells = []
    for q in ("Q1", "Q2", "Q3"):
        cells.append(("BASELINE",   q, "ADMIN"))
        cells.append(("P_NULL",     q, "ADMIN"))
        cells.append(("P_HASH",     q, "ADMIN"))
        cells.append(("P_COND",     q, "READER"))
        cells.append(("P_COND",     q, "EXCLUDED"))
        cells.append(("P_COND_ISR", q, "READER"))
        cells.append(("P_COND_ISR", q, "EXCLUDED"))
    cells.append(("BASELINE", "Q4", "ADMIN"))
    return cells


HEADER = dedent(f"""\
-- ============================================================
-- MASKING TAX - PHASE 2 STAGE B: full 22-cell matrix + MC
-- Run ID:     {RUN_ID}
-- Warehouse:  {WH} (SMALL)
-- Table:      {TABLE}
-- Masked col: {COL}
-- N reps:     {N_REPS} per cell
-- ============================================================
-- ASSUMES STAGE A ALREADY RAN (clone exists, grants in place,
-- gut-check passed).
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;
USE WAREHOUSE {WH};
ALTER WAREHOUSE {WH} SET WAREHOUSE_SIZE = 'SMALL';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
USE SECONDARY ROLES NONE;

-- Grant USAGE on SMALL warehouse to test roles (so cells under
-- READER/EXCLUDED can run there)
GRANT USAGE ON WAREHOUSE {WH} TO ROLE TEST_PII_READER_{RUN_ID};
GRANT USAGE ON WAREHOUSE {WH} TO ROLE TEST_PII_EXCLUDED_{RUN_ID};

SELECT CURRENT_ROLE() AS r, CURRENT_WAREHOUSE() AS w,
       CURRENT_SECONDARY_ROLES() AS sr;

""")


FOOTER = dedent(f"""\
-- ============================================================
-- POST-RUN: detach any remaining policy, unset query tag
-- ============================================================
USE ROLE ACCOUNTADMIN;
ALTER TABLE {TABLE} MODIFY COLUMN {COL} UNSET MASKING POLICY;
ALTER SESSION UNSET QUERY_TAG;

-- Results pull happens in a separate script (run_20260610a_phase2_results.sql)
-- so we can re-pull without re-running the matrix.
SELECT 'phase 2 matrix complete' AS status;
""")


def main():
    parts = [HEADER]
    cells = matrix()
    for idx, (variant, q, role) in enumerate(cells, start=1):
        if START_CELL <= idx <= END_CELL:
            parts.append(cell(idx, variant, q, role))
    mc_start = len(cells) + 1
    # MC1 = mc_start, MC2 = mc_start + 1
    if START_CELL <= mc_start + 1 and mc_start <= END_CELL:
        parts.append(multi_column_cells(start_idx=mc_start))
    parts.append(FOOTER)
    print("".join(parts))


if __name__ == "__main__":
    main()
