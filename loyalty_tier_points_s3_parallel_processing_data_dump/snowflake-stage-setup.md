# Snowflake Storage Integration + S3 Stage Setup

> **STATUS: DONE.** The integration `loyalty_migration_s3_int` and the perf/prod stages exist
> and work. This doc is now **reference + troubleshooting** — the "repoint per env" note (Step 4–7)
> and the AssumeRole Troubleshooting section are the parts you'll still use. Drop the objects
> after the prod cutover (Cleanup section).

Cross-team handshake so Snowflake can `COPY INTO` the Loyalty buckets. Built **manually in the
Snowflake UI as ACCOUNTADMIN** (not Terraform). Flow (already completed): we created the
integration → shared IAM user ARN + external ID → Loyalty created the IAM roles (per-env
accounts) → we set the real ARN, created stages, verified.

## Step 1 — create the integration (ACCOUNTADMIN)

```sql
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION loyalty_migration_s3_int
  TYPE                      = EXTERNAL_STAGE
  STORAGE_PROVIDER          = 'S3'
  ENABLED                   = TRUE
  STORAGE_AWS_ROLE_ARN      = 'arn:aws:iam::000000000000:role/placeholder'
  STORAGE_ALLOWED_LOCATIONS = (
    's3://fes-loyalty-fanapp-perf-1/tp_migration/',
    's3://fes-loyalty-fanapp-prod-1/tp_migration/'
  );
```

Placeholder ARN is intentional (harmless until stages+grants exist). Plain `CREATE` — if it
errors "already exists," stop and `DESC` first.

## Step 2 — get the two values for Loyalty

```sql
DESC INTEGRATION loyalty_migration_s3_int;
```

Copy **`STORAGE_AWS_IAM_USER_ARN`** and **`STORAGE_AWS_EXTERNAL_ID`**.

## Step 3 — Loyalty handoff (their action, acct 851474972090)

Ask them to create an IAM role (e.g. `fes-loyalty-snowflake-s3-fanapp-migration`) and return
the **role ARN**.

**Trust policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "<STORAGE_AWS_IAM_USER_ARN>" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>" } }
  }]
}
```

**Permission policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:GetObjectVersion","s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::fes-loyalty-fanapp-perf-1/tp_migration/*",
        "arn:aws:s3:::fes-loyalty-fanapp-prod-1/tp_migration/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": [
        "arn:aws:s3:::fes-loyalty-fanapp-perf-1",
        "arn:aws:s3:::fes-loyalty-fanapp-prod-1"
      ],
      "Condition": { "StringLike": { "s3:prefix": ["tp_migration/*"] } }
    }
  ]
}
```

## Step 4–7 — after Loyalty returns the role ARN

**Two roles, one integration → repoint per env.** Loyalty's PR (#3008) created one IAM role
per env, and **each fanapp env is a SEPARATE AWS account** (verified from the apply logs):
- perf `arn:aws:iam::354089337614:role/fes-loyalty-snowflake-s3-fanapp-perf-1-migration`
- prod `arn:aws:iam::851474972090:role/fes-loyalty-snowflake-s3-fanapp-prod-1-migration`

