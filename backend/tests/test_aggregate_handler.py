"""Tests for ``sheket.aggregate.handler``, the scheduled aggregate Lambda (#6).

DynamoDB and S3 are moto's in-memory implementations (the ``ddb_table`` and
``s3_bucket`` fixtures), so the day-partition queries, the projection, the
pagination and the S3 object metadata are exercised for real. Reports are
written in the report handler's own item shape: either through
``report.handler`` itself or through ``report._report_item``. The contract
files are read from the repository's ``contract/`` and never written.

The acceptance criteria of #6 are marked ``AC-n`` in the section headers.
"""

import copy
import json
import logging
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from botocore.exceptions import ClientError
from conftest import BUCKET_NAME, TABLE_NAME, load_contract
from jsonschema import ValidationError

from sheket import aggregate, report
from sheket.aggregate import (
    BLOCKLIST_KEY,
    FORCED_REFRESH,
    WINDOW,
    build_blocklist,
    serialize_blocklist,
    validate_blocklist,
)

# 2026-10-06T12:00:00Z, a whole second like every value of ``aggregate._now``.
NOW_DT = datetime(2026, 10, 6, 12, 0, 0, tzinfo=timezone.utc)
NOW = int(NOW_DT.timestamp())

# Captured at import, before aggregate_env points it at the repository copy.
PACKAGED_CONTRACT_DIR = aggregate.CONTRACT_DIR

MIN_INSTALLS = 3
MIN_NETWORKS = 2

CALL = "+972501234567"
SMS = "ExampleParty"
SMS_NORMALISED = "exampleparty"

# Two distinct /24 networks, so two distinct net_hash values.
NET_A = "net-a"
NET_B = "net-b"


def install_id(n):
    """Return a distinct, valid lowercase install UUID for index ``n``."""
    return f"00000000-0000-4000-8000-{n:012d}"


# --- fixtures and helpers -----------------------------------------------------


@pytest.fixture(autouse=True)
def aggregate_env(monkeypatch, contract_dir):
    """Configure the handler as Terraform would (spec 6.3 thresholds).

    ``CONTRACT_DIR`` points at the repository's ``contract/``: the packaged
    ``sheket/contract/`` copy exists only in the Lambda zip (#7).
    """
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("BUCKET_NAME", BUCKET_NAME)
    monkeypatch.setenv("MIN_INSTALLS", str(MIN_INSTALLS))
    monkeypatch.setenv("MIN_NETWORKS", str(MIN_NETWORKS))
    monkeypatch.setattr(aggregate, "CONTRACT_DIR", contract_dir)


class Clock:
    """``aggregate._now`` frozen at ``now``; tests move it by assignment."""

    def __init__(self, now):
        self.now = now


@pytest.fixture
def clock(monkeypatch):
    c = Clock(NOW)
    monkeypatch.setattr(aggregate, "_now", lambda: c.now)
    return c


@pytest.fixture
def aws(ddb_table, s3_bucket, clock):
    """Both moto resources plus the frozen clock: ``(dynamodb, s3)``."""
    return ddb_table, s3_bucket


@pytest.fixture
def schema():
    return load_contract("blocklist.schema.json")


def put_report(ddb, kind, sender, n, net, at, text=None):
    """Store one report in ``report._report_item``'s exact item shape."""
    fields = {
        "install_id": install_id(n),
        "platform": "android",
        "kind": kind,
        "sender": sender,
        "app_version": "1.0.0",
        "text": text,
    }
    ddb.put_item(TableName=TABLE_NAME, Item=report._report_item(fields, net, at))


def put_group(ddb, kind, sender, at, installs=MIN_INSTALLS, start=0):
    """Store ``installs`` reports from distinct installs over two networks."""
    for i in range(installs):
        put_report(ddb, kind, sender, start + i, (NET_A, NET_B)[i % 2], at)


def put_override(ddb, sk):
    ddb.put_item(TableName=TABLE_NAME, Item={"pk": {"S": "OVERRIDE"}, "sk": {"S": sk}})


def put_previous(s3, body):
    """Store ``body`` (a dict, str or bytes) as the published blocklist."""
    if isinstance(body, dict):
        body = serialize_blocklist(body)
    if isinstance(body, str):
        body = body.encode("utf-8")
    s3.put_object(Bucket=BUCKET_NAME, Key=BLOCKLIST_KEY, Body=body)


def published_bytes(s3):
    return s3.get_object(Bucket=BUCKET_NAME, Key=BLOCKLIST_KEY)["Body"].read()


def published(s3):
    return json.loads(published_bytes(s3).decode("utf-8"))


def object_count(s3):
    return s3.list_objects_v2(Bucket=BUCKET_NAME).get("KeyCount", 0)


def run():
    """Invoke the handler with an EventBridge-like event and no context."""
    return aggregate.handler({"source": "aws.scheduler"}, None)


def emf_lines(out):
    """Return the parsed JSON lines of stdout that carry the EMF envelope."""
    lines = []
    for line in out.splitlines():
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, dict) and "_aws" in parsed:
            lines.append(parsed)
    return lines


class RecordingDynamoDB:
    """Wraps the moto DynamoDB client; records every ``query`` call.

    ``limit`` adds ``Limit`` to each query so moto returns several pages and
    real ``LastEvaluatedKey`` pagination is exercised.
    """

    def __init__(self, client, limit=None):
        self._client = client
        self._limit = limit
        self.queries = []

    def query(self, **kwargs):
        self.queries.append(copy.deepcopy(kwargs))
        if self._limit is not None:
            kwargs = {**kwargs, "Limit": self._limit}
        return self._client.query(**kwargs)


