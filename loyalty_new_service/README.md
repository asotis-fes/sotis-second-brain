# Loyalty New Backend — Source-to-Ledger Mapping (One Credits)

Workspace for porting the `one_credits_loyalty_analytics_ledger` dbt model from
the old loyalty source tables (Postgres-replicated `journal` / `entry` /
`opco_program_account` / etc.) to the new loyalty backend service.

Test data lives in `FES_USERS.ANNA_SMITH.LOYALTY_TEST_*` (14 tables).

## Files

- `mapping.md` — old-source → new-source field map and shape changes
- `ledger_v2_draft.sql` — first-pass rewrite of `one_credits_loyalty_analytics_ledger` on the new sources
- `validation_queries.sql` — sanity-check queries to compare against the old ledger
