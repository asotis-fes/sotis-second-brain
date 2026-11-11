#!/usr/bin/env python3
"""Emit phased export SQL from the vetted builders in export_tp_migration.py, for `snow sql -f`.

Config via env: TP_ENV (perf|prod), TP_CUT ('YYYY-MM-DD HH24:MI:SS' freeze cutoff).

  export TP_ENV=perf TP_CUT='2026-08-03 12:00:00'
  python3 gen.py setup   > 1_setup.sql    && snow sql -f 1_setup.sql   # WRITE (run as your role)
  python3 gen.py verify  > v.sql          && snow sql -f v.sql         # read-only GATE (FK=0?)
  python3 gen.py count   > c.sql          && snow sql -f c.sql         # read-only -> N
  python3 gen.py export <N> > 2.sql       && snow sql -f 2.sql         # WRITE: COPY INTO (ACCOUNTADMIN)
  python3 gen.py cleanup > 4.sql          && snow sql -f 4.sql         # WRITE: drop transient tables

Notes:
- setup/verify/count run as your default role (owns the transient tables; grant Suneel SELECT).
- export prepends USE ROLE ACCOUNTADMIN for stage/integration usage. That role must also SELECT the
  snapshot tables — FMTI/overrides read TP_EFFECTIVE_SNAPSHOT (+ base FMTI/overrides), ledger reads
  TP_LEDGER_SNAPSHOT — so grant the whole schema before exporting:
    GRANT SELECT ON ALL TABLES IN SCHEMA FES_USERS.ALEX_SOTIS TO ROLE ACCOUNTADMIN;
  (or grant the stage+integration USAGE to your default role and drop the USE ROLE line.)
- For prod: repoint the integration to the prod role first (see snowflake-stage-setup.md).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_tp_migration as e

ENV = os.environ.get('TP_ENV', 'perf')
CUT = os.environ.get('TP_CUT', '')
mode = sys.argv[1] if len(sys.argv) > 1 else 'help'

if mode == 'setup':
    assert CUT, "set TP_CUT='YYYY-MM-DD HH24:MI:SS'"
    print(e.sql_setup(CUT))
elif mode == 'count':
    print(e.sql_count_chunks())
elif mode == 'ledger-snap':
    # rebuild ONLY the ledger snapshot at the cutover, reusing the EXISTING de-collide (EFF_SNAP).
    # Use when fmti/overrides were already exported and the ledger must key on that same EFF_SNAP.
    assert CUT, "set TP_CUT='<cutover>'"
    print(f"USE WAREHOUSE {e.WH};")
    print(e.sql_ledger_snapshot(CUT))
elif mode == 'chunks':
    # emit ONLY the N ledger-chunk COPYs (no fmti, no overrides). For exporting transactions
    # after fmti/overrides are already in the bucket.
    n = int(sys.argv[2])
    print("USE ROLE ACCOUNTADMIN;")
    print(f"USE WAREHOUSE {e.WH};")
    for i in range(n):
        print(e.sql_ledger_chunk(ENV, i))
elif mode == 'export':
    n = int(sys.argv[2])
    print("USE ROLE ACCOUNTADMIN;")
    print(f"USE WAREHOUSE {e.WH};")
    print(e.sql_fmti(ENV))
    print(e.sql_overrides(ENV))
    for i in range(n):
        print(e.sql_ledger_chunk(ENV, i))
elif mode == 'verify':
    print(e.sql_verify())
elif mode == 'cleanup':
    print(e.sql_cleanup())
else:
    print(__doc__)