> ⚠️ Accounts differ per env and are NOT the GitHub Actions CI/backend accounts
> (`767397958296` perf-CI / `975050193047` prod-CI — those run `gh-actions-tf-…-plan`).
> Pointing the integration at the wrong account → `sts:AssumeRole` "not authorized" (role
> doesn't exist there). Always take the true ARN from the apply log
> (`aws_iam_role.snowflake_migration … Creation complete [id=…]`).

The integration holds ONE `STORAGE_AWS_ROLE_ARN`, so **set the perf role now, repoint to the
prod role on 8/3.** Both roles trust the same external ID, so no other change needed.

```sql
USE ROLE ACCOUNTADMIN;

-- PERF run (repoint to the prod role/account for the 2026-08-03 prod run):
ALTER STORAGE INTEGRATION loyalty_migration_s3_int
  SET STORAGE_AWS_ROLE_ARN =
    'arn:aws:iam::354089337614:role/fes-loyalty-snowflake-s3-fanapp-perf-1-migration';
DESC INTEGRATION loyalty_migration_s3_int;   -- confirm STORAGE_AWS_ROLE_ARN updated

CREATE STAGE LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf
  URL = 's3://fes-loyalty-fanapp-perf-1/tp_migration/'
  STORAGE_INTEGRATION = loyalty_migration_s3_int
  COMMENT = 'TP migration export — PERF (one-time, drop after 2026-08-03)';

CREATE STAGE LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod
  URL = 's3://fes-loyalty-fanapp-prod-1/tp_migration/'
  STORAGE_INTEGRATION = loyalty_migration_s3_int
  COMMENT = 'TP migration export — PROD (one-time, drop after 2026-08-03)';

-- verify (empty list, no error = S3 access works). AccessDenied after ALTER:
-- wait 1-2 min for IAM propagation; if it persists with correct ARN/external-id => KMS
-- (bucket SSE-KMS CMK needs kms:GenerateDataKey/Decrypt on the role — back to Loyalty).
LIST @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf;

COPY INTO @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/_writetest/
  FROM (SELECT 1 AS test_col) FILE_FORMAT=(TYPE=CSV) HEADER=TRUE OVERWRITE=TRUE;
REMOVE @LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf/_writetest/;
```

**Grants: not needed.** Exports run as **ACCOUNTADMIN** (decided), which already owns the
integration + stages. Only add grants if a dedicated export role is introduced later:
```sql
-- (skip unless switching off ACCOUNTADMIN)
GRANT USAGE ON INTEGRATION loyalty_migration_s3_int TO ROLE <export-role>;
GRANT USAGE ON STAGE LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf TO ROLE <export-role>;
GRANT USAGE ON STAGE LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod TO ROLE <export-role>;
```

## Cleanup (after 2026-08-03)

```sql
DROP STAGE IF EXISTS LOYALTY.LOYALTY_INFO.loyalty_migration_stage_perf;
DROP STAGE IF EXISTS LOYALTY.LOYALTY_INFO.loyalty_migration_stage_prod;
DROP STORAGE INTEGRATION IF EXISTS loyalty_migration_s3_int;
```

## Corrections vs. Suneel's `SNOWFLAKE_STAGE_SETUP.md`

- Doc uses `dev-1`; real targets are **perf-1 + prod-1**.
- Doc splits work as dev/prod stages; we use **perf/prod**.

## Troubleshooting

**`LIST`/COPY fails: "User: arn:aws:iam::685689791302:user/13b00000-s is not authorized to
perform: sts:AssumeRole on resource: <role arn>"**
This is an AWS trust/AssumeRole failure, NOT KMS/S3. Diagnose in this order:
1. **Confirm our side** — `DESC INTEGRATION loyalty_migration_s3_int`: `STORAGE_AWS_ROLE_ARN`
   = the env's role, `STORAGE_AWS_IAM_USER_ARN` matches the error principal, and
   `STORAGE_AWS_EXTERNAL_ID` is unchanged from what Loyalty baked into the trust policy. (If
   the external ID changed, the integration was recreated — never do that; re-hand the new ID.)
2. **Confirm the role ARN's ACCOUNT is right — it differs per env** (perf `354089337614`,
   prod `851474972090`). Do NOT use the GitHub Actions CI/backend accounts (`767397958296`
   perf-CI, `975050193047` prod-CI) — the role does not exist there, so the assume fails with
   the same message. Get the true ARN from the apply log (`aws_iam_role.snowflake_migration …
   Creation complete [id=…]`) or the `snowflake_tp_migration_role_arn` output.
3. **Confirm the role actually exists** — AWS obscures "role not found" as the same
   "not authorized" message. In fanapp-terraform, **merged ≠ applied**: the per-workspace
   `Apply` step is gated behind a `fanapp-platform` GitHub Environment approval. Check the
   push-event TF runs for the merge commit — if the env's Apply is `pending`/`waiting`, the
   role was never created; someone on `fanapp-platform` must approve+run it.
4. Only after a successful assume would a bucket-encryption **KMS CMK** gap show up — as
   `AccessDenied` on the object (add `kms:GenerateDataKey`/`Decrypt` to the role).

(2026-07-30 root causes: (a) wrong role-ARN account — used the CI backend accounts instead of
the per-env resource accounts (perf `354089337614`, prod `851474972090`); (b) perf Apply
initially pending/cancelled at the `fanapp-platform` gate, later re-run to success.)
