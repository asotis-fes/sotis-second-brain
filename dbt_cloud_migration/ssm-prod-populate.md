# SSM Prod Populate — `/airflow/connections/dbt_cloud_ae`

**Do this now.** Not on cutover morning. There is no downside to populating early — the connection is only consumed by `dbt_loyalty_6hours`, which currently references `dbt_cloud_ae` but the DAG isn't running in prod yet (deploy happens at cutover merge). Populating early removes one time-critical step from cutover morning and lets you validate the connection ahead of time.

## Prerequisites (already done)

- ✅ Terraform placeholder exists in prod SSM. Created by fanapp-terraform PR #2873 (merged 2026-07-11), which touched both `terraform/fes-data/compute/dev/compute/local.tf` and `terraform/fes-data/compute/prod/compute/local.tf`.
- ✅ Grants applied. fanapp-terraform PR #2916 merged 2026-07-16.

## Step 1 — Generate the prod service token in dbt Cloud

**Role: `Job Runner`** (least-privilege — see rationale below).

1. Log in to dbt Cloud → account **70437463654557** (host: `sh023.us1.dbt.com`).
2. **Account settings → Service tokens → Create Service Token**.
   - **Name:** `airflow-mwaa-prod`
   - **Permission set:** **Job Runner**
   - **Project:** **FES Analytics Engineering** (the dbt-fes-ae project only — restricts the token to that one project, keeping other projects in the account out of reach).
   - **Environment write access:** shows **None** for Job Runner. That's the expected value — Job Runner never modifies env settings, so this column is not applicable to it (per [enterprise permissions docs](https://docs.getdbt.com/docs/cloud/manage-access/enterprise-permissions)). Nothing to configure here.
3. **Copy the token value immediately.** It's shown only once. Hold it in your clipboard/1Password buffer for Step 2b — don't paste into a doc.

⚠️ **Do not reuse the `airflow-mwaa-dev` token.** Prod gets its own token so we can rotate/revoke independently, and so audit logs distinguish which MWAA env fired a run.

### Why Job Runner, not Job Admin

MWAA's entire interaction with dbt Cloud is two HTTP calls per DAG run:

- `POST /api/v2/accounts/{id}/jobs/{job_id}/run/` — trigger the dbt Cloud run
- `GET /api/v2/accounts/{id}/runs/{run_id}/` — poll status until finished