@pytest.fixture
def recorder(aws, monkeypatch):
    ddb, _ = aws
    rec = RecordingDynamoDB(ddb)
    monkeypatch.setattr(aggregate, "_ddb_client", rec)
    return rec


# --- AC-1: reports in the report handler's item shape -> published list -------


def test_reports_posted_through_the_report_handler_are_published(
    aws, monkeypatch, schema
):
    _, s3 = aws
    monkeypatch.setattr(report, "_now", lambda: NOW_DT - timedelta(hours=1))
    ips = ["203.0.113.10", "198.51.100.20", "203.0.113.30"]
    for i, ip in enumerate(ips):
        for kind, sender, text in (("call", CALL, None), ("sms", SMS, "Vote!")):
            body = {
                "install_id": install_id(i),
                "platform": "android",
                "kind": kind,
                "sender": sender,
                "app_version": "1.0.0",
            }
            if text is not None:
                body["text"] = text
            event = {
                "version": "2.0",
                "rawPath": "/v1/reports",
                "rawQueryString": "",
                "headers": {"content-type": "application/json"},
                "requestContext": {
                    "http": {
                        "method": "POST",
                        "path": "/v1/reports",
                        "protocol": "HTTP/1.1",
                        "sourceIp": ip,
                        "userAgent": "test",
                    }
                },
                "isBase64Encoded": False,
                "body": json.dumps(body),
            }
            assert report.handler(event, None)["statusCode"] == 202

    run()

    doc = published(s3)
    validate_blocklist(doc, schema)
    assert doc["call_numbers"] == [CALL]
    assert doc["sms_senders"] == [SMS_NORMALISED]
    assert doc["version"] == NOW


def test_published_document_matches_a_fresh_build_from_the_same_inputs(aws, curated):
    ddb, s3 = aws
    put_group(ddb, "call", CALL, NOW_DT - timedelta(days=1))
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(days=2), start=10)
    put_override(ddb, "force_block#sms#SpamCo")

    run()

    reports = [
        {
            "kind": "call",
            "sender": CALL,
            "install_id": install_id(i),
            "net_hash": (NET_A, NET_B)[i % 2],
            "received_at": "2026-10-05T12:00:00.000Z",
        }
        for i in range(MIN_INSTALLS)
    ] + [
        {
            "kind": "sms",
            "sender": SMS,
            "install_id": install_id(10 + i),
            "net_hash": (NET_A, NET_B)[i % 2],
            "received_at": "2026-10-04T12:00:00.000Z",
        }
        for i in range(MIN_INSTALLS)
    ]
    expected = build_blocklist(
        curated,
        reports,
        [{"sk": "force_block#sms#SpamCo"}],
        NOW,
        0,
        MIN_INSTALLS,
        MIN_NETWORKS,
    )
    assert published_bytes(s3) == serialize_blocklist(expected).encode("utf-8")


def test_curated_lists_are_carried_into_the_published_document(aws, curated):
    _, s3 = aws
    run()
    doc = published(s3)
    assert doc["schema"] == 1
    assert doc["sms_allow_senders"] == sorted(curated["sms_allow_senders"])
    assert [k["text"] for k in doc["sms_keywords"]] == sorted(
        k["text"] for k in curated["sms_keywords"]
    )


def test_group_below_the_install_threshold_is_not_published(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(hours=1), installs=2)
    run()
    assert published(s3)["sms_senders"] == []


def test_group_on_one_network_is_not_published(aws):
    ddb, s3 = aws
    for i in range(MIN_INSTALLS):
        put_report(ddb, "sms", SMS, i, NET_A, NOW_DT - timedelta(hours=1))
    run()
    assert published(s3)["sms_senders"] == []


def test_force_block_overrides_are_published(aws):
    ddb, s3 = aws
    put_override(ddb, "force_block#call#+972521112233")
    put_override(ddb, "force_block#sms#SpamCo")
    run()
    doc = published(s3)
    assert doc["call_numbers"] == ["+972521112233"]
    assert doc["sms_senders"] == ["spamco"]


def test_never_block_override_removes_a_published_sender(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(hours=1))
    put_group(ddb, "call", CALL, NOW_DT - timedelta(hours=1), start=10)
    put_override(ddb, f"never_block#{SMS}")
    run()
    doc = published(s3)
    assert doc["sms_senders"] == []
    assert doc["call_numbers"] == [CALL]


def test_malformed_override_is_skipped_and_the_run_succeeds(aws):
    ddb, s3 = aws
    put_override(ddb, "force_block#fax#+972521112233")
    put_override(ddb, "something_else")
    put_override(ddb, "force_block#sms#SpamCo")
    run()
    assert published(s3)["sms_senders"] == ["spamco"]


def test_counter_items_in_other_partitions_are_not_read_as_reports(aws):
    ddb, s3 = aws
    day = NOW_DT.strftime("%Y-%m-%d")
    for i in range(MIN_INSTALLS):
        ddb.put_item(
            TableName=TABLE_NAME,
            Item={
                "pk": {"S": f"RL#I#{install_id(i)}#{day}"},
                "sk": {"S": "-"},
                "n": {"N": "1"},
            },
        )
    run()
    doc = published(s3)
    assert doc["call_numbers"] == [] and doc["sms_senders"] == []


# --- AC-1: the 7-day window and the day partitions -----------------------------


def test_report_exactly_at_the_cutoff_is_included(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - WINDOW)
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]


def test_report_one_millisecond_before_the_cutoff_is_excluded(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - WINDOW - timedelta(milliseconds=1))
    run()
    assert published(s3)["sms_senders"] == []


