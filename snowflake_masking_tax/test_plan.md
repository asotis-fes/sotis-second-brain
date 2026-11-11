# Snowflake Masking Policy Performance Tax — Test Plan

**Goal:** Produce defensible numbers on the time/credit cost of adding column masking policies to a table, vs. an unmasked baseline. Output will inform the FES Data team's decision between (a) Snowflake column masking policies and (b) the `[schema]_pii` + view-on-top approach used today.

**Scope of this document:** masking policy tax only. The view-based alternative is out of scope here.

**Run environment:** Snowflake UI, signed in as alex.sotis (admin). All objects created in `FES_USERS.ALEX_SOTIS`. All roles created here are scratch — terraform will own the real ones.

---

## 1. Approach

### 1.1 What we're actually measuring

A masking policy adds work in two places:

1. **Compilation time** — the policy expression is inlined into the query plan; the optimizer must evaluate eligibility (role checks, `INVOKER_*` functions, etc.) per applicable column.
2. **Execution time** — the masking expression is evaluated per row, per masked column referenced in the projection / predicate. For a `SHA2()` mask over 180M rows that's 180M hash ops; for a constant `'***'` mask it's effectively free per row.

We want both numbers, separately, because the team's tolerance is different for "policy adds 200ms of compile" vs. "policy doubles wall-clock on a 30s query."

### 1.2 Test matrix

Four policy variants × three query patterns × two roles for conditional variants × N=10 reps.

| Variant | Body | What it isolates |
|---|---|---|
| `P_NULL` | `RETURNS STRING -> NULL` | Lower bound — no work, no branching. The compile-time tax in isolation. |
| `P_HASH` | `RETURNS STRING -> SHA2(val, 256)` | Per-row CPU cost. Realistic for hash-masking PII. |
| `P_COND` | `RETURNS STRING -> CASE WHEN CURRENT_ROLE() = 'TEST_PII_READER_<run_id>' THEN val ELSE SHA2(val, 256) END` | Cheap branching path: primary-role-only string compare + hash. |
| `P_COND_ISR` | `RETURNS STRING -> CASE WHEN IS_ROLE_IN_SESSION('TEST_PII_READER_<run_id>') THEN val ELSE SHA2(val, 256) END` | Real-production branching: walks the session role set (works with secondary roles, which production policies at FBG typically rely on). Likely costlier than `P_COND`. |

Query patterns (against the table from §6):

| Pattern | Why |
|---|---|
| Q1: `SELECT MAX(LENGTH(<masked_col>)) FROM t` | Forces full-table evaluation of the mask in the projection. **Not** `SELECT col FROM t LIMIT 1000` — that would push LIMIT past the projection and only fire the mask on 1000 rows, giving a near-zero, misleading delta. |
| Q2: `SELECT COUNT(DISTINCT <masked_col>) FROM t` | Full evaluation of mask plus distinct aggregation work. |
| Q3: `SELECT COUNT(*) FROM t WHERE <masked_col> = 'x'` | Tests whether masked predicates lose push-down. Expectation: they do → `bytes_scanned` likely jumps. |
| Q4: `SELECT AVG(amount), COUNT(*) FROM t` (baseline only) | Control — no masked columns referenced; should show ~0 tax on baseline. Confirms the harness isn't biased. Not re-run under masked variants. |

Plus a **multi-column cell** at the end of Phase 2 (§6.1): `P_HASH` applied to 4 columns simultaneously, with a query that projects all four. Real PII tables mask 3–8 columns, and per-row cost is per-masked-column-projected; one-column tests systematically under-state real tax.

Roles: query plans differ between the role allowed to see plaintext and the role that gets the masked branch — both paths need timing.

### 1.3 The secondary-roles gotcha

This is the most failure-prone part of the test. Snowflake sessions can have a **primary role** (`CURRENT_ROLE()`) and a **secondary role set** (`CURRENT_SECONDARY_ROLES()`, `IS_ROLE_IN_SESSION(...)`). With `USE SECONDARY ROLES ALL` (which is the default in many FBG sessions), every role the user has been granted is in the session's effective set.

That matters here because most production masking policies are written like one of:

```sql
-- Form A: matches against the primary role only
CASE WHEN CURRENT_ROLE() IN ('PII_READER') THEN val ELSE '***' END

-- Form B: matches against any role in the session
CASE WHEN IS_ROLE_IN_SESSION('PII_READER') THEN val ELSE '***' END
```

If we write Form B and run as my admin user, **ACCOUNTADMIN is in my session as a secondary role** and the policy returns plaintext — the masked path never executes and the test is invalid.

**Mitigation, layered:**

1. **`USE SECONDARY ROLES NONE`** before every test run. This drops everything except the primary role from the session. After this, `IS_ROLE_IN_SESSION('ACCOUNTADMIN')` returns FALSE even though it's still granted to my user.
2. The policies in this test use `CURRENT_ROLE()` (Form A), which is even narrower — only the *primary* role is checked. So even if step 1 is forgotten, the masked branch still fires.
3. Verification block in §4 — runs `SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES()` and asserts the masked branch is hit before any benchmark runs.

