"""Shared helpers for the Tiger local validation scripts.

These are LOCAL, TEMPORARY, and do NOT send data to production ad platforms.
They query the live source table via the `snow` CLI (reusing your existing
FAN_DATA_EXCHANGE_PROD connection), apply the AE export transform inline, and
build the platform payloads so you can validate the whole pipeline end-to-end.

No secrets are hardcoded here. Credentials for the optional validation endpoints
are read from environment variables at call time.
"""
from __future__ import annotations

import csv
import io
import subprocess
from typing import Any

SNOW_CONNECTION = "FAN_DATA_EXCHANGE_PROD"
WAREHOUSE = "FDE_DEVELOPER_WH"
SOURCE_TABLE = "fes_users.zoe_sarwar.gl_new_to_x"

# extinfo indices 5-15 (all must be strings) — mirrors the Airflow send job.
EXTINFO_STATIC_TAIL = ["", "en_US", "", "", "390", "844", "3.00", "6", "256", "128", ""]
ENGAGEMENT_TIME_MSEC = 1000

# Map the "new-to-X" flags to event names (the AE readiness derivation).
EVENT_FLAG_MAP = {
    "new_fbg": "is_new_to_fbg",
    "new_commerce": "is_new_to_commerce",
    "new_fanatics": "is_new_to_fanatics",
    "new_collectibles": "is_new_to_collectibles",
}


def run_query(sql: str) -> list[dict[str, Any]]:
    """Run a read-only SELECT via the snow CLI and return rows as dicts.

    Uses --format csv (the JSON formatter hangs on some snow CLI builds). Snowflake
    returns UPPERCASE column headers; callers use case-insensitive lookups.
    """
    full_sql = f"USE WAREHOUSE {WAREHOUSE}; {sql}"
    proc = subprocess.run(
        ["snow", "sql", "-c", SNOW_CONNECTION, "--format", "csv", "--query", full_sql],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"snow query failed:\n{proc.stderr or proc.stdout}")
    return _parse_last_csv_block(proc.stdout)


def _parse_last_csv_block(out: str) -> list[dict[str, Any]]:
    """snow prints one CSV block per statement (USE WAREHOUSE emits a 'status'
    block first); return the last block that isn't just a status line."""
    blocks, current = [], []
    for line in out.splitlines():
        if line.strip() == "":
            if current:
                blocks.append(current)
                current = []
            continue
        current.append(line)
    if current:
        blocks.append(current)

    for block in reversed(blocks):
        header = next(csv.reader([block[0]]))
        if header == ["status"]:
            continue
        rows = list(csv.DictReader(io.StringIO("\n".join(block))))
        # csv gives all strings; coerce numerics so callers can do arithmetic/format.
        return [{k: _coerce(v) for k, v in row.items()} for row in rows]
    return []


def _coerce(v: str) -> Any:
    if v is None or v == "":
        return None
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        return v


def fetch_meta_source_rows(event_name: str, limit: int) -> list[dict]:
    """Fetch source rows shaped like the AE meta_capi_export transform.

    Mirrors ENTDATA-2264 with the gap fixes applied:
    - fn/ln omitted (no first_name/last_name column exists in source).
    - readiness = email + ip + user_agent + platform + extinfo_0 all present.
    """
    flag = EVENT_FLAG_MAP[event_name]
    sql = f"""
    SELECT
        fanapp_tenant_fan_id,
        '{event_name}' AS event_name,
        register_ts AS event_time,
        sha256_hashed_email,
        ip_address AS client_ip_address,
        user_agent AS client_user_agent,
        SHA2(LOWER(TRIM(fanapp_tenant_fan_id)), 256) AS external_id_hashed,
        CASE WHEN consent_status = 'authorized' THEN 1 ELSE 0 END AS advertiser_tracking_enabled,
        platform,
        extinfo_0_version AS extinfo_0,
        extinfo_1_package AS extinfo_1,
        extinfo_2_short_version AS extinfo_2,
        extinfo_3_long_version AS extinfo_3,
        extinfo_4_os_version AS extinfo_4
    FROM {SOURCE_TABLE}
    WHERE {flag} = TRUE
      AND sha256_hashed_email IS NOT NULL
      AND ip_address IS NOT NULL
      AND user_agent IS NOT NULL
      AND platform IS NOT NULL
      AND extinfo_0_version IS NOT NULL
    ORDER BY register_ts DESC
    LIMIT {int(limit)}
    """
    return run_query(sql)