def test_one_old_report_cannot_complete_a_group(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(days=1), installs=2)
    put_report(ddb, "sms", SMS, 2, NET_A, NOW_DT - WINDOW - timedelta(seconds=1))
    run()
    assert published(s3)["sms_senders"] == []


def test_report_exactly_at_now_is_included(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT)
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]


def test_report_in_a_future_partition_is_not_read(aws, recorder):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT + timedelta(days=1))
    run()
    assert published(s3)["sms_senders"] == []
    tomorrow = (NOW_DT + timedelta(days=1)).strftime("%Y-%m-%d")
    assert all(
        q["ExpressionAttributeValues"][":pk"]["S"] != f"R#{tomorrow}"
        for q in recorder.queries
        if ":pk" in q["ExpressionAttributeValues"]
    )


def test_reports_spread_over_every_day_partition_all_count(aws, monkeypatch):
    ddb, s3 = aws
    # One install per partition, 0..7 days back (the oldest exactly at the
    # cutoff); a publication at MIN_INSTALLS=8 needs every one of them.
    for d in range(8):
        put_report(
            ddb, "sms", SMS, d, (NET_A, NET_B)[d % 2], NOW_DT - timedelta(days=d)
        )
    monkeypatch.setenv("MIN_INSTALLS", "8")
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]


def test_eight_day_partitions_are_queried_with_the_projection(recorder):
    run()
    report_queries = [
        q for q in recorder.queries if ":pk" in q["ExpressionAttributeValues"]
    ]
    days = [q["ExpressionAttributeValues"][":pk"]["S"] for q in report_queries]
    assert days == [
        f"R#{(NOW_DT - timedelta(days=d)).strftime('%Y-%m-%d')}"
        for d in range(7, -1, -1)
    ]
    for q in report_queries:
        assert q["TableName"] == TABLE_NAME
        assert q["ProjectionExpression"] == (
            "kind, sender, install_id, net_hash, received_at"
        )
    # Only the oldest partition is narrowed by the cutoff.
    assert report_queries[0]["KeyConditionExpression"] == "pk = :pk AND sk >= :cut"
    assert report_queries[0]["ExpressionAttributeValues"][":cut"] == {
        "S": "2026-09-29T12:00:00.000Z"
    }
    for q in report_queries[1:]:
        assert q["KeyConditionExpression"] == "pk = :pk"
        assert ":cut" not in q["ExpressionAttributeValues"]


@pytest.mark.parametrize(
    "now_dt",
    [
        datetime(2026, 10, 6, 0, 0, 0, tzinfo=timezone.utc),
        datetime(2026, 10, 6, 23, 59, 59, tzinfo=timezone.utc),
        datetime(2026, 12, 31, 23, 59, 59, tzinfo=timezone.utc),
        datetime(2028, 3, 1, 0, 0, 1, tzinfo=timezone.utc),
    ],
    ids=["midnight", "end-of-day", "year-end", "after-leap-day"],
)
def test_always_eight_partitions_at_day_boundaries(recorder, clock, now_dt):
    clock.now = int(now_dt.timestamp())
    run()
    days = [
        q["ExpressionAttributeValues"][":pk"]["S"]
        for q in recorder.queries
        if ":pk" in q["ExpressionAttributeValues"]
    ]
    assert len(days) == 8
    assert days[0] == f"R#{(now_dt - WINDOW).strftime('%Y-%m-%d')}"
    assert days[-1] == f"R#{now_dt.strftime('%Y-%m-%d')}"


def test_overrides_are_queried_from_the_override_partition(recorder):
    run()
    override_queries = [
        q for q in recorder.queries if ":o" in q["ExpressionAttributeValues"]
    ]
    assert override_queries == [
        {
            "TableName": TABLE_NAME,
            "KeyConditionExpression": "pk = :o",
            "ExpressionAttributeValues": {":o": {"S": "OVERRIDE"}},
            "ProjectionExpression": "sk",
        }
    ]
    assert len(recorder.queries) == 9


def test_projection_drops_every_other_report_attribute(aws):
    ddb, _ = aws
    put_report(ddb, "sms", SMS, 0, NET_A, NOW_DT - timedelta(hours=1), text="Hi")
    loaded = aggregate._load_reports(TABLE_NAME, NOW)
    assert loaded == [
        {
            "kind": "sms",
            "sender": SMS,
            "install_id": install_id(0),
            "net_hash": NET_A,
            "received_at": "2026-10-06T11:00:00.000Z",
        }
    ]


def test_every_page_of_reports_and_overrides_is_read(aws, monkeypatch):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(hours=1), installs=5)
    put_override(ddb, "force_block#sms#SpamOne")
    put_override(ddb, "force_block#sms#SpamTwo")
    put_override(ddb, "force_block#sms#SpamThree")
    rec = RecordingDynamoDB(ddb, limit=1)
    monkeypatch.setattr(aggregate, "_ddb_client", rec)
    monkeypatch.setenv("MIN_INSTALLS", "5")

    run()

    assert published(s3)["sms_senders"] == sorted(
        [SMS_NORMALISED, "spamone", "spamtwo", "spamthree"]
    )
    assert any("ExclusiveStartKey" in q for q in rec.queries)


# --- _query_all: pagination and attribute conversion (stub client) -------------


class StubPages:
    def __init__(self, pages):
        self.pages = list(pages)
        self.calls = []

    def query(self, **kwargs):
        self.calls.append(dict(kwargs))
        return self.pages.pop(0)


