"""Tests for the aggregate Lambda under a report flood (issue #49).

Covers the four parts of the fix:

- reports are streamed page by page (``_query_items``, ``_load_reports``);
- a ``(kind, sender)`` group stops being counted once it qualifies
  (``_published``), with the same published result as counting everything;
- the read is capped per run by ``MAX_REPORTS_PER_RUN`` and
  ``READ_TIME_BUDGET``, and a capped run still publishes the curated list,
  the overrides and the senders that already qualified;
- a synthetic ~1M-report flood runs through the real handler in a fresh
  subprocess (``flood_run.py``), and ``infra/lambda.tf`` is checked against
  its measured peak memory and time.
"""

import json
import logging
import random
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import BUCKET_NAME, TABLE_NAME, load_contract
from test_aggregate_handler import (
    CALL,
    NET_A,
    NET_B,
    NOW,
    NOW_DT,
    SMS,
    SMS_NORMALISED,
    emf_lines,
    install_id,
    published,
    put_group,
    put_override,
    put_report,
    run,
)

from sheket import aggregate
from sheket.normalize import is_e164, normalize_sender

TESTS_DIR = Path(__file__).resolve().parent
LAMBDA_TF = TESTS_DIR.parents[1] / "infra" / "lambda.tf"

# Eight UTC day partitions for NOW (2026-10-06T12:00:00Z), oldest first.
DAYS = [
    f"R#{(NOW_DT - timedelta(days=d)).strftime('%Y-%m-%d')}" for d in range(7, -1, -1)
]
# The order _load_reports queries them in: today first.
NEWEST_FIRST = DAYS[::-1]


@pytest.fixture(autouse=True)
def aggregate_env(monkeypatch, contract_dir):
    """Configure the handler as Terraform would, like the handler tests."""
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("BUCKET_NAME", BUCKET_NAME)
    monkeypatch.setenv("MIN_INSTALLS", "3")
    monkeypatch.setenv("MIN_NETWORKS", "2")
    monkeypatch.setattr(aggregate, "CONTRACT_DIR", contract_dir)


@pytest.fixture
def aws(ddb_table, s3_bucket, monkeypatch):
    monkeypatch.setattr(aggregate, "_now", lambda: NOW)
    return ddb_table, s3_bucket


class FakeMonotonic:
    """``aggregate._monotonic`` under test control; counts its reads."""

    def __init__(self, value=0.0):
        self.value = value
        self.reads = 0

    def __call__(self):
        self.reads += 1
        return self.value


@pytest.fixture
def mono(monkeypatch):
    clock = FakeMonotonic()
    monkeypatch.setattr(aggregate, "_monotonic", clock)
    return clock


class StubPartitions:
    """A DynamoDB stub serving ``per_day`` items in every report partition.

    Items come in pages of ``page`` with a real ``LastEvaluatedKey`` chain.
    Every call is recorded, so tests can see which pages were fetched.
    """

    def __init__(self, per_day, page=2, item=None):
        self.per_day = per_day
        self.page = page
        self.item = item
        self.calls = []

    def query(self, **params):
        self.calls.append(params)
        pk = params["ExpressionAttributeValues"][":pk"]["S"]
        start = int(params.get("ExclusiveStartKey", {}).get("n", {"N": "0"})["N"])
        end = min(start + self.page, self.per_day)
        items = [
            self.item if self.item is not None else {"sk": {"S": f"{pk}#{i}"}}
            for i in range(start, end)
        ]
        page = {"Items": items}
        if end < self.per_day:
            page["LastEvaluatedKey"] = {"pk": {"S": pk}, "n": {"N": str(end)}}
        return page

    @property
    def partitions(self):
        """Distinct partitions queried, in first-query order."""
        seen = []
        for call in self.calls:
            pk = call["ExpressionAttributeValues"][":pk"]["S"]
            if pk not in seen:
                seen.append(pk)
        return seen


def capped_messages(caplog):
    return [
        r.getMessage()
        for r in caplog.records
        if r.getMessage().startswith("report read capped")
    ]


def loaded_messages(caplog):
    return [
        r.getMessage() for r in caplog.records if r.getMessage().startswith("loaded ")
    ]


