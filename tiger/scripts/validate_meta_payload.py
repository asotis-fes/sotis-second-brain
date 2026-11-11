#!/usr/bin/env python3
"""Build Meta CAPI payloads from real source rows and validate them LOCALLY.

Default mode does NOT send anything. It fetches ready rows, builds the exact
payload the Airflow job would build, and runs the structural checks Meta enforces
server-side (16-string extinfo, hashed email, int event_time, etc.).

Optional --send-test routes events to Meta's Test Events tab ONLY (requires a
--test-event-code and the META_ACCESS_TOKEN / META_DATASET_ID env vars). It never
sends production events.

Usage:
    python validate_meta_payload.py --limit 50
    python validate_meta_payload.py --limit 10 --send-test --test-event-code TEST12345
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from _common import build_meta_event, fetch_meta_source_rows, validate_meta_event

GRAPH_API_VERSION = "v20.0"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--event", default="new_fbg")
    ap.add_argument("--limit", type=int, default=50)
    ap.add_argument("--send-test", action="store_true",
                    help="POST to Meta Test Events tab (needs --test-event-code).")
    ap.add_argument("--test-event-code", default=None)
    args = ap.parse_args()

    rows = fetch_meta_source_rows(args.event, args.limit)
    print(f"Fetched {len(rows)} ready '{args.event}' rows from source.\n")
    if not rows:
        print("No ready rows — nothing to validate. (Check gap-analysis.md.)")
        return

    events, bad = [], 0
    for r in rows:
        e = build_meta_event(r)
        errs = validate_meta_event(e)
        events.append(e)
        if errs:
            bad += 1
            print(f"  INVALID: {errs}")

    print(f"\nBuilt {len(events)} events — {len(events) - bad} valid, {bad} invalid.")
    print("\n--- sample payload ---")
    print(json.dumps({"data": [events[0]]}, indent=2, default=str))

    if not args.send_test:
        print("\n(build + validate only; no data sent. Use --send-test to hit Test Events.)")
        return

    if not args.test_event_code:
        sys.exit("--send-test requires --test-event-code (routes to Test Events tab).")
    token = os.environ.get("META_ACCESS_TOKEN")
    dataset = os.environ.get("META_DATASET_ID")
    if not token or not dataset:
        sys.exit("Set META_ACCESS_TOKEN and META_DATASET_ID env vars to send test events.")

    import requests

    endpoint = f"https://graph.facebook.com/{GRAPH_API_VERSION}/{dataset}/events"
    payload = {"data": events, "test_event_code": args.test_event_code}
    resp = requests.post(endpoint, params={"access_token": token}, json=payload, timeout=60)
    print(f"\nTest send → HTTP {resp.status_code}: {resp.text[:400]}")


if __name__ == "__main__":
    main()