Belt and suspenders. If any of those three fail, the test will refuse to proceed instead of silently returning plaintext.

### 1.4 Cache control

Three caches matter:

- **Result cache** (24h): `ALTER SESSION SET USE_CACHED_RESULT = FALSE` — disabled for all benchmark runs.
- **Warehouse local SSD cache**: cleared by `ALTER WAREHOUSE <wh> SUSPEND` then `RESUME`. Done **once per test cell**, then we discard the first 2 runs as warmup and measure the next 8.
- **Metadata cache**: always on, can't disable. Affects all variants equally so it doesn't bias the comparison.

Why not suspend/resume between every single run? Because for the 180M-row clone (Phase 2) the warehouse warmup adds ~5–15s of irrelevant overhead per iteration and would dominate the signal. Steady-state warm-cache numbers are what production queries actually see anyway.

### 1.5 Statistical approach

For each cell (variant × query × role):

- N = 10 runs
- Drop runs 1–2 (warmup)
- Report median, p90, and stddev of the remaining 8
- Compare to the un-policied baseline cell (same query, same role, same warehouse, same data) — report Δ_median in ms and Δ% relative
- **Noisy-cell rule:** any cell where `stddev / median > 10%` is flagged and re-run. Don't blindly trust the median if the underlying samples are dispersed — high variance often means we accidentally hit a cold cache, a noisy neighbor on the warehouse, or a compilation cache effect.
- **What we're measuring is warm-cache steady state**, not cold-start latency. The first 2 reps absorb warehouse warmup; reps 3–10 reflect what a returning query sees. This is what production analyst/dashboard queries hit. We are deliberately not benchmarking cold-start because (a) it's dominated by warehouse-resume cost which is policy-independent, and (b) production queries are mostly warm. State this explicitly in the report.

**Cell-ordering / interleaving.** Don't run all baselines first and then all variants — warehouse and account state drift over a 30-min test run and would systematically advantage whichever was measured later. Instead, **for each query, run all variants back-to-back before moving to the next query**: baseline → P_NULL → P_HASH → P_COND(reader) → P_COND(excluded) → P_COND_ISR(reader) → P_COND_ISR(excluded), then move to the next query. This way drift hits all variants of a given query equally.

Total executions per phase: ~22 cells × 10 reps ≈ 220 query executions. With XS–S warehouse this is cheap.

### 1.6 Metrics source

Everything pulled from `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (45-min latency, but accurate) or `INFORMATION_SCHEMA.QUERY_HISTORY` (fresh, 14-day window). We'll use INFORMATION_SCHEMA for live results and ACCOUNT_USAGE for the final report.

Each test cell tags its queries via `QUERY_TAG`, e.g.:

```sql
ALTER SESSION SET QUERY_TAG = 'mtax|phase=p1|variant=P_HASH|q=Q2|role=MASKED|rep=03';
```

This makes aggregation trivial and survives session restarts.

Columns pulled per query:

- `COMPILATION_TIME` (ms) — where most masking-policy cost lives
- `EXECUTION_TIME` (ms) — per-row evaluation cost
- `TOTAL_ELAPSED_TIME` (ms) — what the user feels
- `BYTES_SCANNED` — to detect predicate-pushdown loss
- `CREDITS_USED_CLOUD_SERVICES` — cloud-services credits (compilation is billed here)
- `WAREHOUSE_SIZE` — for converting execution time → warehouse credits

Warehouse credits are derived: `(execution_time_seconds / 3600) × credits_per_hour_for_size`.

### 1.7 Phasing

- **Phase 1 — Synthetic smoke test (1M rows, ~12 columns).** Two cells only: baseline Q2 + `P_HASH` Q2. Five-minute check that the harness, role isolation, and policy enforcement all wire up correctly. Not for reporting numbers — just for catching bugs before committing to Phase 2. Verification block in §4 already proves enforcement; this confirms the harness produces a non-zero, plausible tax.
- **Phase 2 — `fangraph.admin.fangraph` clone (180M rows, wide).** Real-scale numbers. Zero-copy clone, so storage cost is ~zero. This is the test we report on.

If Phase 1 shows a non-zero, directionally-correct tax for `P_HASH` vs baseline, proceed. Otherwise debug.

---

## 2. Setup — variables and warehouse

Replace `<RUN_ID>` with a short token to namespace this run, e.g. `20260610a`. The token is appended to every object we create so multiple parallel runs don't collide, and so cleanup is unambiguous.

```sql
-- ============================================================
-- 0. SESSION SETUP — RUN ONCE AT START
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;

-- Pick a warehouse small enough that variance is dominated by the
-- query, not by warehouse-startup or noisy-neighbor effects.
-- XS keeps things cheap and minimizes parallelism variance.
USE WAREHOUSE FES_DATA_DEV_WH;  -- <-- replace with your scratch WH if different
ALTER WAREHOUSE FES_DATA_DEV_WH SET WAREHOUSE_SIZE = 'XSMALL';

-- Disable result cache for the whole session
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Lock down the role set so masking policies see only the primary role.
USE SECONDARY ROLES NONE;