# --- streaming: _query_items and the lazy _load_reports ------------------------


def test_query_items_fetches_the_next_page_only_when_needed(monkeypatch):
    stub = StubPartitions(per_day=5, page=2)
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    params = {"ExpressionAttributeValues": {":pk": {"S": DAYS[0]}}}

    items = aggregate._query_items(**params)
    assert stub.calls == []  # nothing is read until iterated
    assert next(items) == {"sk": f"{DAYS[0]}#0"}
    assert len(stub.calls) == 1
    assert next(items) == {"sk": f"{DAYS[0]}#1"}
    assert len(stub.calls) == 1  # still the first page
    assert next(items) == {"sk": f"{DAYS[0]}#2"}
    assert len(stub.calls) == 2
    assert [i["sk"] for i in items] == [f"{DAYS[0]}#3", f"{DAYS[0]}#4"]
    assert len(stub.calls) == 3
    # The caller's kwargs are never mutated by the pagination.
    assert params == {"ExpressionAttributeValues": {":pk": {"S": DAYS[0]}}}


def test_query_items_and_query_all_return_the_same_items(monkeypatch):
    item = {"kind": {"S": "sms"}, "n": {"N": "1"}, "odd": "x"}
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(5, 2, item))
    streamed = list(
        aggregate._query_items(ExpressionAttributeValues={":pk": {"S": "p"}})
    )
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(5, 2, item))
    listed = aggregate._query_all(ExpressionAttributeValues={":pk": {"S": "p"}})
    assert isinstance(listed, list)
    assert streamed == listed == [{"kind": "sms"}] * 5


def test_load_reports_reads_nothing_until_iterated(mono):
    # The autouse fixture's client fails the test on any use.
    reports = aggregate._load_reports(TABLE_NAME, NOW)
    assert mono.reads == 0
    del reports


def test_uncapped_read_yields_every_item_newest_partition_first(
    monkeypatch, mono, caplog
):
    stub = StubPartitions(per_day=3, page=2)
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 24)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    items = list(aggregate._load_reports(TABLE_NAME, NOW))

    assert [i["sk"] for i in items] == [
        f"{d}#{n}" for d in NEWEST_FIRST for n in range(3)
    ]
    assert stub.partitions == NEWEST_FIRST
    assert capped_messages(caplog) == []
    assert loaded_messages(caplog) == ["loaded 24 reports from 8 day partitions"]


def test_reports_are_read_newest_first_within_a_partition(aws, mono):
    ddb, _ = aws
    put_report(ddb, "call", CALL, 0, NET_A, NOW_DT - timedelta(hours=2))
    put_report(ddb, "call", CALL, 1, NET_B, NOW_DT - timedelta(hours=1))

    items = list(aggregate._load_reports(TABLE_NAME, NOW))

    assert [i["install_id"] for i in items] == [install_id(1), install_id(0)]


def test_item_cap_keeps_the_newest_report_of_a_partition(aws, mono, monkeypatch):
    ddb, _ = aws
    put_report(ddb, "call", CALL, 0, NET_A, NOW_DT - timedelta(hours=2))
    put_report(ddb, "call", CALL, 1, NET_B, NOW_DT - timedelta(hours=1))
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 1)

    (item,) = aggregate._load_reports(TABLE_NAME, NOW)

    assert item["install_id"] == install_id(1)
    assert item["received_at"] == "2026-10-06T11:00:00.000Z"


# --- the item cap ---------------------------------------------------------------


def test_item_cap_stops_the_read_and_skips_the_older_partitions(
    monkeypatch, mono, caplog
):
    stub = StubPartitions(per_day=3, page=2)
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 4)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    items = list(aggregate._load_reports(TABLE_NAME, NOW))

    # Newest first: all of today, then the first item of yesterday.
    assert [i["sk"] for i in items] == [
        f"{NEWEST_FIRST[0]}#0",
        f"{NEWEST_FIRST[0]}#1",
        f"{NEWEST_FIRST[0]}#2",
        f"{NEWEST_FIRST[1]}#0",
    ]
    assert stub.partitions == NEWEST_FIRST[:2]
    (warning,) = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert warning.getMessage() == (
        "report read capped: 4 reports, 2 of 8 day partitions, 0.0 s"
    )
    assert loaded_messages(caplog) == ["loaded 4 reports from 2 day partitions"]


