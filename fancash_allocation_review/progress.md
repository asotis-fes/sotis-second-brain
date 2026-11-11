# Progress Log

## 2026-09-08 — Session 1 — Phase 0 setup + Phase 1 ingest + full review

### Done
- **Phase 0**: created workspace + stubs.
- **Phase 1 ingest**:
  - Doc → `spec.md` ([Fancash Allocation Logic](https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3486875693) v12).
  - Query → `inputs/fancash_attribution.sql` (472 lines, from repo).
  - Slack #project-fancash-migration → `slack_thread.md` (full channel + key threads read).
- **Data-error review** (`FDE_DEVELOPER_2XL_WH`, table `LOYALTY.FANCASH.ALLOCATION_20260908`):
  - Independently reproduced **every** doc invariant on all 4,101,158 rows → **0 violations**
    (grain, Σpercent=1.00, jurisdiction domain=51, no sub-1%, no dup keys, no null keys, type alignment).
  - **Coverage check**: $291.46M "missing" balance = 99.98% **test accounts** (correct); only ~$56.7k /
    12,448 real accts dropped (ledger-vs-balance grain mismatch, immaterial, defaults to F1 opco).
  - **Allowlisted test account** `48954a70-…` confirmed present (1 row) = Daniel Friedwald, intentional
    for canary (Anton 09-03) — must strip for full prod run.
  - Mapped every Slack open question → status in latest query (`slack_thread.md`).
  - **Bonus net-out check (done)**: NOT exactly zero — $1.49M unclaimed bonus (189,611 accts) stays in
    the denominator (0.43% of the $349M remaining pool). Split-level dilution only; totals fine.
    One-line fix available (`fancash_type='regular'`). (First attempt at 2XL with 3 self-joins timed
    out; rewrote as single-scan conditional aggregation on 3XL → returned fast.)

### Findings summary
- 🟢 No structural data errors.
- 🔴/🟡 Three confirmations (not defects): allowlisted employee acct, percent-vs-dollar contract,
  real-money coverage gap. See `findings.md` / `decisions.md`.

### Next task
- Finish the bonus net-out check; fold result into `findings.md §Bonus`.
- If user wants: (a) confirm the 3 open questions with the team, (b) diff `ALLOCATION_20260908` vs a
  fresh query run, (c) spot-check the doc's 3 worked-example accounts against the table.
