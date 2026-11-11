import logging
import pendulum

from airflow.decorators import dag, task
from airflow.exceptions import AirflowException
from airflow.providers.amazon.aws.transfers.sql_to_s3 import SqlToS3Operator
from airflow.providers.common.sql.hooks.sql import DbApiHook
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook

from loyalty.configs import (
    OC_INGEST_LIVE,
    OC_POSTGRES_TABLE_CONFIGS,
    POSTGRES_TABLE_CONFIGS_ACTIVE,
)
from utils import args, callbacks, config
from utils.dag_run import get_backfill_flag
from utils.dbt_cloud import create_dbt_cloud_task_group

logger = logging.getLogger(__name__)

DBT_CLOUD_FESLOYALTY_JOB_ID = config.get_value_for_env(
    dev=70437463793539,
    prod=70437463793547,
)

# Snowflake database/schema for loyalty tables
SNOWFLAKE_DATABASE = config.get_value_for_env(dev="LOYALTY_DEV", prod="LOYALTY")
SQL_CONN_ID = config.get_value_for_env(
    # dev="loyalty_postgres_test",
    dev="loyalty_postgres_dev",
    prod="loyalty_postgres",
)


@task
def compare_row_counts(**context):
    """
    Compare row counts between Postgres source tables and Snowflake dbt models.
    Counts rows up to data_interval_end to match what was pulled in load tasks.
    Raises AirflowException if any row counts don't match.
    """
    data_interval_end = context["data_interval_end"]
    end_ts = data_interval_end.isoformat()

    pg_hook = DbApiHook.get_hook(SQL_CONN_ID)
    snowflake_hook = SnowflakeHook(snowflake_conn_id="snowflake_service_user")

    all_configs = list(POSTGRES_TABLE_CONFIGS_ACTIVE)
    if OC_INGEST_LIVE:
        all_configs.extend(OC_POSTGRES_TABLE_CONFIGS)

    results = []
    mismatched_tables = []

    for table_config in all_configs:
        table_name = table_config["table"]
        incremental_col = table_config["incremental_col"]
        # allocation has no DB-enforced uniqueness; count distinct pairs.
        # Concatenated form works in both Snowflake and Postgres (multi-arg
        # COUNT DISTINCT is Snowflake-only).
        if table_name == "allocation":
            count_expr = (
                "COUNT(DISTINCT earn_transaction_id || '|' || consume_transaction_id)"
            )
        else:
            count_expr = "COUNT(*)"

        pg_table = table_name
        sf_table = f"{SNOWFLAKE_DATABASE}.SOURCE.{table_name}"

        pg_sql = f"""
            SELECT {count_expr}
            FROM {pg_table}
            WHERE {incremental_col} < '{end_ts}'::TIMESTAMP
        """
        pg_count = pg_hook.get_first(pg_sql)[0]

        sf_sql = f"""
            SELECT {count_expr}
            FROM {sf_table}
            WHERE {incremental_col} < '{end_ts}'::TIMESTAMP_NTZ
        """
        sf_count = snowflake_hook.get_first(sf_sql)[0]

        diff = pg_count - sf_count
        tolerance_pct = table_config.get("row_count_tolerance_pct", 0)
        max_rows = max(pg_count, sf_count)
        allowed_diff = int(max_rows * tolerance_pct / 100) if tolerance_pct else 0
        within_tolerance = abs(diff) <= allowed_diff
        match_status = (
            "MATCH"
            if diff == 0
            else ("WITHIN_TOLERANCE" if within_tolerance else "MISMATCH")
        )
        if diff != 0 and not within_tolerance:
            mismatched_tables.append(table_name)

        results.append(
            {
                "table": table_name,
                "postgres_count": pg_count,
                "snowflake_count": sf_count,
                "difference": diff,
                "tolerance_pct": tolerance_pct,
                "allowed_diff": allowed_diff,
                "status": match_status,
            }
        )

        logger.info(
            f"{table_name}: Postgres={pg_count}, Snowflake={sf_count}, "
            f"Diff={diff}, Tolerance={tolerance_pct}% (±{allowed_diff}), Status={match_status}"
        )

    logger.info("=" * 60)
    logger.info(f"Row Count Comparison Summary (up to {end_ts})")
    logger.info("=" * 60)
    for r in results:
        logger.info(
            f"  {r['table']}: {r['status']} "
            f"(PG={r['postgres_count']}, SF={r['snowflake_count']}, Diff={r['difference']})"
        )

    if mismatched_tables:
        raise AirflowException(
            f"Row count mismatch detected for tables: {', '.join(mismatched_tables)}. "
            "Review the logs above for details."
        )

    return results