def test_reading_exactly_the_cap_is_not_capped(monkeypatch, mono, caplog):
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(per_day=3))
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 24)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    status = {"capped": False}
    assert len(list(aggregate._load_reports(TABLE_NAME, NOW, status=status))) == 24
    assert status == {"capped": False}
    assert capped_messages(caplog) == []
    assert loaded_messages(caplog) == ["loaded 24 reports from 8 day partitions"]


def test_one_item_over_the_cap_is_capped(monkeypatch, mono, caplog):
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(per_day=3))
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 23)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    status = {"capped": False}
    assert len(list(aggregate._load_reports(TABLE_NAME, NOW, status=status))) == 23
    assert status == {"capped": True}
    assert capped_messages(caplog) == [
        "report read capped: 23 reports, 8 of 8 day partitions, 0.0 s"
    ]


def test_malformed_items_count_towards_the_cap(monkeypatch, mono):
    # No string attribute at all: each converts to {} and is skipped later.
    stub = StubPartitions(per_day=3, item={"x": {"N": "1"}})
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 2)

    assert list(aggregate._load_reports(TABLE_NAME, NOW)) == [{}, {}]
    assert stub.partitions == NEWEST_FIRST[:1]


def test_default_cap_covers_the_issue_flood():
    # About 100 IPv4 addresses x 60 reports per hour x 7 days (issue #49).
    assert aggregate.MAX_REPORTS_PER_RUN == 1_000_000
    assert 0 < aggregate.READ_TIME_BUDGET < 15 * 60


# --- the time budget --------------------------------------------------------------


def test_time_budget_stops_the_read(monkeypatch, mono, caplog):
    stub = StubPartitions(per_day=3)
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")
    budget = aggregate.READ_TIME_BUDGET

    taken = []
    for item in aggregate._load_reports(TABLE_NAME, NOW):
        taken.append(item)
        # The consumer's work counts: building runs between the items.
        mono.value += budget / 4

    assert len(taken) == 4
    assert stub.partitions == NEWEST_FIRST[:2]
    assert capped_messages(caplog) == [
        f"report read capped: 4 reports, 2 of 8 day partitions, {budget:.1f} s"
    ]
    assert loaded_messages(caplog) == ["loaded 4 reports from 2 day partitions"]


def test_time_just_under_the_budget_is_not_capped(monkeypatch, mono, caplog):
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(per_day=1))
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    taken = 0
    for _ in aggregate._load_reports(TABLE_NAME, NOW):
        taken += 1
        mono.value = aggregate.READ_TIME_BUDGET - 0.001

    assert taken == 8
    assert capped_messages(caplog) == []


def test_time_budget_starts_at_the_first_item_not_at_creation(monkeypatch, mono):
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(per_day=1))
    reports = aggregate._load_reports(TABLE_NAME, NOW)
    # The handler opens the stream, then loads the overrides and S3 first.
    mono.value = 10 * aggregate.READ_TIME_BUDGET
    assert len(list(reports)) == 8


def test_time_budget_uses_the_monotonic_clock_not_now(monkeypatch, mono):
    monkeypatch.setattr(aggregate, "_ddb_client", StubPartitions(per_day=1))

    def no_now():
        raise AssertionError("_load_reports must not read _now")

    monkeypatch.setattr(aggregate, "_now", no_now)
    assert len(list(aggregate._load_reports(TABLE_NAME, NOW))) == 8
    assert mono.reads == 1 + 8  # the start, then one check per item


def test_default_monotonic_clock_is_monotonic():
    first = aggregate._monotonic()
    second = aggregate._monotonic()
    assert isinstance(first, float)
    assert second >= first


# --- _published: a qualified group stops being counted -----------------------------