def fetch_firebase_source_rows(event_name: str, limit: int) -> list[dict]:
    """Fetch source rows shaped like the AE firebase_mp_export transform (ENTDATA-2265)."""
    flag = EVENT_FLAG_MAP[event_name]
    sql = f"""
    SELECT
        fanapp_tenant_fan_id,
        '{event_name}' AS event_name,
        register_ts AS event_time,
        LOWER(firebase_app_instance_id) AS firebase_app_instance_id,
        platform
    FROM {SOURCE_TABLE}
    WHERE {flag} = TRUE
      AND firebase_app_instance_id IS NOT NULL
      AND platform IS NOT NULL
    ORDER BY register_ts DESC
    LIMIT {int(limit)}
    """
    return run_query(sql)


def build_meta_event(r: dict) -> dict:
    """Build one Meta CAPI event — identical logic to the Airflow send job."""
    extinfo = [
        str(r.get("EXTINFO_0") or r.get("extinfo_0") or ""),
        str(r.get("EXTINFO_1") or r.get("extinfo_1") or ""),
        str(r.get("EXTINFO_2") or r.get("extinfo_2") or ""),
        str(r.get("EXTINFO_3") or r.get("extinfo_3") or ""),
        str(r.get("EXTINFO_4") or r.get("extinfo_4") or ""),
        *EXTINFO_STATIC_TAIL,
    ]
    g = lambda k: r.get(k.upper(), r.get(k.lower()))  # noqa: E731  snow uppercases keys
    return {
        "event_name": g("event_name"),
        "event_time": _to_unix(g("event_time")),
        "action_source": "app",
        "user_data": {
            "em": [g("sha256_hashed_email")],
            "client_ip_address": str(g("client_ip_address") or ""),
            "client_user_agent": str(g("client_user_agent") or ""),
            "external_id": [g("external_id_hashed")],  # already hashed — do NOT re-hash
        },
        "app_data": {
            "advertiser_tracking_enabled": int(g("advertiser_tracking_enabled") or 0),
            "application_tracking_enabled": 1,
            "extinfo": extinfo,
        },
        "custom_data": {"currency": "USD"},
    }


def build_firebase_payload(r: dict) -> dict:
    g = lambda k: r.get(k.upper(), r.get(k.lower()))  # noqa: E731
    return {
        "app_instance_id": str(g("firebase_app_instance_id")).lower(),
        "user_id": g("fanapp_tenant_fan_id"),
        "events": [
            {
                "name": g("event_name"),
                "params": {"currency": "USD", "engagement_time_msec": ENGAGEMENT_TIME_MSEC},
            }
        ],
    }


def validate_meta_event(e: dict) -> list[str]:
    """Local structural validation — the checks Meta enforces server-side."""
    errs = []
    if e.get("action_source") != "app":
        errs.append("action_source must be 'app'")
    if not isinstance(e.get("event_time"), int):
        errs.append("event_time must be an int (unix seconds)")
    em = e.get("user_data", {}).get("em")
    if not em or not em[0]:
        errs.append("user_data.em (hashed email) is required")
    ext = e.get("app_data", {}).get("extinfo")
    if not isinstance(ext, list) or len(ext) != 16:
        errs.append("extinfo must have exactly 16 positions")
    elif not all(isinstance(x, str) for x in ext):
        errs.append("all 16 extinfo positions must be STRINGS (Meta 400 otherwise)")
    return errs


def _to_unix(ts: Any) -> Any:
    """Best-effort convert a snow JSON timestamp string to unix seconds."""
    if ts is None:
        return None
    if isinstance(ts, (int, float)):
        return int(ts)
    from datetime import datetime

    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S.%f",
                "%Y-%m-%d %H:%M:%S"):
        try:
            return int(datetime.strptime(str(ts)[:26], fmt).timestamp())
        except ValueError:
            continue
    return str(ts)
