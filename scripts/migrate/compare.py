#!/usr/bin/env python3
"""Compare the COUNTS line from the legacy stack with the one from AWS.

Usage:  python3 scripts/migrate/compare.py migration/legacy-counts.txt migration/aws-counts.txt
Exit code 0 means everything matches.
"""
import json
import sys


def read_counts(path: str) -> dict:
    for line in open(path):
        if line.startswith("COUNTS "):
            return json.loads(line.removeprefix("COUNTS "))
    sys.exit(f"No COUNTS line found in {path}")


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    legacy, aws = read_counts(sys.argv[1]), read_counts(sys.argv[2])

    ok = True
    print(f"{'check':<26}{'legacy':>10}{'aws':>10}  result")
    for key in sorted(set(legacy) | set(aws)):
        a, b = legacy.get(key), aws.get(key)
        match = a == b
        ok &= match
        if isinstance(a, list) or isinstance(b, list):
            a, b = f"{len(a or [])} items", f"{len(b or [])} items"
        print(f"{key:<26}{str(a):>10}{str(b):>10}  {'OK' if match else 'MISMATCH'}")

    if aws.get("finished_files_present") != aws.get("finished_files_expected"):
        ok = False
        print("\nSome finished jobs on AWS point at files that are not in S3.")

    print("\nMIGRATION VERIFIED: everything matches." if ok else "\nMIGRATION NOT VERIFIED: see mismatches above.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