def reference_published(reports, now, min_installs, min_networks):
    """The pre-#49 counting: every report counted, thresholds checked at the end.

    Same validation as ``aggregate._published``, without its logging.
    """
    now_dt = datetime.fromtimestamp(now, timezone.utc)
    installs, nets = {}, {}
    for r in reports:
        if not isinstance(r, dict) or r.get("kind") not in aggregate.KINDS:
            continue
        if any(
            not isinstance(r.get(f), str) or not r.get(f)
            for f in ("kind", "sender", "install_id", "net_hash", "received_at")
        ):
            continue
        try:
            received = datetime.fromisoformat(r["received_at"])
        except ValueError:
            continue
        if received.tzinfo is None:
            received = received.replace(tzinfo=timezone.utc)
        sender = normalize_sender(r["sender"])
        if sender is None or (r["kind"] == "call" and not is_e164(sender)):
            continue
        if received > now_dt or received < now_dt - aggregate.WINDOW:
            continue
        key = (r["kind"], sender)
        installs.setdefault(key, set()).add(r["install_id"])
        nets.setdefault(key, set()).add(r["net_hash"])
    call, sms = set(), set()
    for (kind, sender), ids in installs.items():
        if len(ids) >= min_installs and len(nets[(kind, sender)]) >= min_networks:
            (call if kind == "call" else sms).add(sender)
    return call, sms


def at(seconds_ago):
    return datetime.fromtimestamp(NOW - seconds_ago, timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z"
    )


def random_reports(rng, count):
    senders = [("call", "+97250000000" + str(d)) for d in range(6)] + [
        ("sms", name) for name in ("PartyA", "partya", "PartyB", "Bank")
    ]
    reports = []
    for _ in range(count):
        kind, sender = rng.choice(senders)
        reports.append(
            {
                "kind": kind,
                "sender": sender,
                "install_id": f"i{rng.randrange(6)}",
                "net_hash": f"n{rng.randrange(4)}",
                # Mostly inside the 7-day window, some outside or in the future.
                "received_at": at(rng.randrange(-3600, 8 * 86400)),
            }
        )
    reports.append({"kind": "call"})  # malformed: missing fields
    reports.append("not-a-dict")
    return reports


@pytest.mark.parametrize("seed", range(40))
def test_early_stop_publishes_exactly_what_full_counting_publishes(seed):
    rng = random.Random(seed)
    reports = random_reports(rng, rng.randrange(0, 120))
    min_installs = rng.randrange(1, 5)
    min_networks = rng.randrange(1, 4)
    assert aggregate._published(
        iter(reports), NOW, min_installs, min_networks
    ) == reference_published(reports, NOW, min_installs, min_networks)


def test_a_flood_for_one_sender_publishes_it_once():
    reports = (
        {
            "kind": "call",
            "sender": CALL,
            "install_id": f"i{i}",
            "net_hash": f"n{i % 7}",
            "received_at": at(60),
        }
        for i in range(50_000)
    )
    assert aggregate._published(reports, NOW, 3, 2) == ({CALL}, set())


def test_reports_after_qualifying_are_still_validated_and_logged(caplog):
    good = [
        {
            "kind": "sms",
            "sender": SMS,
            "install_id": f"i{i}",
            "net_hash": f"n{i % 2}",
            "received_at": at(60),
        }
        for i in range(3)
    ]
    late_bad = {**good[0], "received_at": "not-a-time"}
    late_future = {**good[0], "received_at": at(-3600)}
    caplog.set_level(logging.ERROR, logger="sheket.aggregate")

    result = aggregate._published(iter(good + [late_bad, late_future]), NOW, 3, 2)

    assert result == (set(), {SMS_NORMALISED})
    assert [r.getMessage() for r in caplog.records] == [
        "report skipped: unparsable received_at (kind='sms')",
        "report skipped: received_at in the future (kind='sms')",
    ]


def test_kinds_stay_separate_after_the_early_stop():
    reports = [
        {
            "kind": kind,
            "sender": "+972501111111",
            "install_id": f"i{i}",
            "net_hash": f"n{i % 2}",
            "received_at": at(60),
        }
        for kind, n in (("call", 3), ("sms", 2))
        for i in range(n)
    ]
    # The call group qualifies; the sms group (2 installs) does not.
    assert aggregate._published(iter(reports), NOW, 3, 2) == ({"+972501111111"}, set())


