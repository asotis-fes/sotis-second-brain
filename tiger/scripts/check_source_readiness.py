#!/usr/bin/env python3
"""Report how many source rows would be `ready_to_send` per platform, and the
per-field fill rates that gate readiness. NO external calls — read-only Snowflake.

This surfaces the gaps in ../gap-analysis.md against live data, so you know what
the export jobs will actually have to work with before you build them.

Usage:
    python check_source_readiness.py
"""
from __future__ import annotations

from _common import SOURCE_TABLE, run_query


def main() -> None:
    print(f"Source: {SOURCE_TABLE}\n")

    fill = run_query(
        f"""
        SELECT
            COUNT(*) AS total_rows,
            COUNT_IF(register_ts >= CURRENT_DATE()-7) AS rows_last_7d,
            ROUND(100*COUNT_IF(sha256_hashed_email IS NOT NULL)/COUNT(*),1) AS pct_email,
            ROUND(100*COUNT_IF(ip_address IS NOT NULL)/COUNT(*),1) AS pct_ip,
            ROUND(100*COUNT_IF(user_agent IS NOT NULL)/COUNT(*),1) AS pct_user_agent,
            ROUND(100*COUNT_IF(platform IS NOT NULL)/COUNT(*),1) AS pct_platform,
            ROUND(100*COUNT_IF(consent_status IS NOT NULL)/COUNT(*),1) AS pct_consent,
            ROUND(100*COUNT_IF(firebase_app_instance_id IS NOT NULL)/COUNT(*),1) AS pct_fb_iid,
            ROUND(100*COUNT_IF(extinfo_0_version IS NOT NULL)/COUNT(*),1) AS pct_extinfo_0
        FROM {SOURCE_TABLE}
        """
    )[0]

    print("=== Field fill rates ===")
    for k, v in fill.items():
        flag = ""
        if k.lower().startswith("pct_") and isinstance(v, (int, float)):
            flag = "  <-- BLOCKER (empty)" if v == 0 else ("  <-- sparse" if v < 80 else "")
        print(f"  {k:<18} {v}{flag}")

    ready = run_query(
        f"""
        SELECT
            -- Meta readiness gate (ENTDATA-2264): email+ip+ua+platform+extinfo_0
            COUNT_IF(
                sha256_hashed_email IS NOT NULL AND ip_address IS NOT NULL
                AND user_agent IS NOT NULL AND platform IS NOT NULL
                AND extinfo_0_version IS NOT NULL
            ) AS meta_ready,
            -- Firebase readiness gate (ENTDATA-2265): firebase_app_instance_id+platform
            COUNT_IF(
                firebase_app_instance_id IS NOT NULL AND platform IS NOT NULL
            ) AS firebase_ready,
            COUNT(*) AS total
        FROM {SOURCE_TABLE}
        WHERE is_new_to_fbg = TRUE
        """
    )[0]

    total = ready["TOTAL"] or 0
    print("\n=== ready_to_send counts (event=new_fbg) ===")
    for label, key in (("Meta CAPI", "META_READY"), ("Firebase MP", "FIREBASE_READY")):
        n = ready[key] or 0
        pct = (100 * n / total) if total else 0
        verdict = "  <-- NOTHING TO SEND" if n == 0 else ""
        print(f"  {label:<12} {n:>8,} / {total:,} ready ({pct:.1f}%){verdict}")

    print("\nSee ../gap-analysis.md for the full interpretation.")


if __name__ == "__main__":
    main()