-- Sanity check the session state before doing anything else.
SELECT
    CURRENT_ROLE()             AS primary_role,
    CURRENT_SECONDARY_ROLES()  AS secondary_roles_json,  -- expect: roles=[], values=[]
    CURRENT_WAREHOUSE()        AS wh,
    CURRENT_DATABASE()         AS db,
    CURRENT_SCHEMA()           AS sch;
```

---

## 3. Phase 1 setup — synthetic table (smoke test only)

1M rows, 12 columns. Just enough to verify the harness produces directionally-correct numbers before committing to the fangraph clone.

```sql
-- ============================================================
-- 1. SYNTHETIC TABLE — PHASE 1 SMOKE TEST
-- ============================================================

CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> AS
WITH base AS (
    SELECT SEQ8() AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 1000000))
)
SELECT
    rn                                                                                  AS id,
    UUID_STRING()                                                                       AS fan_id,
    'user' || rn || '@example.com'                                                      AS email,           -- PII-ish
    LPAD(MOD(ABS(HASH(rn)), 9000000000) + 1000000000, 10, '0')                          AS phone,           -- PII-ish
    'First' || MOD(rn, 1000)                                                            AS first_name,      -- PII-ish
    'Last'  || MOD(rn, 5000)                                                            AS last_name,       -- PII-ish
    DATEADD('day', -MOD(rn, 3650), CURRENT_DATE())                                      AS dob,             -- PII-ish
    DATEADD('second', -MOD(rn, 3 * 365 * 86400), CURRENT_TIMESTAMP())                   AS event_ts,        -- non-PII
    CASE MOD(rn, 5)
        WHEN 0 THEN 'NY' WHEN 1 THEN 'NJ' WHEN 2 THEN 'PA'
        WHEN 3 THEN 'FL' ELSE 'CA' END                                                  AS state,           -- non-PII
    (MOD(ABS(HASH(rn)), 10000000) / 100.0)::NUMBER(12,2)                                AS amount,          -- non-PII
    MOD(rn, 7) = 0                                                                      AS is_vip,          -- non-PII
    'note ' || SUBSTR(SHA1(rn::STRING), 1, 40)                                          AS notes            -- non-PII
FROM base;
-- Note: RANDOM(seed) / RANDSTR(len, seed) require a constant seed in
-- Snowflake; passing a column reference raises a compile error.
-- HASH/SHA1 of the row number give us deterministic, scalar-safe
-- per-row variation without the seed constraint.

-- Sanity
SELECT COUNT(*) AS row_count FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>;
-- expect 1,000,000
```

---

## 4. Roles, policies, grants — Phase 1

```sql
-- ============================================================
-- 2. SCRATCH ROLES
-- ============================================================

