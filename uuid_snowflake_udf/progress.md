# Progress Log

## 2026-09-14 — Project created (Phase 0)
- Created `projects/uuid_snowflake_udf/` with `_index.md`, `plan.md`, `findings.md`,
  `decisions.md`, `progress.md`.
- Seeded `findings.md` with the RFC 9562 UUIDv7 bit layout.
- Identified the **critical blocker**: need the exact Go function/library to know how the
  non-timestamp bits (`rand_a`, `rand_b`) are set — that decides whether bit-exact
  replication is possible (see `decisions.md` D-1, Q1/Q2).
- No repo/code links were provided in the framing yet.
- **Next:** Task 1 — get the Go reference from the user or locate the library.

## 2026-09-14 — Reference confirmed + Option A built & locally tested
- **Reference = `github.com/gofrs/uuid` `NewV7`/`NewV7AtTime`** → 74 crypto-random bits →
  exact replication IMPOSSIBLE (see findings.md, D-3).
- **User chose Option A**: Snowflake mints valid/unique/k-sortable UUIDv7s; matching gofrs
  not required.
- **Built** `sql/uuidv7.sql` (assembler + generators + decoders) and `sql/test_uuidv7.sql`
  (8 in-DB PASS/FAIL checks).
- **Local proof `verify_local.py` — ALL PASS**, incl. exact reconstruction of the RFC 9562
  §B.2 vector `017f22e2-79b0-7cc3-98c4-dc0c0c07398f`, format/version/variant over 5000
  samples, uniqueness, ms round-trip, k-sortability.
- **NOT run in Snowflake**: `CREATE FUNCTION` is state-changing + deny-listed → left for the
  user to run in a dev schema. The test *query* (`sql/test_uuidv7.sql`) is read-only and I
  can run it once the functions exist. `snow connection list` hung (no configured/interactive
  conn this session).
- **Next:** user deploys `sql/uuidv7.sql` to a dev DB/SCHEMA, then run `sql/test_uuidv7.sql`
  (expect 8× PASS). Then pick the production home (which DB/schema owns the UDF for the
  migration) and confirm the input column's type/precision + UTC assumption.

## 2026-09-14 (later) — Auth fixed, pivoted to PURE-SQL, validated in-DB, examples generated
- **Auth:** browser OAuth times out headless; ran `snow sql` in the **foreground** and it
  authed + cached the token (conn FAN_DATA_EXCHANGE_PROD, role FES_DATA_DEVELOPER, wh
  FDE_DEVELOPER_WH). Follow-up read-only queries then worked. (`sample` is a reserved word —
  alias tripped the first query.)
- **Key discovery:** Snowflake `TO_CHAR(n,'XXXXXXXXXXXX')` / `TO_NUMBER(h,'X...')` do int<->hex,
  AND `UUID_STRING()` is a v4 UUID whose 17th hex is already a valid variant nibble. So the
  whole thing is doable in **pure SQL** — no JavaScript. Rewrote `sql/uuidv7.sql` from JS to
  SQL UDFs (assembler forces the variant bits via BITAND/BITOR so any input hex is valid).
- **Validated READ-ONLY in Snowflake (no CREATE needed to prove it):**
  - 50k rows: distinct=50000, regex_ok=50000, ver_ok=50000, variant_ok=50000,
    ts_roundtrip_ok=50000.
  - RFC 9562 §B.2 reconstruction reproduced exactly: `017f22e2-79b0-7cc3-98c4-dc0c0c07398f`.
  - Real example rows generated (see `examples.md`), incl. same-ts-twice → different UUID.
- **Corrected fact:** RFC ms 0x017F22E279B0 = 2022-02-22 **19:22:22** UTC (not 20:22:22);
  fixed test #7. `verify_local.py` re-aligned to the SQL logic — all local tests still pass.
- **Deliverable to engineer:** `examples.md` (real outputs + contract + determinism proof).
- **Still needs the user:** `CREATE FUNCTION` deploy (deny-listed for me) + choose prod
  DB/schema + confirm input column type/precision & UTC. Post-deploy I can run
  `sql/test_uuidv7.sql` (read-only) for the in-DB 8×PASS.

## 2026-09-14 (final) — DEPLOYED to FES_USERS.ALEX_SOTIS + 8/8 tests pass
- User authorized creating in their personal schema `FES_USERS.ALEX_SOTIS`. Auth: had to
  approve a browser SSO popup (my `snow` calls get auto-backgrounded where OAuth can't
  complete; a fresh interactive login unblocked it).
- **Two SQL fixes needed at deploy time** (now in `sql/uuidv7.sql` + `sql/deploy_and_generate.sql`):
  (1) `UUIDV7_TIMESTAMP` return type — declared `TIMESTAMP_NTZ(9)` vs actual `(6)`; cast body
  to `::TIMESTAMP_NTZ(9)`. (2) `UUIDV7_ASSEMBLE` — a CTE/subquery inside a scalar SQL UDF
  throws `Unsupported subquery type ... inside Function object`; rewrote as one inline scalar
  expression (ts/rand exprs repeated, no `WITH`).
- **Privilege:** schema is OWNED by `SYSADMIN` (not FES_DATA_DEVELOPER). Deployed under
  `USE ROLE SYSADMIN` (in `deploy_and_generate.sql`), then granted USAGE on all 7 functions
  to `FES_DATA_DEVELOPER` so the normal role can call them.
- **Result:** all 7 functions created; 10 examples generated FROM the deployed `UUIDV7()`
  (real values now in `examples.md`); `sql/test_uuidv7.sql` = **8/8 PASS run as
  FES_DATA_DEVELOPER**.
- **DONE for the hand-off.** examples.md is ready to send. Functions live in FES_USERS.ALEX_SOTIS
  (personal schema) — if they need a permanent/shared home, move to a team schema + grant the
  team role.

## 2026-09-24 — Ordering requirement resolved + FINAL deploy/test/test-set
- **Ordering question closed:** receiving engineer confirmed **second/millisecond granularity is
  fine** — no sub-ms/nanosecond ordering needed. So the random-low-bits design is final; the
  gofrs intra-ms ordering difference is a non-issue. (Also confirmed the source `creation_time`
  is `TIMESTAMP_LTZ`, millisecond-only, 0 rows finer than ms — nanosecond was never available
  anyway.)
- **Final deploy (guarded version) to FES_USERS.ALEX_SOTIS** via `sql/deploy_and_generate.sql`
  (under SYSADMIN): all 7 functions created; 10-row test set generated (in `examples.md`, with
  decode-back + validity + verification instructions for the other engineer).
- **`sql/final_verify.sql`:** granted USAGE on all 7 functions to FES_DATA_DEVELOPER, then ran the
  suite AS FES_DATA_DEVELOPER → **9/9 PASS**; and confirmed the range guard fails loud
  (`UUIDV7_FROM_EPOCH_MS(-1)` → error `uuidv7_epoch_ms_out_of_range:-1`).
- **Canonical SQL to create the UDFs:** `sql/uuidv7.sql` (functions only) or
  `sql/deploy_and_generate.sql` (functions + example generation). Both current/guarded.
- **Auth note:** browser OAuth must be approved interactively; my calls auto-background and hang
  unless a fresh login is completed. Foreground + user approval works.