def test_query_all_follows_last_evaluated_key_without_mutating_kwargs(
    monkeypatch,
):
    stub = StubPages(
        [
            {"Items": [{"sk": {"S": "a"}}], "LastEvaluatedKey": {"k": {"S": "1"}}},
            {"Items": [], "LastEvaluatedKey": {"k": {"S": "2"}}},
            {"Items": [{"sk": {"S": "b"}}]},
        ]
    )
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    kwargs = {"TableName": "t", "KeyConditionExpression": "pk = :o"}

    assert aggregate._query_all(**kwargs) == [{"sk": "a"}, {"sk": "b"}]
    assert kwargs == {"TableName": "t", "KeyConditionExpression": "pk = :o"}
    assert [c.get("ExclusiveStartKey") for c in stub.calls] == [
        None,
        {"k": {"S": "1"}},
        {"k": {"S": "2"}},
    ]


def test_query_all_keeps_only_string_attributes(monkeypatch):
    stub = StubPages(
        [
            {
                "Items": [
                    {
                        "kind": {"S": "sms"},
                        "expires_at": {"N": "1"},
                        "sender": {"NULL": True},
                        "odd": "not-an-attribute-value",
                    }
                ]
            }
        ]
    )
    monkeypatch.setattr(aggregate, "_ddb_client", stub)
    assert aggregate._query_all(TableName="t") == [{"kind": "sms"}]


def test_report_with_a_non_string_attribute_is_skipped_not_raised(aws):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(hours=1))
    ddb.put_item(
        TableName=TABLE_NAME,
        Item={
            "pk": {"S": f"R#{NOW_DT.strftime('%Y-%m-%d')}"},
            "sk": {"S": "2026-10-06T11:30:00.000Z#bad"},
            "kind": {"S": "sms"},
            "sender": {"N": "5"},
            "install_id": {"S": install_id(99)},
            "net_hash": {"S": NET_A},
            "received_at": {"S": "2026-10-06T11:30:00.000Z"},
        },
    )
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]


# --- AC-2: a document that fails validation is never written -------------------


@pytest.fixture
def invalid_contract_dir(tmp_path, contract_dir, monkeypatch):
    """A copy of contract/ whose curated call number breaks the schema."""
    shutil.copy(contract_dir / "blocklist.schema.json", tmp_path)
    curated = load_contract("curated.json")
    curated["call_numbers"] = ["12"]
    (tmp_path / "curated.json").write_text(json.dumps(curated), encoding="utf-8")
    monkeypatch.setattr(aggregate, "CONTRACT_DIR", tmp_path)
    return tmp_path


def test_invalid_document_raises_and_keeps_the_previous_object(
    aws, curated, invalid_contract_dir, capsys
):
    ddb, s3 = aws
    previous = build_blocklist(curated, [], [], NOW - 3600, 0, 3, 2)
    put_previous(s3, previous)
    before = published_bytes(s3)
    put_override(ddb, "force_block#sms#SpamCo")  # content would change

    with pytest.raises(ValidationError):
        run()

    assert published_bytes(s3) == before
    assert emf_lines(capsys.readouterr().out) == []


def test_invalid_document_on_the_first_run_writes_nothing(
    aws, invalid_contract_dir, capsys
):
    _, s3 = aws
    with pytest.raises(ValidationError):
        run()
    assert object_count(s3) == 0
    assert emf_lines(capsys.readouterr().out) == []


def test_validation_runs_before_put_object(aws, monkeypatch):
    order = []
    real_validate = aggregate.validate_blocklist
    real_s3 = aggregate._s3()

    class S3Spy:
        def get_object(self, **kw):
            return real_s3.get_object(**kw)

        def put_object(self, **kw):
            order.append("put")
            return real_s3.put_object(**kw)

    def validate(doc, schema):
        order.append("validate")
        return real_validate(doc, schema)

    monkeypatch.setattr(aggregate, "validate_blocklist", validate)
    monkeypatch.setattr(aggregate, "_s3_client", S3Spy())
    run()
    assert order == ["validate", "put"]


def test_s3_read_error_other_than_no_such_key_propagates(aws, monkeypatch, capsys):
    class DeniedS3:
        puts = 0

        def get_object(self, **kw):
            raise ClientError(
                {"Error": {"Code": "AccessDenied", "Message": "denied"}}, "GetObject"
            )

        def put_object(self, **kw):  # pragma: no cover - must not be called
            DeniedS3.puts += 1

    monkeypatch.setattr(aggregate, "_s3_client", DeniedS3())
    with pytest.raises(ClientError) as exc:
        run()
    assert exc.value.response["Error"]["Code"] == "AccessDenied"
    assert DeniedS3.puts == 0
    assert emf_lines(capsys.readouterr().out) == []


def test_dynamodb_error_propagates_and_writes_nothing(aws, monkeypatch, capsys):
    _, s3 = aws
    monkeypatch.setenv("TABLE_NAME", "no-such-table")
    with pytest.raises(ClientError):
        run()
    assert object_count(s3) == 0
    assert emf_lines(capsys.readouterr().out) == []


def test_missing_contract_file_raises_before_any_aws_call(tmp_path, monkeypatch):
    # No moto fixture: any AWS use would hit _NoAwsClient and fail differently.
    monkeypatch.setattr(aggregate, "CONTRACT_DIR", tmp_path)
    with pytest.raises(FileNotFoundError):
        run()


def test_contract_dir_defaults_to_the_packaged_copy_next_to_the_module():
    assert PACKAGED_CONTRACT_DIR == Path(aggregate.__file__).parent / "contract"


