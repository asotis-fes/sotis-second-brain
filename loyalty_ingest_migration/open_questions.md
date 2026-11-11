# Open Questions

Parking lot for questions that don't block immediate progress but need answers before/around cutover. When a question gets answered, move it to `decisions/` with the reasoning.

## OQ-1 — Does the legacy `POSTGRES_TABLE_CONFIGS` ingest retire at cutover, or coexist?

**Why it matters:** Decides whether table-name collisions (`loyalty_account`, `program`) are temporary (legacy retires → new takes the bare names) or permanent (need disambiguated names forever). Also affects how aggressive we can be about removing the legacy load tasks from the DAG.

**Asked of user:** 2026-06-24. Not blocking — we'll design for coexistence by default (safer) and simplify later if legacy retires.

---

## OQ-2 — How will the new prod tables appear in the loyalty team's Postgres without colliding on **their** end?

**Context:** At cutover, the `test_`-prefixed bucket-model tables become un-prefixed in the same prod Postgres we're already ingesting from. But the legacy-shape tables (`loyalty_account`, `program`, etc.) also live in that PG. Two scenarios:

1. **Unified physical table:** loyalty team merges the two `loyalty_account` / `program` shapes into a single physical table that serves both legacy code and new bucket-model code. Then our ingest just reads one table; no PG-side collision, but we still need to decide what to name it downstream so we don't break the legacy dbt models.
2. **Separate physical tables:** the loyalty team disambiguates on their side (different schema, different name like `loyalty_account_v2`, etc.). We need to know the exact names they land on.

**Asked of user:** 2026-06-24. Needs answer from the loyalty engineering team. Until we know, the collision analysis (`analysis/table_name_collisions.md`) covers both scenarios.

---

## OQ-3 — Where do `compare_row_counts` checks fit for the new tables?

**Context:** Today the row-count parity check only iterates `POSTGRES_TABLE_CONFIGS`. New-backend tables get no parity check. Before cutover we need parity on the new tables too — but it depends on whether they have Snowflake-side dbt models materialized in time, and what schema they land in (`SOURCE`? somewhere else?).

**Not asked yet** — surface during cutover-plan drafting.

---

## OQ-4 — Where do Snowflake external tables get created and maintained?

**Context:** Layer 2 of the legacy pipeline is the Snowflake external table (`LOYALTY.SOURCE.<TABLE>_EXT`). The dbt repo declares them as sources and uses `refresh_external_table()` to keep partition lists fresh, but **the DDL that creates the ext table is not in the dbt repo.** Likely Terraform (`fanapp-terraform`) or a one-off SQL file. We need to find that pattern and replicate it for 14 new tables.

**User mentioned** ("we have an external table that queries S3") that at least one new-backend ext table exists in dev — need to locate it, see its DDL, see who owns the create/update path.

**Not asked yet** — surface during pipeline-verification step.

---

## OQ-5 — Who owns the layer-3 staging models for the new backend — data eng or analytics eng?

**Context:** Legacy staging models in `models/loyalty/source/*.sql` are mechanical 1:1 mirrors of source tables (incremental + dedupe + ext-table-refresh pre-hook). Data-eng-shaped work. But the analytics engineer is the one building the new ledgers and may already be planning to author them. Worth confirming so we don't duplicate effort.

**Not asked yet** — surface in next conversation.
