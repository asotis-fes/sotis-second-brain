# dbt Cloud Migration

Living working folder for the FES `dbt-core` on MWAA → **dbt Cloud (Fusion)** migration.

Big-bang cutover with a one-PR revert rollback, executed on a compressed timeline. Development and testing accumulates on a single long-lived branch (`dbt-cloud-migration` in fes-airflow); zero merges to main until the atomic cutover PR (per **D40**).

## Where to look

| Question | File |
|---|---|
| **What still needs to happen? (live tracker)** | [`remaining-steps.md`](remaining-steps.md) |
| **How do the two systems relate post-cutover?** | [`post-cutover-architecture.md`](post-cutover-architecture.md) |
| How do I populate prod SSM for `dbt_cloud_ae`? | [`ssm-prod-populate.md`](ssm-prod-populate.md) |
| What's the cutover-morning checklist? | [`monday-cutover-plan.md`](monday-cutover-plan.md) |
| How does the DAG-by-DAG migration mechanic work? | [`cutover-playbook.md`](cutover-playbook.md) |
| Why did we choose X? | [`decisions.md`](decisions.md) (D1–D41 chronological) |
| What gotchas hit us along the way? | [`discoveries.md`](discoveries.md) |
| PR status across the three affected repos? | [`pr-tracker.md`](pr-tracker.md) |
| Snowflake role/ownership model? | [`permissions.md`](permissions.md) |
| Which dbt Cloud job maps to which DAG (+ prod/dev IDs)? | [`deploy-jobs.md`](deploy-jobs.md) |
| DAG-level conversion detail? | [`dag-conversion-inventory.md`](dag-conversion-inventory.md) |
| How is `data_interval_*` threaded through? | [`data-interval-usage.md`](data-interval-usage.md) |
| Post-cutover cleanup of Airflow-var references in dbt-fes-ae / dbt-governance / dbt-fes-analytics? | [`airflow-vars-cutover/`](airflow-vars-cutover/) |
| Dev coupling-test matrix? | [`coupling-test-plan.md`](coupling-test-plan.md) |
| Fusion parse-cleanup + loyalty diff proof? | [`fusion-migration/`](fusion-migration/) |
| Architecture diagrams? | [`diagrams.md`](diagrams.md) |
| Cutover-morning SQL (grants + ownership)? | [`sql/`](sql/) |

## Status

**Phase:** pre-cutover polish. All 22 prod dbt Cloud jobs exist with cron populated and `triggers.schedule=false`. fes-airflow PR #2252 is draft (CI blocked on coverage). fanapp-terraform grants PR #2916 merged 2026-07-16 (PR #2877 superseded and closed). Target cutover date: **~2026-07-23**.

See [`remaining-steps.md`](remaining-steps.md) for the running checklist and [`monday-cutover-plan.md`](monday-cutover-plan.md) for the full narrative plan.

## History

Earlier iterations of this folder maintained separate "big-bang 5-week plan" and "YOLO aggressive weekend" tracks. They converged: the current plan is big-bang shape (D1) with a YOLO-compressed timeline and a few nice-to-haves deferred post-cutover (Mesh split, TF-ified jobs, tiered alerting, cost monitoring). D33/D36/D38 (wave-based rollout, per-DAG parallel-run) are SUPERSEDED by D40 (single-cutover long-lived branch) and D41 (delete pure-dbt DAGs; fangraph gets its own dbt Cloud job paused until Fusion-validated).