def test_contract_files_are_loaded_from_contract_dir(contract_dir):
    curated, schema = aggregate._load_contract()
    assert curated == load_contract("curated.json")
    assert schema == load_contract("blocklist.schema.json")


# --- AC-3: first run and unusable previous objects -----------------------------


def test_first_run_writes_with_previous_version_zero(aws, monkeypatch, caplog):
    _, s3 = aws
    seen = {}
    real_build = aggregate.build_blocklist

    def build(*args, **kwargs):
        seen["previous_version"] = args[4]
        return real_build(*args, **kwargs)

    monkeypatch.setattr(aggregate, "build_blocklist", build)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    assert seen["previous_version"] == 0
    doc = published(s3)
    assert doc["version"] == NOW
    assert doc["generated_at"] == "2026-10-06T12:00:00Z"
    assert "first run" in caplog.text


@pytest.mark.parametrize(
    "body",
    [
        b"\xff\xfe not utf-8",
        b"{ not json",
        b"",
        b"[1, 2, 3]",
        b'"a string"',
        b'{"schema": 1}',
        b'{"version": "1791149668"}',
        b'{"version": true}',
        b'{"version": -1}',
        b'{"version": 1.5}',
    ],
    ids=[
        "not-utf8",
        "not-json",
        "empty",
        "array",
        "string",
        "no-version",
        "string-version",
        "bool-version",
        "negative-version",
        "float-version",
    ],
)
def test_unusable_previous_object_is_replaced(aws, caplog, schema, body):
    _, s3 = aws
    put_previous(s3, body)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    doc = published(s3)
    validate_blocklist(doc, schema)
    assert doc["version"] == NOW
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert errors and "previous blocklist" in errors[0].getMessage()


def test_unusable_previous_object_with_equal_content_is_still_replaced(aws, curated):
    _, s3 = aws
    previous = build_blocklist(curated, [], [], NOW - 60, 0, 3, 2)
    previous["version"] = "not-an-int"
    put_previous(s3, previous)
    run()
    assert published(s3)["version"] == NOW


def test_unusable_previous_object_content_is_not_logged(aws, caplog):
    _, s3 = aws
    put_previous(s3, b'["SECRET-SENDER-VALUE"]')
    caplog.set_level(logging.DEBUG, logger="sheket.aggregate")
    run()
    assert "SECRET-SENDER-VALUE" not in caplog.text


def test_version_stays_increasing_when_the_previous_is_ahead_of_the_clock(aws, curated):
    ddb, s3 = aws
    previous = build_blocklist(curated, [], [], NOW + 500, 0, 3, 2)
    put_previous(s3, previous)
    put_override(ddb, "force_block#sms#SpamCo")
    run()
    assert published(s3)["version"] == NOW + 501


# #50 (1): a whole-valued float version is valid under the schema and must keep
# the version increasing instead of being treated as absent.


def test_whole_valued_float_previous_version_keeps_the_version_increasing(
    aws, caplog, schema
):
    _, s3 = aws
    put_previous(s3, b'{"version": 9999999999.0}')
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    doc = published(s3)
    validate_blocklist(doc, schema)
    assert doc["version"] == 9999999999 + 1
    assert type(doc["version"]) is int
    assert b'"version": 10000000000,' in published_bytes(s3)  # an int, no ".0"
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]


def test_whole_valued_float_previous_version_is_read_as_an_int(aws, curated, caplog):
    _, s3 = aws
    previous = build_blocklist(curated, [], [], NOW - 60, 0, 3, 2)
    body = serialize_blocklist(previous).replace(
        f'"version": {NOW - 60},', f'"version": {NOW - 60}.0,'
    )
    assert f'"version": {NOW - 60}.0,' in body
    put_previous(s3, body)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    # Unchanged content inside the refresh window: not rewritten, and the
    # previous version is logged as the integer it is.
    assert published_bytes(s3) == body.encode("utf-8")
    assert f"blocklist unchanged: version={NOW - 60} " in caplog.text


@pytest.mark.parametrize(
    "raw", [b"NaN", b"Infinity", b"-Infinity", b"-1.0", b"0.5"], ids=bytes.decode
)
def test_non_integral_or_negative_float_previous_version_is_unusable(aws, caplog, raw):
    _, s3 = aws
    put_previous(s3, b'{"version": ' + raw + b"}")
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    assert published(s3)["version"] == NOW
    errors = [r.getMessage() for r in caplog.records if r.levelno >= logging.ERROR]
    assert errors == ["previous blocklist version invalid (type=float); using 0"]


def test_load_previous_returns_an_int_for_a_whole_valued_float(aws):
    _, s3 = aws
    put_previous(s3, b'{"version": 1791201600.0}')
    doc, version = aggregate._load_previous(BUCKET_NAME)
    assert version == 1791201600
    assert type(version) is int
    assert doc == {"version": 1791201600.0}


# #50 (2): a previous version too large for `datetime` must not fail every run.


def test_max_version_is_the_last_one_whose_successor_is_a_date():
    assert aggregate.MAX_VERSION == 253402300798
    assert aggregate._generated_at(aggregate.MAX_VERSION + 1) == "9999-12-31T23:59:59Z"
    with pytest.raises(ValueError):
        aggregate._generated_at(aggregate.MAX_VERSION + 2)


