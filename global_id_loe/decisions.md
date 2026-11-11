# Decisions & assumptions

## Scope
- Estimate covers **FBG Data team** work only across three surfaces: `fes-airflow`
  (ingestion), `fanapp-terraform` (data shares), `dbt-fes-ae` (dbt models).
- Framing: we would **only receive `private_fan_id`** and must **send `private_fan_id`**
  in place of `loyalty_id` / `tenant_fan_id`.

## Deliverable format
- Final = **high-level** Confluence doc. Basic change areas per surface + a single
  headline estimate ("X engineers for X months"). Detailed breakdown stays in these files.

## Open decisions (to resolve)
- 1:1 hard cutover vs. transition period carrying both IDs.
- Whether identity resolution (mapping old id ↔ private_fan_id) is in-scope for our team
  or provided upstream.