-- Role that should see plaintext (in the policy's allow-list).
CREATE OR REPLACE ROLE TEST_PII_READER_<RUN_ID>;

-- Role that should see masked values.
CREATE OR REPLACE ROLE TEST_PII_EXCLUDED_<RUN_ID>;

-- Grant both to my user so I can switch between them.
-- User identifier is case-sensitive when double-quoted. Snowflake
-- stores it uppercase; pass exactly what `SELECT CURRENT_USER()`
-- returns. Lowercase + quotes fails with "User does not exist".
GRANT ROLE TEST_PII_READER_<RUN_ID>   TO USER "ALEX.SOTIS@BETFANATICS.COM";
GRANT ROLE TEST_PII_EXCLUDED_<RUN_ID> TO USER "ALEX.SOTIS@BETFANATICS.COM";

-- Both roles need to be able to use the warehouse and read the table.
GRANT USAGE ON WAREHOUSE FES_DATA_DEV_WH               TO ROLE TEST_PII_READER_<RUN_ID>;
GRANT USAGE ON WAREHOUSE FES_DATA_DEV_WH               TO ROLE TEST_PII_EXCLUDED_<RUN_ID>;
GRANT USAGE ON DATABASE FES_USERS                      TO ROLE TEST_PII_READER_<RUN_ID>;
GRANT USAGE ON DATABASE FES_USERS                      TO ROLE TEST_PII_EXCLUDED_<RUN_ID>;
GRANT USAGE ON SCHEMA   FES_USERS.ALEX_SOTIS           TO ROLE TEST_PII_READER_<RUN_ID>;
GRANT USAGE ON SCHEMA   FES_USERS.ALEX_SOTIS           TO ROLE TEST_PII_EXCLUDED_<RUN_ID>;
GRANT SELECT ON ALL TABLES IN SCHEMA FES_USERS.ALEX_SOTIS TO ROLE TEST_PII_READER_<RUN_ID>;
GRANT SELECT ON ALL TABLES IN SCHEMA FES_USERS.ALEX_SOTIS TO ROLE TEST_PII_EXCLUDED_<RUN_ID>;

-- ============================================================
-- 3. MASKING POLICIES (3 VARIANTS)
-- ============================================================

-- P_NULL: trivial — no transformation, no branching.
CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_NULL_<RUN_ID> AS
    (val STRING) RETURNS STRING ->
    NULL;

-- P_HASH: per-row SHA2.
CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_<RUN_ID> AS
    (val STRING) RETURNS STRING ->
    SHA2(val, 256);

-- P_COND: role-conditional using CURRENT_ROLE(). Cheap path:
-- only checks the primary role with a string compare. Easier
-- enforcement target but does NOT support secondary-role grants,
-- which is why production policies at FBG generally use the ISR
-- variant below.
CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_<RUN_ID> AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() = 'TEST_PII_READER_<RUN_ID>' THEN val
        ELSE SHA2(val, 256)
    END;

-- P_COND_ISR: role-conditional using IS_ROLE_IN_SESSION(). This is
-- the form production policies typically use because it respects
-- secondary-role grants. Expected to be costlier than P_COND
-- because the role-set lookup walks the session's role hierarchy
-- rather than doing a single string compare. We test both so the
-- team can decide whether the convenience of ISR is worth the cost.
CREATE OR REPLACE MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_ISR_<RUN_ID> AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('TEST_PII_READER_<RUN_ID>') THEN val
        ELSE SHA2(val, 256)
    END;

-- ============================================================
-- 4. ENFORCEMENT SANITY CHECK
-- ============================================================
-- Before any benchmarking, prove that:
--   - Admin role (with secondary roles NONE) sees masked values
--   - TEST_PII_READER_<RUN_ID> sees plaintext
--   - TEST_PII_EXCLUDED_<RUN_ID> sees masked values

-- Apply P_COND to one column for the verification test.
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>
    MODIFY COLUMN email
    SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_<RUN_ID>;

-- As ACCOUNTADMIN with secondary roles NONE -> should be masked
USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
SELECT 'ACCOUNTADMIN' AS as_role, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> LIMIT 3;
-- expect SHA2 strings (64 hex chars), NOT 'userN@example.com'

USE ROLE TEST_PII_READER_<RUN_ID>;
SELECT 'TEST_PII_READER' AS as_role, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> LIMIT 3;
-- expect 'user0@example.com', 'user1@example.com', ...

USE ROLE TEST_PII_EXCLUDED_<RUN_ID>;
SELECT 'TEST_PII_EXCLUDED' AS as_role, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> LIMIT 3;
-- expect SHA2 strings

-- Also verify P_COND_ISR. With SECONDARY ROLES NONE the
-- behaviour should match P_COND. The interesting divergence
-- (ISR returns plaintext when role is a secondary) is
-- demonstrated by the last check below.
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>
    MODIFY COLUMN email UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>
    MODIFY COLUMN email
    SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_COND_ISR_<RUN_ID>;

USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
SELECT 'ISR / ACCOUNTADMIN / secondary=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> LIMIT 3;
-- expect SHA2 strings (masked) — TEST_PII_READER is not in session

USE ROLE TEST_PII_READER_<RUN_ID>;
SELECT 'ISR / TEST_PII_READER / secondary=NONE' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> LIMIT 3;
-- expect plaintext

-- The "why ISR is different from COND" demo:
-- secondary=ALL + ACCOUNTADMIN primary, but TEST_PII_READER
-- granted to user → ISR sees TEST_PII_READER in session →
-- returns plaintext. This is the production-realistic path.
USE SECONDARY ROLES ALL;
USE ROLE ACCOUNTADMIN;
SELECT 'ISR / ACCOUNTADMIN / secondary=ALL' AS scenario, email
FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> LIMIT 3;
-- expect plaintext (TEST_PII_READER granted to user is in the secondary role set)

-- Reset for benchmarking.
USE SECONDARY ROLES NONE;
USE ROLE ACCOUNTADMIN;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>
    MODIFY COLUMN email UNSET MASKING POLICY;
```

**STOP** if any of the three verification queries returned the wrong shape. Possible causes:

- Secondary roles still active → re-run `USE SECONDARY ROLES NONE`
- Role grant didn't take effect → re-run the GRANTs
- Policy body has a typo → recreate the policy

Only proceed past this point once enforcement is verified.

---

## 5. Benchmark harness

The benchmark is wrapped in a Snowflake Scripting block so each cell runs deterministically. The block:

1. Suspends + resumes the warehouse (clear local cache).
2. Sets `QUERY_TAG` per iteration.
3. Runs the query N times.
4. Inserts a marker row at the end so we can find the run's queries easily.

A "cell" = (policy state, query, role). We run one cell at a time. Below is the harness; copy and substitute the four `<...>` placeholders.

```sql
-- ============================================================
-- 5. BENCHMARK HARNESS — RUN ONE CELL
-- ============================================================
-- Placeholders to fill in per cell:
--   <CELL_TAG>      e.g. 'p1|var=BASELINE|q=Q2|role=ADMIN'
--   <ROLE_TO_USE>   e.g. ACCOUNTADMIN or TEST_PII_EXCLUDED_<RUN_ID>
--   <QUERY_SQL>     the SQL to benchmark (no trailing semicolon).
--                   IMPORTANT: every single quote inside <QUERY_SQL>
--                   must be doubled to '' because the SQL is embedded
--                   in an EXECUTE IMMEDIATE '...' wrapper. E.g. Q3's
--                   literal 'NEVER_MATCH_FOR_MTAX_TEST@example.com'
--                   becomes ''NEVER_MATCH_FOR_MTAX_TEST@example.com''.
--                   Missing this raises "syntax error ... unexpected
--                   '<literal>'." mid-matrix.
--   <N>             iteration count, default 10
-- ------------------------------------------------------------

USE SECONDARY ROLES NONE;
USE ROLE <ROLE_TO_USE>;
USE WAREHOUSE FES_DATA_DEV_WH;

-- Cold-start the warehouse.
ALTER WAREHOUSE FES_DATA_DEV_WH SUSPEND;
-- (wait — SUSPEND is async; a SELECT 1 below forces a resume)
ALTER WAREHOUSE FES_DATA_DEV_WH RESUME IF SUSPENDED;
SELECT 1;  -- warm provisioning

ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Run N reps. Each rep gets its own QUERY_TAG suffix so we can
-- pull them all by LIKE in §7.
DECLARE
    n INTEGER DEFAULT 10;
    i INTEGER DEFAULT 1;
    base_tag STRING DEFAULT 'mtax|<CELL_TAG>';
    rep_tag STRING;
BEGIN
    WHILE (i <= n) DO
        rep_tag := base_tag || '|rep=' || LPAD(i::STRING, 2, '0');
        EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || rep_tag || '''';
        EXECUTE IMMEDIATE '<QUERY_SQL>';
        i := i + 1;
    END WHILE;
    RETURN 'done: ' || base_tag;
END;
```

### 5.1 The benchmark queries

Defined inline (not as views — we want to vary the masked column between variants).

```sql
-- Q1: forced full-projection scan with cheap aggregate.
--     NOT `SELECT email FROM t LIMIT 1000` — LIMIT pushes past the
--     projection and the mask only fires on 1000 rows, producing a
--     misleadingly small delta.
-- Q1: SELECT MAX(LENGTH(email)) FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>

-- Q2: full eval of mask + distinct aggregation
-- Q2: SELECT COUNT(DISTINCT email) FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>

-- Q3: predicate on masked column — tests pushdown loss
-- Q3: SELECT COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID> WHERE email = 'user42@example.com'

-- Q4: control, baseline only. No masked column referenced; should show ~0 tax.
-- Q4: SELECT AVG(amount), COUNT(*) FROM FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>
```

### 5.2 The execution plan (the actual matrix)

**Phase 1 (smoke test) is just two cells:**

| # | Policy state | Cell tag | Role |
|---|---|---|---|
| S1 | None (baseline) | `p1\|var=BASELINE\|q=Q2\|role=ADMIN` | ACCOUNTADMIN |
| S2 | `P_HASH` on email | `p1\|var=P_HASH\|q=Q2\|role=ADMIN` | ACCOUNTADMIN |

If S2 median > S1 median by a plausible amount (say at least 10%), the harness is wired correctly → proceed to Phase 2. Otherwise debug. Use the cell tag prefix `p1|` for Phase 1 — these numbers are not for the final report.

**Phase 2 (the real test).** Use cell tag prefix `p2|`. Substitute the masked column you picked for fangraph in `<fg_col>`. Run the rows below **in order** — they're already interleaved per-query so warehouse/account drift is absorbed evenly across variants.

| # | Policy state | Cell tag | Role |
|---|---|---|---|
| **Q1 block — full-projection scan** | | | |
| 1 | None | `p2\|var=BASELINE\|q=Q1\|role=ADMIN` | ACCOUNTADMIN |
| 2 | `P_NULL` on `<fg_col>` | `p2\|var=P_NULL\|q=Q1\|role=ADMIN` | ACCOUNTADMIN |
| 3 | `P_HASH` on `<fg_col>` | `p2\|var=P_HASH\|q=Q1\|role=ADMIN` | ACCOUNTADMIN |
| 4 | `P_COND` on `<fg_col>` | `p2\|var=P_COND\|q=Q1\|role=READER` | TEST_PII_READER_<RUN_ID> |
| 5 | `P_COND` on `<fg_col>` | `p2\|var=P_COND\|q=Q1\|role=EXCLUDED` | TEST_PII_EXCLUDED_<RUN_ID> |
| 6 | `P_COND_ISR` on `<fg_col>` | `p2\|var=P_COND_ISR\|q=Q1\|role=READER` | TEST_PII_READER_<RUN_ID> |
| 7 | `P_COND_ISR` on `<fg_col>` | `p2\|var=P_COND_ISR\|q=Q1\|role=EXCLUDED` | TEST_PII_EXCLUDED_<RUN_ID> |
| **Q2 block — count distinct** | | | |
| 8 | None | `p2\|var=BASELINE\|q=Q2\|role=ADMIN` | ACCOUNTADMIN |
| 9 | `P_NULL` on `<fg_col>` | `p2\|var=P_NULL\|q=Q2\|role=ADMIN` | ACCOUNTADMIN |
| 10 | `P_HASH` on `<fg_col>` | `p2\|var=P_HASH\|q=Q2\|role=ADMIN` | ACCOUNTADMIN |
| 11 | `P_COND` on `<fg_col>` | `p2\|var=P_COND\|q=Q2\|role=READER` | TEST_PII_READER_<RUN_ID> |
| 12 | `P_COND` on `<fg_col>` | `p2\|var=P_COND\|q=Q2\|role=EXCLUDED` | TEST_PII_EXCLUDED_<RUN_ID> |
| 13 | `P_COND_ISR` on `<fg_col>` | `p2\|var=P_COND_ISR\|q=Q2\|role=READER` | TEST_PII_READER_<RUN_ID> |
| 14 | `P_COND_ISR` on `<fg_col>` | `p2\|var=P_COND_ISR\|q=Q2\|role=EXCLUDED` | TEST_PII_EXCLUDED_<RUN_ID> |
| **Q3 block — predicate on masked col** | | | |
| 15 | None | `p2\|var=BASELINE\|q=Q3\|role=ADMIN` | ACCOUNTADMIN |
| 16 | `P_NULL` on `<fg_col>` | `p2\|var=P_NULL\|q=Q3\|role=ADMIN` | ACCOUNTADMIN |
| 17 | `P_HASH` on `<fg_col>` | `p2\|var=P_HASH\|q=Q3\|role=ADMIN` | ACCOUNTADMIN |
| 18 | `P_COND` on `<fg_col>` | `p2\|var=P_COND\|q=Q3\|role=READER` | TEST_PII_READER_<RUN_ID> |
| 19 | `P_COND` on `<fg_col>` | `p2\|var=P_COND\|q=Q3\|role=EXCLUDED` | TEST_PII_EXCLUDED_<RUN_ID> |
| 20 | `P_COND_ISR` on `<fg_col>` | `p2\|var=P_COND_ISR\|q=Q3\|role=READER` | TEST_PII_READER_<RUN_ID> |
| 21 | `P_COND_ISR` on `<fg_col>` | `p2\|var=P_COND_ISR\|q=Q3\|role=EXCLUDED` | TEST_PII_EXCLUDED_<RUN_ID> |
| **Q4 — harness control, baseline only** | | | |
| 22 | None | `p2\|var=BASELINE\|q=Q4\|role=ADMIN` | ACCOUNTADMIN |

(Multi-column cell is a separate block in §6.1.)

Between policy changes, toggle the policy on/off:

```sql
-- Attach policy
ALTER TABLE FES_USERS.ALEX_SOTIS.<table>
    MODIFY COLUMN <col>
    SET MASKING POLICY FES_USERS.ALEX_SOTIS.<P_NULL|P_HASH|P_COND|P_COND_ISR>_<RUN_ID>;

-- Detach before applying a different policy
ALTER TABLE FES_USERS.ALEX_SOTIS.<table>
    MODIFY COLUMN <col> UNSET MASKING POLICY;
```

---

## 6. Phase 2 — fangraph clone

After Phase 1 numbers look sane, do the same matrix at scale.

```sql
-- ============================================================
-- 6. PHASE 2 SETUP — CLONE FANGRAPH (ZERO-COPY)
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES NONE;

CREATE OR REPLACE TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    CLONE FANGRAPH.ADMIN.FANGRAPH;

-- Verify it cloned
SELECT COUNT(*) AS rowcount FROM FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>;
-- expect ~180M

-- Re-grant SELECT on the new clone to test roles
GRANT SELECT ON FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    TO ROLE TEST_PII_READER_<RUN_ID>;
GRANT SELECT ON FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    TO ROLE TEST_PII_EXCLUDED_<RUN_ID>;
```

Then run §5.2's Phase 2 matrix against `MTAX_FG_<RUN_ID>`, with `<fg_col>` set to a string PII column on fangraph (TBD — `DESCRIBE TABLE FANGRAPH.ADMIN.FANGRAPH` first; candidates: `email`, `phone`, `first_name`).

Phase 2 may warrant **bumping the warehouse to SMALL or MEDIUM** since 180M rows × SHA2 will be slow on XS. Run cell 8 (Q2 baseline) once at XS as a gut-check — if it's > 60s, size up. Pick one size and keep it constant across all Phase 2 cells, including the multi-column block below.

### 6.1 Multi-column cell

Real PII tables mask 3–8 columns and per-row cost is per-masked-column-projected. Two cells, on top of the Phase 2 matrix above, to characterize this:

```sql
-- Pick 4 string columns on the fangraph clone — ideally all
-- PII-like (e.g. email, phone, first_name, last_name) — replace
-- the four <col_N> placeholders below.

-- Detach any leftover policy from Q1-Q3 testing.
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <fg_col> UNSET MASKING POLICY;

-- Attach P_HASH to four columns simultaneously.
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_1> SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_<RUN_ID>;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_2> SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_<RUN_ID>;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_3> SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_<RUN_ID>;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_4> SET MASKING POLICY FES_USERS.ALEX_SOTIS.P_HASH_<RUN_ID>;
```

Cells to run via the harness:

| # | Policy state | Cell tag | Role | Query |
|---|---|---|---|---|
| MC1 | None (baseline, 4 cols projected) | `p2\|var=BASELINE_4COL\|q=Q1_MC\|role=ADMIN` | ACCOUNTADMIN | `SELECT MAX(LENGTH(<col_1>)), MAX(LENGTH(<col_2>)), MAX(LENGTH(<col_3>)), MAX(LENGTH(<col_4>)) FROM FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>` |
| MC2 | `P_HASH` on 4 cols | `p2\|var=P_HASH_4COL\|q=Q1_MC\|role=ADMIN` | ACCOUNTADMIN | (same query as above) |

The delta MC2 − MC1 vs the single-column `P_HASH` delta (cell 3 minus cell 1 from §5.2) tells us whether per-row mask cost scales roughly linearly with column count, or whether something amortizes.

Detach all four policies before cleanup:

```sql
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID> MODIFY COLUMN <col_1> UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID> MODIFY COLUMN <col_2> UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID> MODIFY COLUMN <col_3> UNSET MASKING POLICY;
ALTER TABLE FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID> MODIFY COLUMN <col_4> UNSET MASKING POLICY;
```

---

## 7. Pulling and aggregating results

Run after each cell or at the end. Uses `INFORMATION_SCHEMA.QUERY_HISTORY` (live, 14-day window) so we don't wait on `ACCOUNT_USAGE`.

```sql
-- ============================================================
-- 7. RESULTS PULL
-- ============================================================

USE ROLE ACCOUNTADMIN;

WITH raw AS (
    SELECT
        query_id,
        query_tag,
        compilation_time,
        execution_time,
        total_elapsed_time,
        bytes_scanned,
        credits_used_cloud_services,
        warehouse_size,
        start_time
    FROM TABLE(
        FES_USERS.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
            USER_NAME      => CURRENT_USER(),
            RESULT_LIMIT   => 10000,
            END_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP())
        )
    )
    WHERE query_tag LIKE 'mtax|%'
      -- CRITICAL: filter to actual benchmark queries. Without this,
      -- the `ALTER SESSION SET QUERY_TAG` statements inside the harness
      -- (which run as their own QUERY_HISTORY rows, tagged with the
      -- previous iteration's tag) pollute the aggregation and pull
      -- medians toward zero. Symptom: `warehouse_size = None` and
      -- `bytes_scanned = 0` appearing in the grouped output.
      AND query_type = 'SELECT'
),
parsed AS (
    SELECT
        query_id,
        query_tag,
        SPLIT_PART(query_tag, '|', 2) AS phase,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 3), '=', 2) AS variant,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 4), '=', 2) AS query_id_label,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 5), '=', 2) AS role_label,
        SPLIT_PART(SPLIT_PART(query_tag, '|', 6), '=', 2)::INT AS rep,
        compilation_time,
        execution_time,
        total_elapsed_time,
        bytes_scanned,
        credits_used_cloud_services,
        warehouse_size
    FROM raw
),
trimmed AS (
    -- Drop warmup reps 1-2 per cell
    SELECT *
    FROM parsed
    WHERE rep > 2
)
SELECT
    phase,
    variant,
    query_id_label,
    role_label,
    COUNT(*) AS n_runs,
    MEDIAN(compilation_time)              AS compile_ms_median,
    MEDIAN(execution_time)                AS exec_ms_median,
    MEDIAN(total_elapsed_time)            AS total_ms_median,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY total_elapsed_time) AS total_ms_p90,
    STDDEV(total_elapsed_time)            AS total_ms_stddev,
    AVG(bytes_scanned)                    AS bytes_scanned_avg,
    AVG(credits_used_cloud_services)      AS cloud_credits_avg,
    ANY_VALUE(warehouse_size)             AS wh_size
FROM trimmed
GROUP BY phase, variant, query_id_label, role_label
ORDER BY phase, query_id_label, variant, role_label;
```

### 7.1 Computing the tax

After we have the aggregated table, join each `variant != 'BASELINE'` row against the corresponding `variant = 'BASELINE'` row on `(phase, query_id_label, role_label='ADMIN' or matching)` to get:

```sql
WITH agg AS (
    -- result of §7 query above
    ...
),
baseline AS (
    SELECT phase, query_id_label, role_label,
           compile_ms_median  AS b_compile_ms,
           exec_ms_median     AS b_exec_ms,
           total_ms_median    AS b_total_ms,
           bytes_scanned_avg  AS b_bytes
    FROM agg WHERE variant = 'BASELINE'
)
SELECT
    a.phase,
    a.variant,
    a.query_id_label,
    a.role_label,
    a.total_ms_median       AS masked_total_ms,
    b.b_total_ms            AS baseline_total_ms,
    a.total_ms_median - b.b_total_ms                                  AS delta_ms,
    ROUND(100.0 * (a.total_ms_median - b.b_total_ms) / b.b_total_ms, 1) AS delta_pct,
    a.compile_ms_median - b.b_compile_ms                              AS compile_delta_ms,
    a.exec_ms_median    - b.b_exec_ms                                 AS exec_delta_ms,
    ROUND(100.0 * (a.bytes_scanned_avg - b.b_bytes) / NULLIF(b.b_bytes, 0), 1) AS bytes_delta_pct
FROM agg a
JOIN baseline b
    USING (phase, query_id_label)
WHERE a.variant != 'BASELINE'
ORDER BY a.phase, a.query_id_label, a.variant, a.role_label;
```

This is the final summary to put in the report.

---

## 8. Cleanup

**Must run regardless of test outcome.** All scratch objects are namespaced with `<RUN_ID>` so this is safe.

```sql
-- ============================================================
-- 8. CLEANUP
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES NONE;
USE DATABASE FES_USERS;
USE SCHEMA ALEX_SOTIS;

-- Detach all policies. `DROP TABLE` would fail with dependent policy
-- references attached. List every column that COULD have been masked
-- during the run, including the four columns from the multi-column
-- cell in §6.1. Safe to over-detach — UNSET is a no-op on an
-- already-clean column.
ALTER TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>
    MODIFY COLUMN email UNSET MASKING POLICY;

-- For the fangraph clone, detach from every column you applied to.
-- Fill in <fg_col>, <col_1>, <col_2>, <col_3>, <col_4> with the same
-- values used in §5.2 and §6.1.
ALTER TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <fg_col> UNSET MASKING POLICY;
ALTER TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_1> UNSET MASKING POLICY;
ALTER TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_2> UNSET MASKING POLICY;
ALTER TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_3> UNSET MASKING POLICY;
ALTER TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>
    MODIFY COLUMN <col_4> UNSET MASKING POLICY;

-- Drop tables
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_SYNTH_<RUN_ID>;
DROP TABLE IF EXISTS FES_USERS.ALEX_SOTIS.MTAX_FG_<RUN_ID>;

-- Drop policies
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P_NULL_<RUN_ID>;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P_HASH_<RUN_ID>;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P_COND_<RUN_ID>;
DROP MASKING POLICY IF EXISTS FES_USERS.ALEX_SOTIS.P_COND_ISR_<RUN_ID>;

-- Drop roles (this also revokes grants made TO these roles automatically)
DROP ROLE IF EXISTS TEST_PII_READER_<RUN_ID>;
DROP ROLE IF EXISTS TEST_PII_EXCLUDED_<RUN_ID>;

-- Reset session
ALTER SESSION UNSET QUERY_TAG;
ALTER SESSION UNSET USE_CACHED_RESULT;
USE SECONDARY ROLES ALL;

-- Verify nothing remains
SELECT 'tables'   AS kind, table_name   AS name FROM FES_USERS.INFORMATION_SCHEMA.TABLES
    WHERE table_schema = 'ALEX_SOTIS' AND table_name LIKE 'MTAX\\_%' ESCAPE '\\'
UNION ALL
SELECT 'policies' AS kind, policy_name  AS name FROM FES_USERS.INFORMATION_SCHEMA.MASKING_POLICIES
    WHERE policy_schema = 'ALEX_SOTIS' AND policy_name LIKE 'P\\_%\\_<RUN_ID>' ESCAPE '\\'
UNION ALL
SELECT 'roles'    AS kind, name         AS name FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
    WHERE name LIKE 'TEST\\_PII\\_%\\_<RUN_ID>' ESCAPE '\\'
      AND deleted_on IS NULL;
-- expect: zero rows
```

---

## 9. What we will report back

A short doc with:

1. The tax table (§7.1 output) for Phase 2 (Phase 1 numbers are smoke-test only, not for the report).
2. A 1-line per-cell narrative ("Q2 / P_HASH: median +X ms / +Y%, compile +A ms, exec +B ms").
3. Notable findings — particularly:
   - Whether masked predicates lose push-down (Q3 `bytes_scanned` delta).
   - What % of the total tax is compile vs execute.
   - `P_COND` vs `P_COND_ISR` delta — is the secondary-role-friendly form materially more expensive?
   - Multi-column scaling — does 4-column hashing cost ~4× single-column, or does it amortize?
4. Explicit limitations (so the report isn't ambushed):
   - **Warm-cache steady state only.** Cold-start results would differ; we don't measure them because they're dominated by policy-independent warehouse-resume cost.
   - **Single warehouse size, single user, no concurrency.** Multi-user / contended-warehouse behaviour could differ.
   - **String masks only.** Numeric and date masks have different per-row cost characteristics (likely cheaper) and are not measured.
   - **Single table, no joins between masked tables.** Joining two policy-masked tables on the masked column would likely lose pushdown on both sides; not tested.
   - **No clustering key, search optimization, materialized view, or time-travel interaction tested.** Each can interact non-trivially with masking; out of scope.
   - **Semi-structured (VARIANT/OBJECT/ARRAY) masking not tested.**
   - **Synthetic baseline column (`email` on the fangraph clone) may not match the team's actual masking targets** — sanity-check the picked column reflects the kind of column they'd actually mask.

If we want concurrency, multi-user effects, or any of the bullets above, those are follow-on tests.

---

## 10. Open questions / things to verify before kicking off

- [ ] Confirm the warehouse `FES_DATA_DEV_WH` (or equivalent) is OK for this scratch use — pick the right scratch WH.
- [ ] Pick the masked column for Phase 2 — needs to be (a) string type, (b) actually PII or PII-like, (c) widely referenced. Inspect `DESCRIBE TABLE FANGRAPH.ADMIN.FANGRAPH` and pick.
- [ ] Pick the 4 columns for the multi-column cell in §6.1.