# --- the handler: a capped run still publishes ------------------------------------


CALL_NEVER = "+972509998877"


def seed_capped_run(ddb):
    """Two call groups today, one sms group in an old partition, two overrides.

    Partitions are read newest first, so today's six reports are read before
    a cap of 6; the three old ones are not.
    """
    put_group(ddb, "call", CALL, NOW_DT - timedelta(hours=1))
    put_group(ddb, "call", CALL_NEVER, NOW_DT - timedelta(hours=1), start=20)
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(days=6), start=10)
    put_override(ddb, "force_block#sms#SpamOne")
    put_override(ddb, f"never_block#{CALL_NEVER}")


def assert_capped_publication(doc, curated):
    # Both of today's groups qualified before the cap, and never_block removes
    # one; the old group was never read.
    assert doc["call_numbers"] == [CALL]
    # The force_block override is published although its sender was never
    # reported.
    assert doc["sms_senders"] == ["spamone"]
    assert doc["sms_allow_senders"] == sorted(curated["sms_allow_senders"])
    assert [k["text"] for k in doc["sms_keywords"]] == sorted(
        k["text"] for k in curated["sms_keywords"]
    )
    assert doc["version"] == NOW


def test_item_capped_run_publishes_curated_overrides_and_qualified(
    aws, monkeypatch, caplog, capsys, curated, contract_loader
):
    ddb, s3 = aws
    seed_capped_run(ddb)
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 6)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    doc = published(s3)
    aggregate.validate_blocklist(doc, contract_loader("blocklist.schema.json"))
    assert_capped_publication(doc, curated)
    (message,) = capped_messages(caplog)
    assert message.startswith("report read capped: 6 reports, 7 of 8 day partitions")
    assert loaded_messages(caplog) == ["loaded 6 reports from 7 day partitions"]
    (line,) = emf_lines(capsys.readouterr().out)
    assert line["written"] is True
    assert line["AggregateSucceeded"] == 1
    assert line["ReportReadCapped"] == 1


