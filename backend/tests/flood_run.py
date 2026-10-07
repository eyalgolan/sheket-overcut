"""Synthetic report flood through the aggregate handler (issue #49).

Not a test module: ``test_aggregate_flood.py`` runs it as a fresh
subprocess per shape, so each shape's peak RSS (``ru_maxrss``) is its own and
includes the boto3, botocore and jsonschema imports the Lambda also pays for.

The real ``aggregate.handler`` runs end to end. Only the two AWS clients are
stubs: the DynamoDB stub generates report pages lazily in DynamoDB wire
format, one page at a time, and serves the override partition; the S3 stub
has no previous blocklist and records the put. Nothing reaches the network.

Usage: python tests/flood_run.py <shape>   (prints one JSON line on stdout)
"""

import json
import logging
import os
import resource
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
NOW = 1791201600  # 2026-10-05T12:00:00Z, a whole second like ``_now``.
PAGE = 1000  # Items per DynamoDB page (1 MB pages hold ~5000 of these).
# About 100 IPv4 addresses x 60 reports per hour x 168 hours (issue #49).
FLOOD = 1_008_000

# shape: (generated reports, sender pattern)
SHAPES = {
    # Every report a different sender: nothing qualifies, every group stays
    # counted, so this is the worst case for memory. 1.2M is above the cap.
    "distinct_over_cap": (1_200_000, "distinct"),
    # 100 senders flooded by distinct installs: each qualifies after a few
    # reports and is then no longer counted.
    "few_senders": (FLOOD, "few"),
}

FORCE_CALL = "+972521112233"
OVERRIDES = [f"force_block#call#{FORCE_CALL}", "never_block#+972500000007"]


def _stubs(total, pattern):
    from botocore.exceptions import ClientError

    from sheket import aggregate

    now_dt = datetime.fromtimestamp(NOW, timezone.utc)
    cutoff = now_dt - aggregate.WINDOW
    days = []
    day = cutoff.date()
    while day <= now_dt.date():
        days.append(day)
        day += timedelta(days=1)
    share = [
        total // len(days) + (1 if i < total % len(days) else 0)
        for i in range(len(days))
    ]
    offsets = [sum(share[:i]) for i in range(len(days))]

    def received_at(seconds):
        return datetime.fromtimestamp(seconds, timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S.000Z"
        )

    class StubDynamoDB:
        generated = 0

        def query(self, **params):
            values = params["ExpressionAttributeValues"]
            if ":o" in values:
                return {"Items": [{"sk": {"S": sk}} for sk in OVERRIDES]}
            pk = values[":pk"]["S"]
            idx = days.index(date.fromisoformat(pk[2:]))
            day_start = int(
                datetime.combine(
                    days[idx], datetime.min.time(), timezone.utc
                ).timestamp()
            )
            lo = max(day_start, int(cutoff.timestamp()))
            span = min(day_start + 86399, NOW) - lo + 1
            start = int(params.get("ExclusiveStartKey", {}).get("n", {"N": "0"})["N"])
            end = min(start + PAGE, share[idx])
            items = []
            for j in range(start, end):
                i = offsets[idx] + j
                n = i % 100 if pattern == "few" else i
                items.append(
                    {
                        "kind": {"S": "call"},
                        "sender": {"S": f"+97250{n:07d}"},
                        "install_id": {"S": f"{i:08x}-0000-4000-8000-{i:012x}"},
                        "net_hash": {"S": f"{i % 1000:064x}"},
                        "received_at": {"S": received_at(lo + j % span)},
                    }
                )
            StubDynamoDB.generated += len(items)
            page = {"Items": items}
            if end < share[idx]:
                page["LastEvaluatedKey"] = {"pk": {"S": pk}, "n": {"N": str(end)}}
            return page

    class StubS3:
        body = None

        def get_object(self, **_):
            raise ClientError({"Error": {"Code": "NoSuchKey"}}, "GetObject")

        def put_object(self, **kwargs):
            StubS3.body = kwargs["Body"]

    return StubDynamoDB, StubS3


def _peak_rss_mb():
    """Return this process's own peak RSS in MB.

    On Linux ``ru_maxrss`` survives fork + exec, so a child of a large pytest
    process would report the parent's peak; ``VmHWM`` is reset at exec.
    """
    try:
        with open("/proc/self/status", encoding="ascii") as fh:
            for line in fh:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1]) / 1024
    except OSError:
        pass
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # ru_maxrss is kilobytes on Linux and bytes on macOS.
    return peak / (1024 * 1024) if sys.platform == "darwin" else peak / 1024


def run_shape(name):
    started = time.monotonic()
    sys.path.insert(0, str(REPO / "backend" / "src"))
    for key, value in {
        "AWS_DEFAULT_REGION": "us-east-1",
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "TABLE_NAME": "reports",
        "BUCKET_NAME": "sheket-blocklist-test",
        "MIN_INSTALLS": "3",
        "MIN_NETWORKS": "2",
    }.items():
        os.environ[key] = value
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)

    import boto3

    from sheket import aggregate

    # The Lambda builds both real clients; build them too (unused, no network)
    # so their botocore models count towards the peak.
    boto3.client("dynamodb")
    boto3.client("s3")

    total, pattern = SHAPES[name]
    StubDynamoDB, StubS3 = _stubs(total, pattern)
    aggregate.CONTRACT_DIR = REPO / "contract"
    aggregate._now = lambda: NOW
    aggregate._ddb_client = StubDynamoDB()
    aggregate._s3_client = StubS3()

    run_started = time.monotonic()
    aggregate.handler({"source": "aws.scheduler"}, None)
    run_seconds = time.monotonic() - run_started

    peak_mb = _peak_rss_mb()
    doc = json.loads(StubS3.body.decode("utf-8"))
    return {
        "shape": name,
        "generated": total,
        "stub_items_produced": StubDynamoDB.generated,
        "run_seconds": round(run_seconds, 2),
        "total_seconds": round(time.monotonic() - started, 2),
        "peak_rss_mb": round(peak_mb, 1),
        "doc": doc,
    }


if __name__ == "__main__":
    print(json.dumps(run_shape(sys.argv[1])))
