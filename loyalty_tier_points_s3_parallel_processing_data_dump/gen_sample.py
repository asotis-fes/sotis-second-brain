#!/usr/bin/env python3
"""Emit SAMPLE-restrict SQL: shrink the pinned snapshots to N accounts (Suneel's "1000 IDs first").

Workflow (de-collide model): run the FULL `gen.py setup` ONCE (it builds the expensive 3-tier map
+ de-collide + ledger snaps), THEN run this to restrict EFF_SNAP + LEDGER_SNAP to N sampled
effective loyalty ids that have ledger history. Because the UNCHANGED export builders
(sql_fmti/sql_overrides/sql_ledger_chunk) all JOIN EFF_SNAP / read LEDGER_SNAP, they then emit the
SAME N accounts — with ALL their history — across all three files, to the normal perf paths.

  export TP_ENV=perf TP_CUT="$(date '+%Y-%m-%d %H:%M:%S')"
  python3 gen.py setup      > 1.sql && snow sql -f 1.sql          # FULL snaps (map runs once)
  python3 gen_sample.py 1000 > s.sql && snow sql -f s.sql         # restrict snaps to 1000 accounts
  snow sql -q "GRANT SELECT ON ALL TABLES IN SCHEMA FES_USERS.ALEX_SOTIS TO ROLE ACCOUNTADMIN;"
  python3 gen.py verify     > v.sql && snow sql -f v.sql          # gate on the sample (missing=0)
  python3 gen.py count      > c.sql && snow sql -f c.sql          # -> 1 (all 1000 in chunk 0)
  python3 gen.py export 1   > 2.sql && snow sql -f 2.sql          # sample -> fmti/ override_cdc/ ledger/chunk_00000/

IMPORTANT: this shrinks EFF_SNAP + LEDGER_SNAP in place. Before the FULL run later, re-run
`gen.py setup` to rebuild them at full scope. Sampled ids are kept in
FES_USERS.ALEX_SOTIS.TP_SAMPLE_ACCOUNTS (share with Suneel so he pulls the same set).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_tp_migration as e

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000

SAMPLE_ACCT     = "FES_USERS.ALEX_SOTIS.TP_SAMPLE_ACCOUNTS"
TP_EFF_SAMPLE   = "FES_USERS.ALEX_SOTIS.TP_EFF_SAMPLE"
TP_LEDGER_SAMPLE = "FES_USERS.ALEX_SOTIS.TP_LEDGER_SAMPLE"

print(f"""
USE WAREHOUSE {e.WH};

-- {N} random effective loyalty ids that HAVE ledger history (so all 3 files populate) ------
CREATE OR REPLACE TRANSIENT TABLE {SAMPLE_ACCT} AS
SELECT loyalty_account_id
FROM (SELECT DISTINCT loyalty_account_id FROM {e.LEDGER_SNAP})
ORDER BY RANDOM() LIMIT {N};

-- restrict the de-collide snapshot to the sample (FMTI + overrides JOIN EFF_SNAP -> sample only)
CREATE OR REPLACE TRANSIENT TABLE {TP_EFF_SAMPLE} AS
SELECT * FROM {e.EFF_SNAP}
WHERE effective_loyalty_id IN (SELECT loyalty_account_id FROM {SAMPLE_ACCT});
CREATE OR REPLACE TRANSIENT TABLE {e.EFF_SNAP} AS SELECT * FROM {TP_EFF_SAMPLE};

-- restrict + re-chunk the ledger snapshot to the sample (fresh chunk_num -> all in chunk 0)
CREATE OR REPLACE TRANSIENT TABLE {TP_LEDGER_SAMPLE} AS
WITH s AS (
    SELECT * FROM {e.LEDGER_SNAP}
    WHERE loyalty_account_id IN (SELECT loyalty_account_id FROM {SAMPLE_ACCT})
),
r AS (
    SELECT loyalty_account_id,
           FLOOR((DENSE_RANK() OVER (ORDER BY loyalty_account_id) - 1) / {e.CHUNK_SIZE}) AS chunk_num
    FROM (SELECT DISTINCT loyalty_account_id FROM s)
)
SELECT s.* EXCLUDE (chunk_num), r.chunk_num
FROM s JOIN r USING (loyalty_account_id);
CREATE OR REPLACE TRANSIENT TABLE {e.LEDGER_SNAP} AS SELECT * FROM {TP_LEDGER_SAMPLE};

DROP TABLE IF EXISTS {TP_EFF_SAMPLE};
DROP TABLE IF EXISTS {TP_LEDGER_SAMPLE};
""")