Both are covered by **Job Runner** (`Jobs=Read, Runs=Write`, per [dbt Cloud enterprise permissions docs](https://docs.getdbt.com/docs/cloud/manage-access/enterprise-permissions)).

**Job Admin** additionally lets the token create, edit, and delete jobs. MWAA never does any of that, and if the token leaks, an attacker with Job Admin can edit an existing job's `execute_steps` to run arbitrary shell in the warehouse. Job Runner cannot do that — the blast radius shrinks to "re-run existing jobs at will," which is bounded and detectable.

### Note on env scoping

**Job Runner is not env-scopeable** — confirmed empirically in the token-creation UI (2026-07-18). The "Environment write access" column shows "None" for Job Runner and there's no other env-selection control. This matches the [docs](https://docs.getdbt.com/docs/cloud/manage-access/enterprise-permissions), which list env scoping only for **Analyst / Database Admin / Developer / Git Admin / Team Admin** — all roles that mutate env settings, not roles that trigger job runs.

That means one Job Runner token — regardless of dev vs prod — can trigger any job in its assigned project. We accept this because:

- **AWS-account boundary** — dev SSM lives only in the dev compute account, prod SSM only in the prod compute account. MWAA in each env only sees its own SSM. A leaked dev token cannot be fetched by prod MWAA and vice versa.
- **DAG-side env branching** — `config.get_value_for_env(dev=..., prod=...)` in every DAG constant. Prod MWAA picks prod job IDs at DAG parse time; the token never sees the "wrong" env's job ID unless a DAG is coded incorrectly.
- **Blast radius reduction is the main win** — Job Runner is `Jobs=Read, Runs=Write`. An attacker with a leaked Job Runner token can re-trigger existing jobs in the selected project, but cannot rewrite job steps, delete jobs, create new jobs, or touch other projects. Compared to Job Admin (arbitrary shell via `execute_steps`), this is a large reduction.

## Step 1b — Validate the new token against dbt Cloud API (before touching SSM)

Empirically verify the token has exactly the permissions MWAA needs — and nothing more — before it ever reaches SSM:

```bash
bash projects/dbt_cloud_migration/scripts/test-token-permissions.sh prod
```

The script exercises **every** API call MWAA's `create_dbt_cloud_task_group` makes, plus a few write operations MWAA does not need (which should 403 for a Job Runner token):

- ✅ Must succeed: `GET /accounts/`, `GET /jobs/{id}/`, `GET /runs/{run_id}/`
- ✅ Must succeed (only if `--trigger-prod`): `POST /jobs/{id}/run/`
- ❌ Should 403 for Job Runner: `PUT /jobs/{id}/`, `POST /jobs/`

For prod, the script defaults to NOT triggering a real run — pass `--trigger-prod` if you want to (uses `dbt_sources`, which is source-freshness-only and safe to fire on demand).

Ordered validation flow:
1. Regenerate the dev token as Job Runner. Test in dev: `bash test-token-permissions.sh dev`. Confirm all ✓.
2. Update dev SSM with the new dev token via Datadog Self-Service. Watch the next dev DAG run land green.
3. Only then generate the prod token as Job Runner and continue with Step 2b.

## Step 2 — Build the connection URI

MWAA reads Airflow connections from SSM in **URI format**, not JSON (per **D-06** in discoveries.md).

```
dbt-cloud://70437463654557:<TOKEN>@sh023.us1.dbt.com
```

Substitutions:
- `70437463654557` — dbt Cloud account ID (login field)
- `<TOKEN>` — the token you just copied from step 1 (password field)
- `sh023.us1.dbt.com` — dbt Cloud regional host (**not** `cloud.getdbt.com`, per **D-07**)

**No JSON. No wrapping quotes. No trailing whitespace.**

## Step 2b (recommended) — Use the helper script

Instead of building the URI by hand and clipboard-pasting a token by eye,
run the helper. It validates the token against dbt Cloud, sanity-checks the
prod scope, and loads the URI onto your clipboard — token never touches
disk or scrollback.

```bash
bash projects/dbt_cloud_migration/scripts/populate-ssm-token.sh
```

The script:
1. Prompts for the token via `read -s` (hidden input)
2. GETs `/api/v2/accounts/70437463654557/` — expects 200 (token is a valid dbt Cloud credential)
3. GETs `/api/v2/accounts/.../jobs/70437463791502/` (prod `dbt_loyalty_6hours`) — expects 200 (token has job-read permission at all)
4. Builds `dbt-cloud://<account>:<token>@<host>` and pipes to `pbcopy`

No env-scope isolation check — Job Admin is account-wide (see Step 1 note). The prod token can read both dev and prod jobs; that's expected behavior of the role, not a misconfiguration.

## Step 3 — Populate via Datadog SSM Self-Service

1. Open the [Datadog SSM Self-Service app](https://app.datadoghq.com/app-builder/apps/0f0cd1e3-34fa-44cc-bf2e-e5ab60f8b6a1).
2. Select the prod SSM parameter: `/airflow/connections/dbt_cloud_ae` in the **prod compute account** (fes-data-compute-prod).
3. Paste (⌘V) — the URI from step 2b is already on your clipboard.
4. Submit. The workflow runs an SSM `put-parameter --overwrite` under the hood.

If you see `'triggerWorkflow0' failed with error 'we executed the action but it returned an error response'`, the placeholder likely doesn't exist. Verify PR #2873 was applied (it was — 2026-07-11). If still failing, ping the SSM Self-Service Slack channel.

## Step 4 — Verify (read-only sanity check)

```bash
bash projects/dbt_cloud_migration/scripts/verify-ssm-populated.sh
```

The script only reads metadata (existence, version, last-modified timestamp, last-modified user) — never the value. Expect:
- `Version` > 1 (placeholder was version 1, populate bumps it)
- `Last modified` within the last few minutes
- `Last modified by` = your role ARN via Datadog Self-Service

Final round-trip validation happens post-cutover on the first prod `dbt_loyalty_6hours` run — `run_dbt.trigger` will 200 (connection works) or 401 (token wrong / not scoped to prod env).

## What NOT to do

- ❌ Do NOT retrieve the value via `aws ssm get-parameter --with-decryption` — that logs the token in shell history.
- ❌ Do NOT paste the URI into Slack, PR comments, docs, or any surface that could get indexed. If you need to hand it off, use a password manager.
- ❌ Do NOT commit the URI to any file. This runbook only shows the *format*, never the real token.
- ❌ Do NOT use the dev token for prod (`airflow-mwaa-dev` is scoped to dev environments only).

## If you need to rotate later

Same flow: generate a new prod token in dbt Cloud, populate prod SSM via Self-Service. **Then revoke the old token in dbt Cloud** (Account settings → Service tokens → …). Rotation should be seamless — MWAA hits SSM per connection lookup with a short TTL cache.
