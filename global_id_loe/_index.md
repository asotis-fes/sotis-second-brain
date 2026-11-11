# global_id_loe — LOE for switching teams to a global ID (private_fan_id)

> **Standing directive:** Keep these files updated as work progresses; treat them as
> the source of truth across sessions. Nothing under `projects/` is ever committed.

## Goal

A principal engineer asked for the **level of effort (LOE) for the FBG Data team** if
other teams switched to using a **"global id"** — the **`private_fan_id`** — where they
currently send/receive either **`tenant_fan_id`** or **`loyalty_id`**.

Concretely: document what has to change if we were to **only receive `private_fan_id`**
(instead of `loyalty_id` / `tenant_fan_id`) and would need to **send `private_fan_id`**
in place of those other IDs.

### Three change surfaces to cover
1. **Ingestion** — `fes-airflow` (DAGs / pipelines that receive the id)
2. **Data shares** — `fanapp-terraform` (outbound shares that send the id)
3. **dbt models** — `dbt-fes-ae` (transforms / joins keyed on the id)

### Final deliverable
A **high-level Confluence doc**. Keep it basic: the areas that need handling per surface,
plus a headline estimate in the form **"X engineers for X months."** Some breakdown is
useful internally (these files), but the published doc stays high-level.

## Table of Contents

- `_index.md` — this file (context + TOC)
- `findings.md` — what we learn about how each id is used today across the 3 surfaces
- `plan.md` — the LOE breakdown per surface + the headline estimate
- `decisions.md` — key scoping decisions and assumptions
- `progress.md` — session log / what's done vs. open

## Status

Phase 0 (setup) complete. No doc/code links ingested yet — awaiting go-ahead to start
discovery (Phase 1) across `fes-airflow`, `fanapp-terraform`, and `dbt-fes-ae`.