@pytest.mark.parametrize(
    "raw",
    [b"253402300799", b"253402300800", b"100000000000000000000", b"1e300"],
    ids=bytes.decode,
)
def test_out_of_range_previous_version_is_logged_and_replaced(aws, caplog, schema, raw):
    _, s3 = aws
    put_previous(s3, b'{"version": ' + raw + b"}")
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()  # does not raise

    doc = published(s3)
    validate_blocklist(doc, schema)
    assert doc["version"] == NOW
    assert doc["generated_at"] == "2026-10-06T12:00:00Z"
    errors = [r.getMessage() for r in caplog.records if r.levelno >= logging.ERROR]
    assert errors == [
        "previous blocklist version out of range (above 253402300798); using 0"
    ]


def test_out_of_range_previous_version_recovers_on_the_next_run(aws, clock):
    ddb, s3 = aws
    put_previous(s3, b'{"version": 253402300800}')
    run()
    assert published(s3)["version"] == NOW

    clock.now = NOW + 60
    put_override(ddb, "force_block#sms#SpamCo")
    run()
    assert published(s3)["version"] == NOW + 60


def test_previous_version_at_max_version_is_still_accepted(aws, caplog, schema):
    _, s3 = aws
    put_previous(s3, b'{"version": 253402300798}')
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    doc = published(s3)
    validate_blocklist(doc, schema)
    assert doc["version"] == 253402300799
    assert doc["generated_at"] == "9999-12-31T23:59:59Z"
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]


# --- AC-4: conditional write ---------------------------------------------------


def test_unchanged_content_inside_the_refresh_window_is_not_written(aws, clock, capsys):
    _, s3 = aws
    run()
    first = published_bytes(s3)
    etag = s3.head_object(Bucket=BUCKET_NAME, Key=BLOCKLIST_KEY)["ETag"]

    clock.now = NOW + 3600
    capsys.readouterr()
    run()

    assert published_bytes(s3) == first
    assert s3.head_object(Bucket=BUCKET_NAME, Key=BLOCKLIST_KEY)["ETag"] == etag
    (line,) = emf_lines(capsys.readouterr().out)
    assert line["written"] is False


def test_unchanged_run_logs_the_previous_version(aws, clock, caplog):
    run()
    clock.now = NOW + 60
    caplog.set_level(logging.INFO, logger="sheket.aggregate")
    run()
    assert f"blocklist unchanged: version={NOW} " in caplog.text


def test_changed_content_is_written_with_a_higher_version(aws, clock):
    ddb, s3 = aws
    run()
    first = published(s3)

    clock.now = NOW + 60
    put_override(ddb, "force_block#sms#SpamCo")
    run()

    second = published(s3)
    assert second["sms_senders"] == ["spamco"]
    assert second["version"] == NOW + 60 > first["version"]


def test_changed_content_with_a_stalled_clock_still_increases_version(aws, clock):
    ddb, s3 = aws
    run()
    put_override(ddb, "force_block#sms#SpamCo")
    run()  # same second
    assert published(s3)["version"] == NOW + 1


def test_newly_published_group_triggers_a_write(aws, clock):
    ddb, s3 = aws
    run()
    put_group(ddb, "call", CALL, NOW_DT)
    clock.now = NOW + 120
    run()
    assert published(s3)["call_numbers"] == [CALL]


def test_sender_ageing_out_of_the_window_triggers_a_write(aws, clock):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - WINDOW + timedelta(minutes=30))
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]

    clock.now = NOW + 3600
    run()
    doc = published(s3)
    assert doc["sms_senders"] == []
    assert doc["version"] == NOW + 3600


# Provisional 6-hour forced refresh (open owner Decision 5). These tests go
# with FORCED_REFRESH if the owner drops it.


def test_forced_refresh_is_six_hours():
    assert FORCED_REFRESH == timedelta(hours=6)


def test_unchanged_content_is_rewritten_once_the_refresh_is_due(aws, clock):
    _, s3 = aws
    run()
    clock.now = NOW + int(FORCED_REFRESH.total_seconds())
    run()
    assert published(s3)["version"] == NOW + 6 * 3600


def test_unchanged_content_one_second_before_the_refresh_is_not_written(aws, clock):
    _, s3 = aws
    run()
    clock.now = NOW + int(FORCED_REFRESH.total_seconds()) - 1
    run()
    assert published(s3)["version"] == NOW


@pytest.mark.parametrize("generated_at", [None, 12345, "yesterday", ""], ids=repr)
def test_unreadable_previous_generated_at_forces_a_write(aws, curated, generated_at):
    _, s3 = aws
    previous = build_blocklist(curated, [], [], NOW - 60, 0, 3, 2)
    if generated_at is None:
        del previous["generated_at"]
    else:
        previous["generated_at"] = generated_at
    put_previous(s3, previous)
    run()
    assert published(s3)["version"] == NOW


# #50 (3): a future generated_at must not stop the forced refresh.


@pytest.mark.parametrize("ahead", [1, 3600, 365 * 86400])
def test_future_previous_generated_at_forces_a_write(aws, curated, caplog, ahead):
    _, s3 = aws
    previous = build_blocklist(curated, [], [], NOW - 60, 0, 3, 2)
    previous["generated_at"] = aggregate._generated_at(NOW + ahead)
    put_previous(s3, previous)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    doc = published(s3)
    assert doc["version"] == NOW
    assert doc["generated_at"] == "2026-10-06T12:00:00Z"
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert [r.getMessage() for r in warnings] == [
        "previous generated_at is in the future; forcing refresh"
    ]


def test_previous_ahead_of_the_clock_with_unchanged_content_is_refreshed(aws, curated):
    # Both version and generated_at in the future, content unchanged: the
    # refresh still happens and the version keeps increasing.
    _, s3 = aws
    put_previous(s3, build_blocklist(curated, [], [], NOW + 500, 0, 3, 2))
    run()
    doc = published(s3)
    assert doc["version"] == NOW + 501
    assert doc["generated_at"] == aggregate._generated_at(NOW + 501)