def test_time_capped_run_publishes_curated_overrides_and_qualified(
    aws, monkeypatch, caplog, capsys, curated
):
    ddb, s3 = aws
    seed_capped_run(ddb)
    # The start and the first six item checks are on time; then the budget
    # is spent, as if DynamoDB had slowed down.
    ticks = iter([0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    monkeypatch.setattr(
        aggregate, "_monotonic", lambda: next(ticks, float(aggregate.READ_TIME_BUDGET))
    )
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    assert_capped_publication(published(s3), curated)
    (message,) = capped_messages(caplog)
    assert message.startswith("report read capped: 6 reports, 7 of 8 day partitions")
    (line,) = emf_lines(capsys.readouterr().out)
    assert line["AggregateSucceeded"] == 1
    assert line["ReportReadCapped"] == 1


CALL_OLD = "+972507776655"


def test_capped_run_publishes_a_sender_reported_only_today(
    aws, monkeypatch, caplog, capsys
):
    # A new spam sender appears today while older evidence fills the cap: the
    # newest-first read counts today's reports before the old ones.
    ddb, s3 = aws
    put_group(ddb, "call", CALL, NOW_DT - timedelta(hours=1))
    put_group(ddb, "call", CALL_OLD, NOW_DT - timedelta(days=3), start=10)
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(days=6), start=20)
    monkeypatch.setattr(aggregate, "MAX_REPORTS_PER_RUN", 3)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    doc = published(s3)
    assert doc["call_numbers"] == [CALL]
    assert SMS_NORMALISED not in doc["sms_senders"]
    (message,) = capped_messages(caplog)
    assert message.startswith("report read capped: 3 reports, 4 of 8 day partitions")
    (line,) = emf_lines(capsys.readouterr().out)
    assert line["AggregateSucceeded"] == 1
    assert line["ReportReadCapped"] == 1


def test_uncapped_run_publishes_both_groups(aws, caplog, capsys, curated):
    ddb, s3 = aws
    seed_capped_run(ddb)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")
    run()
    doc = published(s3)
    assert doc["call_numbers"] == [CALL]
    assert doc["sms_senders"] == [SMS_NORMALISED, "spamone"]
    assert capped_messages(caplog) == []
    (line,) = emf_lines(capsys.readouterr().out)
    assert line["ReportReadCapped"] == 0


# --- the synthetic ~1M-report flood and the Lambda sizing --------------------------


def aggregate_lambda_setting(name):
    """Read ``name`` from ``aws_lambda_function.aggregate`` in infra/lambda.tf."""
    text = LAMBDA_TF.read_text(encoding="utf-8")
    block = re.search(
        r'^resource "aws_lambda_function" "aggregate" \{\n(.*?)^\}',
        text,
        re.MULTILINE | re.DOTALL,
    )
    assert block, "aws_lambda_function.aggregate not found in infra/lambda.tf"
    (value,) = re.findall(rf"^\s*{name}\s*=\s*(\d+)\s*$", block.group(1), re.MULTILINE)
    return int(value)


@pytest.fixture(scope="module")
def flood():
    """Run every flood shape in its own fresh interpreter, in parallel.

    Separate processes keep each shape's peak RSS its own; running them
    concurrently keeps the suite's wall time to the slowest shape.
    """
    script = TESTS_DIR / "flood_run.py"
    procs = {
        shape: subprocess.Popen(
            [sys.executable, str(script), shape],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for shape in ("distinct_over_cap", "few_senders")
    }
    results = {}
    for shape, proc in procs.items():
        out, err = proc.communicate(timeout=600)
        assert proc.returncode == 0, err[-2000:]
        lines = out.strip().splitlines()
        results[shape] = {
            **json.loads(lines[-1]),
            "stdout": "\n".join(lines[:-1]),
            "stderr": err,
        }
    return results


def assert_flood_publication(result, call_numbers):
    curated = load_contract("curated.json")
    doc = result["doc"]
    assert doc["call_numbers"] == call_numbers
    assert doc["sms_allow_senders"] == sorted(curated["sms_allow_senders"])
    assert len(doc["sms_keywords"]) == len(curated["sms_keywords"])
    # Exactly the cap was read and the run still succeeded with a heartbeat.
    assert "report read capped: 1000000 reports" in result["stderr"]
    assert "loaded 1000000 reports from" in result["stderr"]
    (line,) = emf_lines(result["stdout"])
    assert line["AggregateSucceeded"] == 1
    assert line["ReportReadCapped"] == 1


def test_flood_of_distinct_senders_is_capped_and_overrides_publish(flood):
    result = flood["distinct_over_cap"]
    assert result["generated"] == 1_200_000
    # Every report is a different sender, so none qualifies; the force_block
    # override is still published.
    assert_flood_publication(result, ["+972521112233"])


def test_flood_of_few_senders_publishes_them_with_little_memory(flood):
    result = flood["few_senders"]
    expected = sorted(
        {f"+97250{n:07d}" for n in range(100)} - {"+972500000007"} | {"+972521112233"}
    )
    assert_flood_publication(result, expected)
    # Qualified senders are no longer counted: the flood costs a few MB over
    # the interpreter and imports (~55 MB), not one set entry per report.
    assert result["peak_rss_mb"] < 100, result


def test_lambda_memory_and_timeout_fit_the_measured_flood(flood):
    memory_size = aggregate_lambda_setting("memory_size")
    timeout = aggregate_lambda_setting("timeout")
    peak = max(r["peak_rss_mb"] for r in flood.values())
    slowest = max(r["run_seconds"] for r in flood.values())

    # Sized at 1.5x the peak on the measuring host (884 MB -> 1536 MB); at
    # least 25% headroom must remain on any host that runs this test.
    assert peak * 1.25 <= memory_size, (peak, memory_size)
    # The read stops at READ_TIME_BUDGET; the rest of the run (overrides,
    # S3, validate, put) needs a margin, and the whole CPU-bound flood must
    # fit twice over.
    assert timeout >= aggregate.READ_TIME_BUDGET + 60, timeout
    assert timeout >= 2 * slowest, (slowest, timeout)
    # Lambda's own maximum, and below the 15-minute schedule.
    assert timeout < 900
