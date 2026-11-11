#!/usr/bin/env python3
"""Build Firebase MP payloads from real source rows and validate them via Google's
`/debug/mp/collect` endpoint, which returns `validationMessages` and NEVER records
an event. Falls back to local structural checks if no credentials are set.

This will typically report "0 ready rows" today, because firebase_app_instance_id
is ~0% populated upstream (the known blocker — see ../gap-analysis.md).

Usage:
    python validate_firebase_payload.py --limit 50
"""
from __future__ import annotations

import argparse
import json
import os

from _common import build_firebase_payload, fetch_firebase_source_rows

DEBUG_ENDPOINT = "https://www.google-analytics.com/debug/mp/collect"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--event", default="new_fbg")
    ap.add_argument("--limit", type=int, default=50)
    args = ap.parse_args()

    rows = fetch_firebase_source_rows(args.event, args.limit)
    print(f"Fetched {len(rows)} ready '{args.event}' rows from source.\n")
    if not rows:
        print(
            "No ready rows — nothing to validate.\n"
            "Expected: firebase_app_instance_id is ~0% populated upstream. This IS\n"
            "the blocker documented in ../gap-analysis.md. Firebase export cannot\n"
            "send until that column is populated (or the BigQuery fallback is built)."
        )
        return

    payloads = [build_firebase_payload(r) for r in rows]
    print("--- sample payload ---")
    print(json.dumps(payloads[0], indent=2, default=str))

    creds = {
        "iOS": (os.environ.get("FIREBASE_APP_ID_IOS"), os.environ.get("FIREBASE_API_SECRET_IOS")),
        "Android": (os.environ.get("FIREBASE_APP_ID_ANDROID"), os.environ.get("FIREBASE_API_SECRET_ANDROID")),
    }
    if all(None in pair for pair in creds.values()):
        print("\n(No FIREBASE_* env vars set — skipping Google debug validation. "
              "Payloads built OK locally.)")
        return

    import requests

    ok = issues = 0
    for r, payload in zip(rows, payloads):
        platform = r.get("PLATFORM", r.get("platform"))
        app_id, secret = creds.get(platform, (None, None))
        if not app_id or not secret:
            print(f"  skip: no creds for platform={platform!r}")
            continue
        resp = requests.post(
            DEBUG_ENDPOINT,
            params={"firebase_app_id": app_id, "api_secret": secret},
            json=payload,
            timeout=30,
        )
        msgs = resp.json().get("validationMessages", [])
        if msgs:
            issues += 1
            print(f"  validation issues: {msgs}")
        else:
            ok += 1

    print(f"\nDebug validation: {ok} clean, {issues} with issues. "
          "(No events recorded — /debug endpoint only.)")


if __name__ == "__main__":
    main()