@dag(
    default_args=args.get_default_args(),
    on_failure_callback=callbacks.dag_failure_callback_p2,
    on_success_callback=callbacks.dag_success_callback_p2,
    dag_id="loyalty_postgres_to_s3_ingest",
    start_date=pendulum.datetime(2026, 2, 15, tz="UTC"),
    schedule_interval=config.get_value_for_env(dev=None, prod="5 * * * *"),
    template_searchpath="dags/loyalty/sql/",
    catchup=True,
    tags=["loyalty"],
    max_active_runs=1,
    max_active_tasks=1,
)
def loyalty_postgres_to_s3_ingest():
    get_backfill_flag_task = get_backfill_flag(key="loyalty_postgres_backfill")
    s3_bucket = config.append_env("fes-integrations-")
    sql_conn_id = SQL_CONN_ID

    load_tasks = []
    for table_config in POSTGRES_TABLE_CONFIGS_ACTIVE:
        table_name = table_config["table"]
        incremental_col = table_config["incremental_col"]
        cols = table_config.get("cols", "*")

        s3_key = f"loyalty_postgres/{table_name}/dt={{{{ ds }}}}/{table_name}_{{{{ ts_nodash }}}}.parquet"

        load_task = SqlToS3Operator(
            task_id=f"load_{table_name}",
            query="loyalty_postgres_incremental.sql",
            s3_bucket=s3_bucket,
            s3_key=s3_key,
            sql_conn_id=sql_conn_id,
            aws_conn_id="aws_storage",
            params={
                "table_name": table_name,
                "incremental_col": incremental_col,
                "cols": cols,
                "is_backfill": "{{ ti.xcom_pull(task_ids='get_backfill_flag') }}",
            },
            pd_kwargs={
                "index": False,
            },
            max_rows_per_file=1000000,
            replace=True,
            file_format="parquet",
        )

        get_backfill_flag_task >> load_task
        load_tasks.append(load_task)

    if OC_INGEST_LIVE:
        for table_config in OC_POSTGRES_TABLE_CONFIGS:
            table_name = table_config["table"]
            incremental_col = table_config["incremental_col"]
            cols = table_config.get("cols", "*")

            s3_key = f"loyalty_postgres/{table_name}/dt={{{{ ds }}}}/{table_name}_{{{{ ts_nodash }}}}.parquet"

            oc_load_task = SqlToS3Operator(
                task_id=f"load_{table_name}",
                query="loyalty_postgres_incremental.sql",
                s3_bucket=s3_bucket,
                s3_key=s3_key,
                sql_conn_id=sql_conn_id,
                aws_conn_id="aws_storage",
                params={
                    "table_name": table_name,
                    "incremental_col": incremental_col,
                    "cols": cols,
                    "is_backfill": "{{ ti.xcom_pull(task_ids='get_backfill_flag') }}",
                },
                pd_kwargs={
                    "index": False,
                },
                max_rows_per_file=1000000,
                replace=True,
                file_format="parquet",
            )

            get_backfill_flag_task >> oc_load_task
            load_tasks.append(oc_load_task)

    loyalty_dbt = create_dbt_cloud_task_group(
        group_id="loyalty_dbt",
        job_id=DBT_CLOUD_FESLOYALTY_JOB_ID,
    )

    load_tasks >> loyalty_dbt
    compare_task = compare_row_counts()
    loyalty_dbt >> compare_task


dag = loyalty_postgres_to_s3_ingest()
