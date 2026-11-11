# dbt1060 — UnusedConfigKey

Fusion is strict about YAML schema. Unknown keys at any level become hard errors, not silent-ignore warnings.

## Sub-cases we hit

### Sub-case A: Top-level YAML anchor keys (`x-*` and `_*`)

**Example error:**
```
[error] [UnusedConfigKey (dbt1060)]: Ignored unexpected key `"x-ff-bronze-config"`. YAML path: `x-ff-bronze-config`.
  --> models/fanflow/bronze_events/fanflow_bronze_events.yml:5:1
```

**1.8 behavior:** dbt-core silently tolerated arbitrary top-level YAML keys. Common convention in fes-airflow was to define reusable anchors as `x-<domain>-config: &anchor-name` or `_<name>: &anchor-name`, then reference them below via `<<: *anchor-name` or `*anchor-name`.

**Fusion behavior:** Any key at the YAML root that isn't in Fusion's schema (`version`, `models`, `sources`, `seeds`, `snapshots`, `data_tests`, etc.) is rejected.

**Fix:** `dbt-autofix deprecations --all` handles this. It moves the anchor definitions inline — instead of a top-level `x-ff-bronze-config: &ff-bronze-config {...}` and per-model `<<: *ff-bronze-config`, it inlines the anchor definition at first use: `<<: &ff-bronze-config {...}`.

**Files touched (partial):** `models/fanflow/bronze_events/`, `models/fanflow/silver_events/`, `models/fangraph/private_fan_id/staging/`, `models/fes_integrations/google_ads/`, `models/growthloop/`, `models/loyalty/bonus/`.

---

### Sub-case B: Source freshness at wrong nesting

**Example error:**
```
[error] [UnusedConfigKey (dbt1060)]: Ignored unexpected key `"loaded_at_field"`.
  --> models/sources/amplitude.yml:9:9
[error] [UnusedConfigKey (dbt1060)]: Ignored unexpected key `"freshness"`.
  --> models/sources/amplitude.yml:10:9
```

**1.8 behavior:** `loaded_at_field` and `freshness` could sit at the table level directly:

```yaml
sources:
  - name: my_source
    tables:
      - name: my_table
        loaded_at_field: ts
        freshness:
          error_after: {count: 24, period: hour}
```

**Fusion behavior:** These properties must sit inside a `config:` block on the source table.

**Fix:** `dbt-autofix` handles this. Output becomes:

```yaml
sources:
  - name: my_source
    tables:
      - name: my_table
        config:
          loaded_at_field: ts
          freshness:
            error_after: {count: 24, period: hour}
```

**Files touched:** most of `models/sources/*.yml` — ~15 files, ~150 tables total.

---

### Sub-case C: `merge_exclude` (typo)

**Example error:**
```
[error] [UnusedConfigKey (dbt1060)]: While parsing config: Ignored unexpected key `"merge_exclude"`.
  YAML path: `config.merge_exclude`.
```

**Root cause:** The correct dbt-snowflake config key is `merge_exclude_columns` (plural). `merge_exclude` (singular) was a typo that dbt-core silently tolerated — it was ignored, not consumed, meaning the intended MERGE column exclusion never actually happened.

**Files with the typo:** `models/fes_integrations/google_ads/google_ads.yaml` (10 occurrences via YAML anchor), `models/fes_integrations/magnite/schema.yaml` (1), `models/fes_integrations/meta_ads/meta_ads.yml` (1).

**Fix chosen (initial): delete the key entirely** to preserve current no-exclusion behavior.

**Fix chosen (revised, 2026-07-11): rename to `merge_exclude_columns`** as a deliberate behavior change.

**Why the reversal:** the team decided that activating the intended column-exclusion is the correct end-state — MERGE statements will no longer update `_insert_ts` on matched rows, so audit timestamps stay accurate. This is a deliberate one-time behavior change during the Fusion migration.

**Downstream risk to watch:** any downstream consumer treating `_insert_ts` as "most recent merge time" is now incorrect and should switch to `_update_ts` (or the model's own recency signal). Consumers of the 3 affected models — google_ads (all `gam_*`), magnite (`magnite_pa_hourly`), meta_ads (`meta_ad_cost_dtl_hrly`) — should be audited.

**Files that ALREADY used the correct key** (unaffected all along): `models/commerce/orders/orders.yaml`, `models/enterprise_metrics/enterprise_metrics.yaml`, `models/identity/unified_profile/unified_profile.yaml`, and many more.

---

### Sub-case D: `config.tests` in schema.yml

**Example error:**
```
[error] [UnusedConfigKey (dbt1060)]: While parsing config: Ignored unexpected key `"tests"`. YAML path: `config.tests`.
```

**1.8 behavior:** Some models had `tests:` nested inside `config:` — a legacy pattern that dbt-core tolerated.

**Fusion behavior:** `tests` must be at the model level, not under `config`.

**Fix:** `dbt-autofix` moves `tests:` out of `config:` up to the model level. Handled automatically for the 2 files that hit this (`fangraph/private_fan_id/private_fan_id.yaml`, `fes_users/rohan_gulati/rohan.yaml`).

## Migration approach summary

Use `dbt-autofix` for sub-cases A, B, D. Manual for sub-case C (business decision on preserving vs migrating behavior).

## References

- [Source freshness](https://docs.getdbt.com/reference/resource-properties/freshness)
- [dbt-snowflake merge_exclude_columns](https://docs.getdbt.com/docs/build/incremental-strategy)
- [YAML anchors](https://yaml.org/spec/1.2.2/#3222-anchors-and-aliases)