def test_generated_at_equal_to_now_is_not_a_refresh(aws, curated, caplog):
    _, s3 = aws
    previous = build_blocklist(curated, [], [], NOW - 60, 0, 3, 2)
    previous["generated_at"] = aggregate._generated_at(NOW)
    put_previous(s3, previous)
    caplog.set_level(logging.INFO, logger="sheket.aggregate")

    run()

    assert published(s3)["version"] == NOW - 60  # not rewritten
    assert not [r for r in caplog.records if r.levelno == logging.WARNING]


# --- _should_write and _content units ------------------------------------------


def _doc(curated, version):
    return build_blocklist(curated, [], [], version, 0, 3, 2)


def test_should_write_on_the_first_run(curated):
    assert aggregate._should_write(_doc(curated, NOW), None, NOW) is True


def test_content_ignores_only_version_and_generated_at(curated):
    a = _doc(curated, NOW)
    b = _doc(curated, NOW - 100)
    assert aggregate._content(a) == aggregate._content(b)
    assert "version" not in aggregate._content(a)
    assert "generated_at" not in aggregate._content(a)
    assert set(aggregate._content(a)) == set(a) - {"version", "generated_at"}
    assert "version" in a  # the input is not mutated


@pytest.mark.parametrize(
    "field",
    [
        "schema",
        "call_numbers",
        "call_prefixes",
        "sms_senders",
        "sms_keywords",
        "sms_allow_senders",
    ],
)
def test_any_content_field_change_is_a_write(curated, field):
    new = _doc(curated, NOW)
    previous = copy.deepcopy(new)
    previous["version"] = NOW - 60
    previous[field] = ["changed"]
    assert aggregate._should_write(new, previous, NOW) is True


def test_list_order_change_is_a_write(curated):
    new = _doc(curated, NOW)
    previous = copy.deepcopy(new)
    previous["sms_allow_senders"] = list(reversed(previous["sms_allow_senders"]))
    assert aggregate._should_write(new, previous, NOW) is True


@pytest.mark.parametrize(
    ("generated_at", "expected"),
    [
        ("2026-10-06T06:00:00Z", True),  # exactly 6 h
        ("2026-10-06T06:00:01Z", False),
        ("2026-10-06T06:00:01", False),  # naive -> UTC
        ("2026-10-06T06:00:00", True),
        ("2026-10-06T09:00:01+03:00", False),  # 06:00:01Z
        ("2026-10-06T09:00:00+03:00", True),
        ("2026-10-06T13:00:00Z", True),  # in the future: forces a refresh
    ],
)
def test_should_write_refresh_age(curated, generated_at, expected):
    new = _doc(curated, NOW)
    previous = copy.deepcopy(new)
    previous["generated_at"] = generated_at
    assert aggregate._should_write(new, previous, NOW) is expected


# --- AC-5: object metadata and body --------------------------------------------


def test_object_is_written_with_content_type_and_cache_control(aws):
    _, s3 = aws
    run()
    head = s3.head_object(Bucket=BUCKET_NAME, Key=BLOCKLIST_KEY)
    assert head["ContentType"] == "application/json; charset=utf-8"
    assert head["CacheControl"] == "public, max-age=300"


def test_refreshed_object_keeps_the_metadata(aws, clock):
    _, s3 = aws
    put_previous(s3, b"garbage")  # written without metadata
    run()
    head = s3.head_object(Bucket=BUCKET_NAME, Key=BLOCKLIST_KEY)
    assert head["CacheControl"] == "public, max-age=300"
    assert head["ContentType"] == "application/json; charset=utf-8"


def test_body_is_the_seed_serialisation_in_raw_utf8(aws, contract_dir):
    _, s3 = aws
    run()
    body = published_bytes(s3)
    text = body.decode("utf-8")
    assert body.endswith(b"\n")
    assert "\\u" not in text  # Hebrew keywords stored raw, not escaped
    assert text == serialize_blocklist(json.loads(text))
    # Same bytes as the committed seed apart from version and generated_at.
    seed = json.loads((contract_dir / "seed-blocklist.json").read_text("utf-8"))
    doc = json.loads(text)
    doc["version"] = seed["version"]
    doc["generated_at"] = seed["generated_at"]
    assert serialize_blocklist(doc) == (contract_dir / "seed-blocklist.json").read_text(
        "utf-8"
    )


def test_only_the_blocklist_key_is_written(aws):
    _, s3 = aws
    run()
    keys = [o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET_NAME)["Contents"]]
    assert keys == ["v1/blocklist.json"]


def test_cache_control_matches_the_five_minute_ttl():
    assert aggregate.CACHE_CONTROL == "public, max-age=300"
    assert aggregate.BLOCKLIST_KEY == "v1/blocklist.json"


# --- AC-6: the EMF heartbeat ----------------------------------------------------


def test_successful_run_prints_exactly_one_emf_line(aws, capsys):
    assert run() is None
    out = capsys.readouterr().out
    (line,) = emf_lines(out)
    # One physical line: EMF needs the whole JSON object on a single line.
    assert sum(1 for raw in out.splitlines() if '"_aws"' in raw) == 1
    assert line["_aws"]["CloudWatchMetrics"] == [
        {
            "Namespace": "Sheket",
            "Dimensions": [["Function"]],
            "Metrics": [{"Name": "AggregateSucceeded", "Unit": "Count"}],
        }
    ]
    assert line["Function"] == "aggregate"
    assert line["AggregateSucceeded"] == 1
    assert line["written"] is True
    assert isinstance(line["_aws"]["Timestamp"], int)
    assert line["_aws"]["Timestamp"] > 1_000_000_000_000  # milliseconds


