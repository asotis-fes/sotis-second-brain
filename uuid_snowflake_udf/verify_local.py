#!/usr/bin/env python3
"""
Offline proof of the UUIDv7 bit-assembly used by the Snowflake UDF.

This mirrors, line-for-line, the logic in sql/uuidv7.sql (UUIDV7_ASSEMBLE JS UDF)
so we can validate the RFC 9562 layout WITHOUT a Snowflake warehouse. The Snowflake
tests in sql/test_uuidv7.sql assert the same properties in-database.

Assembly (RFC 9562 §5.7):
  32 hex chars grouped 8-4-4-4-12 =
    [ 48-bit unix_ts_ms ][ '7' + rand_a(12b) ][ variant(2b)=10 + rand_b... ]
"""
import re

HEX_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


def assemble(epoch_ms: int, rand_hex: str) -> str:
    """Exact mirror of the UUIDV7_ASSEMBLE SQL UDF (sql/uuidv7.sql)."""
    ts_hex = f"{epoch_ms & 0xFFFFFFFFFFFF:012x}"        # low 48 bits, 12 hex chars
    r = rand_hex.replace("-", "").lower()
    a = r[0:3]                                          # rand_a  (12 bits)  @ chars 1-3
    variant = format((int(r[16], 16) & 3) | 8, "x")     # variant nibble @ char 17, forced 10xx
    b = r[17:20]                                         # rand_b  (12 bits) @ chars 18-20
    c = r[20:32]                                         # rand_b  (48 bits) @ chars 21-32
    return f"{ts_hex[0:8]}-{ts_hex[8:12]}-7{a}-{variant}{b}-{c}"


def ts_from_uuid(u: str) -> int:
    """Recover unix_ts_ms from the first 48 bits."""
    h = u.replace("-", "")
    return int(h[0:12], 16)


# ---------------------------------------------------------------------------
def main() -> None:
    failures = []

    def check(name, cond):
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}")
        if not cond:
            failures.append(name)

    print("Test 1 — reconstruct the RFC 9562 §B.2 example vector")
    # RFC vector: 017F22E2-79B0-7CC3-98C4-DC0C0C07398F, unix_ts_ms = 0x017F22E279B0
    rfc_ms = 0x017F22E279B0
    # Feed the RFC's own random bits back in at their char positions:
    # rand_a=cc3 @1-3, variant nibble @17='9', rand_b=8c4 @18-20 + dc0c0c07398f @21-32.
    rfc_rand = "cc3" + "0000000000000" + "9" + "8c4" + "dc0c0c07398f"
    got = assemble(rfc_ms, rfc_rand)
    want = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
    check(f"RFC vector reproduced ({got})", got == want)
    check("RFC ms decodes to 0x017F22E279B0", ts_from_uuid(got) == rfc_ms)

    print("Test 2 — format / version / variant over 5000 pseudo-random samples")
    import hashlib
    fmt_ok = ver_ok = var_ok = True
    seen = set()
    for i in range(5000):
        rh = hashlib.sha256(str(i).encode()).hexdigest()      # stand-in for UUID_STRING()
        ms = 1_600_000_000_000 + i
        u = assemble(ms, rh)
        if not HEX_RE.match(u):
            fmt_ok = False
        if u[14] != "7":
            ver_ok = False
        if u[19] not in "89ab":
            var_ok = False
        seen.add(u)
    check("all match canonical UUIDv7 regex", fmt_ok)
    check("version nibble always 7", ver_ok)
    check("variant nibble always in {8,9,a,b}", var_ok)
    check("5000/5000 unique", len(seen) == 5000)

    print("Test 3 — timestamp round-trips exactly")
    rt_ok = True
    for ms in [0, 1, 1645557742000, 1_700_000_000_123, 0xFFFFFFFFFFFF]:
        if ts_from_uuid(assemble(ms, "0" * 32)) != (ms & 0xFFFFFFFFFFFF):
            rt_ok = False
    check("ms -> uuid -> ms round-trip", rt_ok)

    print("Test 4 — k-sortable: earlier ts sorts lexicographically first")
    fixed = "abcdef0123456789abcdef0123456789"
    seq = [assemble(1_600_000_000_000 + n * 1000, fixed) for n in range(50)]
    check("lexical order == chronological order", seq == sorted(seq))

    print()
    if failures:
        print(f"FAILED: {failures}")
        raise SystemExit(1)
    print("ALL LOCAL TESTS PASSED")


if __name__ == "__main__":
    main()