def test_emf_line_carries_counts_only(aws, capsys):
    ddb, _ = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(hours=1))
    put_override(ddb, "force_block#call#+972521112233")
    run()
    (line,) = emf_lines(capsys.readouterr().out)
    assert line["call_numbers"] == 1
    assert line["sms_senders"] == 1
    assert set(line) == {
        "_aws",
        "Function",
        "AggregateSucceeded",
        "written",
        "call_numbers",
        "sms_senders",
    }


def test_each_run_prints_its_own_heartbeat(aws, clock, capsys):
    run()
    clock.now = NOW + 60
    run()
    lines = emf_lines(capsys.readouterr().out)
    assert [line["written"] for line in lines] == [True, False]
    assert all(line["AggregateSucceeded"] == 1 for line in lines)


# --- AC-7: thresholds and names come from the environment ------------------------


def test_thresholds_are_read_from_the_environment(aws, monkeypatch):
    ddb, s3 = aws
    put_group(ddb, "sms", SMS, NOW_DT - timedelta(hours=1), installs=2)
    run()
    assert published(s3)["sms_senders"] == []

    monkeypatch.setenv("MIN_INSTALLS", "2")
    put_override(ddb, "force_block#call#+972521112233")  # force a write
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]


def test_min_networks_is_read_from_the_environment(aws, monkeypatch):
    ddb, s3 = aws
    for i in range(MIN_INSTALLS):
        put_report(ddb, "sms", SMS, i, NET_A, NOW_DT - timedelta(hours=1))
    monkeypatch.setenv("MIN_NETWORKS", "1")
    run()
    assert published(s3)["sms_senders"] == [SMS_NORMALISED]


def test_bucket_name_is_read_from_the_environment(aws, monkeypatch):
    _, s3 = aws
    s3.create_bucket(Bucket="other-bucket")
    monkeypatch.setenv("BUCKET_NAME", "other-bucket")
    run()
    assert object_count(s3) == 0
    s3.head_object(Bucket="other-bucket", Key=BLOCKLIST_KEY)


def test_config_reads_all_four_variables(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", "t1")
    monkeypatch.setenv("BUCKET_NAME", "b1")
    monkeypatch.setenv("MIN_INSTALLS", "7")
    monkeypatch.setenv("MIN_NETWORKS", "4")
    assert aggregate._config() == ("t1", "b1", 7, 4)


@pytest.mark.parametrize(
    "name", ["TABLE_NAME", "BUCKET_NAME", "MIN_INSTALLS", "MIN_NETWORKS"]
)
def test_missing_variable_raises_before_any_aws_call(monkeypatch, name):
    # No moto fixture: an AWS call would fail with _NoAwsClient's error instead.
    monkeypatch.delenv(name)
    with pytest.raises(KeyError, match=name):
        run()


@pytest.mark.parametrize(
    "value",
    ["0", "-1", "+3", " 3", "3 ", "3\n", "3.0", "1e3", "3_0", "", "abc", "٣", "0x3"],
    ids=repr,
)
@pytest.mark.parametrize("name", ["MIN_INSTALLS", "MIN_NETWORKS"])
def test_invalid_threshold_raises_naming_the_variable(monkeypatch, name, value):
    monkeypatch.setenv(name, value)
    with pytest.raises(ValueError, match=name):
        run()


@pytest.mark.parametrize(("value", "parsed"), [("1", 1), ("03", 3), ("100", 100)])
def test_valid_threshold_values(monkeypatch, value, parsed):
    monkeypatch.setenv("MIN_INSTALLS", value)
    assert aggregate._config().min_installs == parsed


# --- AC-8: no AWS credentials, no real endpoint ---------------------------------


def test_handler_outside_moto_never_reaches_aws():
    # aws_env installs _NoAwsClient; without the moto fixtures any AWS call
    # fails the test instead of reaching a real endpoint.
    with pytest.raises(AssertionError, match="no moto"):
        run()


def test_clients_are_created_lazily_and_cached(aws):
    ddb_client = aggregate._dynamodb()
    s3_client = aggregate._s3()
    assert aggregate._dynamodb() is ddb_client
    assert aggregate._s3() is s3_client


# --- logging: counts only -----------------------------------------------------


def test_logs_never_carry_senders_install_ids_or_network_hashes(aws, caplog):
    ddb, _ = aws
    put_group(ddb, "sms", "SecretParty", NOW_DT - timedelta(hours=1))
    put_override(ddb, "force_block#sms#HiddenSender")
    caplog.set_level(logging.DEBUG, logger="sheket.aggregate")
    run()
    text = caplog.text
    for secret in (
        "SecretParty",
        "secretparty",
        "HiddenSender",
        "hiddensender",
        install_id(0),
        NET_A,
        NET_B,
    ):
        assert secret not in text
    assert f"blocklist written: version={NOW} " in text
    assert "loaded 3 reports from 8 day partitions" in text


def test_now_is_read_once_per_run(aws, monkeypatch):
    calls = []

    def now():
        calls.append(1)
        return NOW

    monkeypatch.setattr(aggregate, "_now", now)
    run()
    assert len(calls) == 1


def test_default_clock_returns_whole_unix_seconds():
    value = aggregate._now()
    assert isinstance(value, int)
    assert abs(value - datetime.now(timezone.utc).timestamp()) < 5
