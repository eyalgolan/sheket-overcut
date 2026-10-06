"""Tests for ``sheket.report``, the ``POST /v1/reports`` handler (spec 6.2).

DynamoDB is moto's in-memory implementation (the ``ddb_table`` fixture), so
the conditional counters and transaction rollback are exercised for real.
moto never produces ``TransactionConflict``, so the retry path uses a stub
client instead.
"""

import base64
import hashlib
import hmac
import json
import logging
import re
from datetime import datetime, timedelta, timezone

import boto3
import pytest
from botocore.exceptions import ClientError

from sheket import report
from sheket.normalize import is_e164

INSTALL_ID = "3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11"
SOURCE_IP = "203.0.113.57"
FIXED_NOW = datetime(2026, 10, 6, 12, 34, 56, 789123, tzinfo=timezone.utc)


def install_id(n):
    """Return a distinct, valid lowercase install UUID for index ``n``."""
    return f"00000000-0000-4000-8000-{n:012d}"


def payload(**overrides):
    """Return a valid SMS report body, with ``overrides`` applied.

    An override of ``...`` (Ellipsis) removes that field.
    """
    body = {
        "install_id": INSTALL_ID,
        "platform": "android",
        "kind": "sms",
        "sender": "ExampleParty",
        "text": "Vote for us on election day",
        "app_version": "1.0.0",
    }
    for key, value in overrides.items():
        if value is ...:
            body.pop(key, None)
        else:
            body[key] = value
    return body


def call_payload(**overrides):
    """Return a valid call report body (no text), with ``overrides`` applied."""
    base = {"kind": "call", "sender": "+972501234567", "text": ...}
    base.update(overrides)
    return payload(**base)


def make_event(
    body=None,
    *,
    path="/v1/reports",
    method="POST",
    ip=SOURCE_IP,
    raw_body=None,
    b64=False,
):
    """Build a Function URL payload v2.0 event.

    ``body`` is JSON-encoded as raw UTF-8, as the apps send it; ``raw_body``
    is used verbatim instead.
    """
    if raw_body is None and body is not None:
        raw_body = json.dumps(body, ensure_ascii=False)
    if b64 and raw_body is not None:
        data = raw_body if isinstance(raw_body, bytes) else raw_body.encode("utf-8")
        raw_body = base64.b64encode(data).decode("ascii")
    event = {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": path,
        "rawQueryString": "",
        "headers": {"content-type": "application/json"},
        "requestContext": {
            "http": {
                "method": method,
                "path": path,
                "protocol": "HTTP/1.1",
                "sourceIp": ip,
                "userAgent": "test",
            }
        },
        "isBase64Encoded": b64,
    }
    if raw_body is not None:
        event["body"] = raw_body
    return event


def call(event):
    """Invoke the handler; return ``(status, parsed body, headers)``."""
    resp = report.handler(event, None)
    return resp["statusCode"], json.loads(resp["body"]), resp["headers"]


def post(body=None, **kwargs):
    return call(make_event(body, **kwargs))


def scan_all(client):
    items, kwargs = [], {"TableName": report._table_name()}
    while True:
        page = client.scan(**kwargs)
        items.extend(page["Items"])
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def reports(client):
    return [i for i in scan_all(client) if i["pk"]["S"].startswith("R#")]


def counters(client):
    """Return ``{pk: n}`` for every rate-limit counter item."""
    return {
        i["pk"]["S"]: int(i["n"]["N"])
        for i in scan_all(client)
        if i["pk"]["S"].startswith("RL#")
    }


def expected_hmac(msg):
    return hmac.new(
        b"test-only-salt-not-a-secret", msg.encode(), hashlib.sha256
    ).hexdigest()


@pytest.fixture
def clock(monkeypatch):
    """Freeze ``report._now``; set ``clock.now`` to move time."""

    class Clock:
        now = FIXED_NOW

    c = Clock()
    monkeypatch.setattr(report, "_now", lambda: c.now)
    return c


@pytest.fixture
def no_ddb(monkeypatch):
    """Fail the test if the handler touches DynamoDB or the salt at all."""

    def boom(*args, **kwargs):
        raise AssertionError("DynamoDB or salt used for a rejected request")

    monkeypatch.setattr(report, "_dynamodb", boom)
    monkeypatch.setattr(report, "_salt", boom)


# --- Routing -----------------------------------------------------------------


@pytest.mark.parametrize(
    "path", ["/", "/v1/report", "/v1/reports/", "/V1/REPORTS", "/v2/reports"]
)
def test_other_path_is_404(no_ddb, path):
    status, body, _ = post(payload(), path=path)
    assert status == 404
    assert body == {"error": "not_found"}


def test_missing_raw_path_is_404(no_ddb):
    event = make_event(payload())
    del event["rawPath"]
    assert call(event)[0] == 404


def test_path_is_checked_before_method(no_ddb):
    assert post(payload(), path="/other", method="GET")[0] == 404


@pytest.mark.parametrize("method", ["GET", "PUT", "DELETE", "PATCH", "OPTIONS"])
def test_other_method_is_405_with_allow_header(no_ddb, method):
    status, body, headers = post(payload(), method=method)
    assert status == 405
    assert body == {"error": "method_not_allowed"}
    assert headers["Allow"] == "POST"
    assert headers["Content-Type"] == "application/json"


# --- AC-1: one 400 per malformed field ---------------------------------------


@pytest.mark.parametrize(
    "event",
    [
        pytest.param(make_event(None), id="missing"),
        pytest.param(make_event(raw_body=""), id="empty"),
        pytest.param(make_event(raw_body="{not json"), id="not-json"),
        pytest.param(make_event(raw_body="[1, 2]"), id="array"),
        pytest.param(make_event(raw_body='"string"'), id="json-string"),
        pytest.param(make_event(raw_body="null"), id="json-null"),
        pytest.param(make_event(raw_body='{"a": NaN}'), id="nan"),
        pytest.param(make_event(raw_body='{"a": Infinity}'), id="infinity"),
        pytest.param(make_event(raw_body='{"a": -Infinity}'), id="neg-infinity"),
        pytest.param(make_event(raw_body="[" * 100000), id="deep-nesting"),
        pytest.param(
            make_event(raw_body="!!!", b64=False) | {"isBase64Encoded": True},
            id="invalid-base64",
        ),
        pytest.param(make_event(raw_body=b"\xff\xfe{}", b64=True), id="invalid-utf8"),
        pytest.param(
            make_event(raw_body=json.dumps(payload()).encode("utf-16"), b64=True),
            id="utf16",
        ),
        pytest.param(make_event(raw_body='{"a": "\ud800"}'), id="lone-surrogate-raw"),
    ],
)
def test_malformed_body_is_400(no_ddb, event):
    assert call(event)[:2] == (400, {"error": "body"})


def test_non_string_body_is_400(no_ddb):
    event = make_event(payload())
    event["body"] = {"install_id": INSTALL_ID}
    assert call(event)[:2] == (400, {"error": "body"})


def _padded_body(size):
    """Return a valid report body string of exactly ``size`` UTF-8 bytes."""
    base = payload(pad="")
    pad = size - len(json.dumps(base).encode("utf-8"))
    assert pad >= 0
    return json.dumps(payload(pad="x" * pad))


def test_body_at_cap_is_accepted(ddb_table):
    raw = _padded_body(report.MAX_BODY_BYTES)
    assert len(raw.encode("utf-8")) == report.MAX_BODY_BYTES
    assert post(raw_body=raw)[0] == 202


def test_body_over_cap_is_400(no_ddb):
    raw = _padded_body(report.MAX_BODY_BYTES + 1)
    assert post(raw_body=raw)[:2] == (400, {"error": "body"})


def test_body_cap_is_measured_after_base64_decoding(ddb_table):
    raw = _padded_body(report.MAX_BODY_BYTES)
    # The base64 text is a third longer, but the decoded body is exactly at
    # the cap.
    assert post(raw_body=raw, b64=True)[0] == 202
    raw = _padded_body(report.MAX_BODY_BYTES + 1)
    assert post(raw_body=raw, b64=True)[:2] == (400, {"error": "body"})


def test_base64_body_is_accepted(ddb_table):
    assert post(payload(), b64=True)[0] == 202


@pytest.mark.parametrize(
    "value",
    [
        ...,
        None,
        "",
        123,
        "not-a-uuid",
        "3f0e4c1e6a0b4f5e9d0a2f6c1b7a9e11",
        "{3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11}",
        "urn:uuid:3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11",
        "3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e1",
        "3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e1g",
        "3f0e4c1e6-a0b-4f5e-9d0a-2f6c1b7a9e11",
    ],
)
def test_bad_install_id_is_400(no_ddb, value):
    assert post(payload(install_id=value))[:2] == (400, {"error": "install_id"})


@pytest.mark.parametrize("value", [..., None, "", "IOS", "Android", "web", 1, ["ios"]])
def test_bad_platform_is_400(no_ddb, value):
    assert post(payload(platform=value))[:2] == (400, {"error": "platform"})


@pytest.mark.parametrize("value", [..., None, "", "SMS", "Call", "voice", True])
def test_bad_kind_is_400(no_ddb, value):
    assert post(payload(kind=value))[:2] == (400, {"error": "kind"})


@pytest.mark.parametrize(
    "value",
    [
        ...,
        None,
        "",
        "   ",
        972501234567,
        "00972501234567",
        "1800500500",
        "a" * 21,
        "two words",
    ],
)
def test_bad_sender_is_400(no_ddb, value):
    assert post(payload(sender=value))[:2] == (400, {"error": "sender"})


def test_sender_with_lone_surrogate_escape_is_400(no_ddb):
    raw = json.dumps(payload(sender="PLACEHOLDER")).replace("PLACEHOLDER", "\\ud800")
    assert post(raw_body=raw)[:2] == (400, {"error": "sender"})


@pytest.mark.parametrize(
    "value",
    [123, ["a"], {"a": 1}, True, "x" * (report.MAX_TEXT_CHARS + 1)],
)
def test_bad_text_is_400(no_ddb, value):
    assert post(payload(text=value))[:2] == (400, {"error": "text"})


def test_text_with_lone_surrogate_escape_is_400(no_ddb):
    raw = json.dumps(payload(text="PLACEHOLDER")).replace("PLACEHOLDER", "ok \\udfff")
    assert post(raw_body=raw)[:2] == (400, {"error": "text"})


@pytest.mark.parametrize(
    "value",
    [
        ...,
        None,
        "",
        100,
        "1.0.0\n",
        "1.0 beta",
        "1.0.0_rc",
        "١.٠",
        "v" * 33,
    ],
)
def test_bad_app_version_is_400(no_ddb, value):
    assert post(payload(app_version=value))[:2] == (400, {"error": "app_version"})


@pytest.mark.parametrize(
    "value", ["1", "1.0.0", "2.3.4+build.5", "1.0.0-rc.1", "v" * 32]
)
def test_good_app_version_is_accepted(ddb_table, value):
    assert post(payload(app_version=value))[0] == 202


@pytest.mark.parametrize(
    "overrides, field",
    [
        ({"install_id": "x", "platform": "x", "app_version": ""}, "install_id"),
        ({"platform": "x", "kind": "x", "sender": ""}, "platform"),
        ({"kind": "x", "sender": "", "text": 1}, "kind"),
        ({"sender": "", "text": 1, "app_version": ""}, "sender"),
        ({"text": 1, "app_version": ""}, "text"),
    ],
)
def test_first_failing_field_is_reported(no_ddb, overrides, field):
    assert post(payload(**overrides))[:2] == (400, {"error": field})


def test_unknown_fields_are_ignored_and_not_stored(ddb_table):
    assert post(payload(extra="ignored", ip="198.51.100.1"))[0] == 202
    (item,) = reports(ddb_table)
    assert "extra" not in item
    assert "ip" not in item


# --- AC-2: sender normalisation and E.164 for calls --------------------------


@pytest.mark.parametrize(
    "raw, stored",
    [
        ("+972 50-123-4567", "+972501234567"),
        ("050-123-4567", "+972501234567"),
        ("972501234567", "+972501234567"),
    ],
)
def test_call_sender_is_normalised_to_e164(ddb_table, raw, stored):
    assert post(call_payload(sender=raw))[0] == 202
    (item,) = reports(ddb_table)
    assert item["sender"] == {"S": stored}


@pytest.mark.parametrize("sender", ["ExampleParty", "100", "*2700"])
def test_call_sender_must_be_e164(no_ddb, sender):
    # Each of these normalises fine for an SMS, but is not an E.164 number.
    assert post(call_payload(sender=sender))[:2] == (400, {"error": "sender"})


@pytest.mark.parametrize(
    "raw, stored",
    [
        ("  ExampleParty ", "exampleparty"),
        ("STRASSE", "strasse"),
        ("Straße", "strasse"),
        ("1-0-0", "100"),
        ("*2700", "*2700"),
        ("050-123-4567", "+972501234567"),
    ],
)
def test_sms_sender_is_normalised(ddb_table, raw, stored):
    assert post(payload(sender=raw))[0] == 202
    (item,) = reports(ddb_table)
    assert item["sender"] == {"S": stored}


def test_report_sms_sender_matches_corpus(ddb_table, normalize_case):
    # contract/README.md: every spelling in the corpus counts as one sender
    # everywhere, reports included.
    out = normalize_case["out"]
    status, body, _ = post(payload(sender=normalize_case["in"]))
    if out is None:
        assert (status, body) == (400, {"error": "sender"})
        assert scan_all(ddb_table) == []
    else:
        assert status == 202
        (item,) = reports(ddb_table)
        assert item["sender"] == {"S": out}


def test_report_call_sender_matches_corpus(ddb_table, normalize_case):
    # A call report also needs the normalised sender to be an E.164 number.
    out = normalize_case["out"]
    status, body, _ = post(call_payload(sender=normalize_case["in"]))
    if out is not None and is_e164(out):
        assert status == 202
        (item,) = reports(ddb_table)
        assert item["sender"] == {"S": out}
    else:
        assert (status, body) == (400, {"error": "sender"})
        assert scan_all(ddb_table) == []


# --- AC-3: text length --------------------------------------------------------


@pytest.mark.parametrize("char", ["x", "ש", "🗳"])
def test_text_limit_counts_code_points(ddb_table, char):
    text = char * report.MAX_TEXT_CHARS
    assert post(payload(text=text))[0] == 202
    (item,) = reports(ddb_table)
    assert item["text"] == {"S": text}
    assert post(payload(text=text + char))[:2] == (400, {"error": "text"})
    assert len(reports(ddb_table)) == 1


def test_worst_case_escaped_1000_char_text_is_accepted(ddb_table):
    # The largest valid report, from a client whose JSON encoder escapes
    # non-ASCII as \uXXXX: each non-BMP character becomes a 12-byte
    # surrogate pair.
    text = "🗳" * report.MAX_TEXT_CHARS
    body = payload(
        platform="android",
        sender="🗳" * 20,
        text=text,
        app_version="9" * 32,
    )
    raw = json.dumps(body, ensure_ascii=True)
    assert 8192 < len(raw.encode("utf-8")) <= report.MAX_BODY_BYTES
    assert post(raw_body=raw)[0] == 202
    (item,) = reports(ddb_table)
    assert item["text"] == {"S": text}


def test_text_on_call_report_is_400(no_ddb):
    # Provisional answer to owner Decision 6.
    assert post(call_payload(text="hello"))[:2] == (400, {"error": "text"})
    assert post(call_payload(text=""))[:2] == (400, {"error": "text"})


def test_null_text_on_call_report_is_accepted(ddb_table):
    assert post(call_payload(text=None))[0] == 202


# --- AC-4: accepted report and the stored item --------------------------------


def test_valid_sms_report_is_202_and_stores_one_item(ddb_table, clock):
    status, body, headers = post(payload(install_id=INSTALL_ID.upper()))
    assert status == 202
    assert body == {}
    assert headers["Content-Type"] == "application/json"

    (item,) = reports(ddb_table)
    assert set(item) == {
        "pk",
        "sk",
        "install_id",
        "platform",
        "kind",
        "sender",
        "text",
        "app_version",
        "received_at",
        "net_hash",
        "expires_at",
    }
    assert item["pk"] == {"S": "R#2026-10-06"}
    assert item["install_id"] == {"S": INSTALL_ID}
    assert item["platform"] == {"S": "android"}
    assert item["kind"] == {"S": "sms"}
    assert item["sender"] == {"S": "exampleparty"}
    assert item["text"] == {"S": "Vote for us on election day"}
    assert item["app_version"] == {"S": "1.0.0"}
    assert item["received_at"] == {"S": "2026-10-06T12:34:56.789Z"}
    assert item["net_hash"] == {"S": expected_hmac("v4:203.0.113.0/24")}
    assert re.fullmatch(
        r"2026-10-06T12:34:56\.789Z#[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
        r"[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        item["sk"]["S"],
    )


@pytest.mark.parametrize("text", [..., None])
def test_absent_or_null_text_is_not_stored(ddb_table, text):
    assert post(payload(text=text))[0] == 202
    (item,) = reports(ddb_table)
    assert "text" not in item


def test_valid_call_report_is_202(ddb_table):
    assert post(call_payload(platform="ios"))[:2] == (202, {})
    (item,) = reports(ddb_table)
    assert item["kind"] == {"S": "call"}
    assert item["platform"] == {"S": "ios"}
    assert "text" not in item


def test_each_report_gets_its_own_item(ddb_table, clock):
    # Same install, same millisecond: the uuid4 in sk keeps them apart.
    for _ in range(3):
        assert post(payload())[0] == 202
    items = reports(ddb_table)
    assert len(items) == 3
    assert len({i["sk"]["S"] for i in items}) == 3


def test_received_at_pads_milliseconds(ddb_table, clock):
    clock.now = datetime(2026, 1, 2, 3, 4, 5, 7000, tzinfo=timezone.utc)
    assert post(payload())[0] == 202
    (item,) = reports(ddb_table)
    assert item["received_at"] == {"S": "2026-01-02T03:04:05.007Z"}
    assert item["pk"] == {"S": "R#2026-01-02"}


# --- AC-5: the raw IP is never stored or logged; network hashing --------------


def test_raw_ip_is_not_stored_or_logged(ddb_table, caplog):
    caplog.set_level(logging.DEBUG)
    ip = "198.51.100.234"
    assert post(payload(), ip=ip)[0] == 202
    stored = json.dumps(scan_all(ddb_table))
    assert ip not in stored
    assert "198.51.100" not in stored
    assert ip not in caplog.text
    assert "198.51.100" not in caplog.text


def test_report_logs_one_line_without_request_content(ddb_table, caplog):
    caplog.set_level(logging.INFO, logger="sheket.report")
    body = payload(sender="SecretSender", text="private message text")
    assert post(body)[0] == 202
    records = [r for r in caplog.records if r.name == "sheket.report"]
    assert len(records) == 1
    msg = records[0].getMessage()
    assert msg == "report outcome=accepted kind=sms platform=android"
    for secret in (
        "secretsender",
        "SecretSender",
        "private message text",
        INSTALL_ID,
        SOURCE_IP,
        "test-only-salt-not-a-secret",
    ):
        assert secret not in caplog.text


def test_rejected_log_names_field_only(no_ddb, caplog):
    caplog.set_level(logging.INFO, logger="sheket.report")
    # An invalid platform value must not be echoed into the logs.
    assert post(payload(platform="evil-198.51.100.7"))[0] == 400
    records = [r for r in caplog.records if r.name == "sheket.report"]
    assert [r.getMessage() for r in records] == [
        "report outcome=rejected field=platform"
    ]
    assert "evil" not in caplog.text


@pytest.mark.parametrize(
    "path, method, outcome",
    [("/x", "POST", "not_found"), ("/v1/reports", "GET", "method_not_allowed")],
)
def test_routing_logs_outcome(no_ddb, caplog, path, method, outcome):
    caplog.set_level(logging.INFO, logger="sheket.report")
    post(payload(), path=path, method=method)
    records = [r for r in caplog.records if r.name == "sheket.report"]
    assert [r.getMessage() for r in records] == [f"report outcome={outcome}"]


def test_ipv4_net_hash_groups_by_slash_24():
    a, ka = report._network_hashes("203.0.113.1", "s")
    b, kb = report._network_hashes("203.0.113.254", "s")
    c, _ = report._network_hashes("203.0.114.1", "s")
    assert a == b
    assert a != c
    # The per-IP key uses the full address.
    assert ka != kb


def test_ipv6_net_hash_groups_by_slash_48():
    # Provisional answer to owner Decision 2.
    a, ka = report._network_hashes("2001:db8:1:aaaa::1", "s")
    b, kb = report._network_hashes("2001:db8:1:bbbb:cccc::2", "s")
    c, _ = report._network_hashes("2001:db8:2::1", "s")
    assert a == b
    assert a != c
    assert ka != kb


def test_ipv4_mapped_ipv6_is_treated_as_ipv4():
    assert report._network_hashes("::ffff:203.0.113.9", "s") == (
        report._network_hashes("203.0.113.9", "s")
    )


def test_ipv6_spellings_share_one_ip_key():
    assert report._network_hashes("2001:0db8:0000:0000:0000:0000:0000:0001", "s") == (
        report._network_hashes("2001:db8::1", "s")
    )


def test_hashes_are_keyed_by_the_salt():
    net, key = report._network_hashes("203.0.113.9", "salt-a")
    assert net == hmac.new(b"salt-a", b"v4:203.0.113.0/24", hashlib.sha256).hexdigest()
    assert key == hmac.new(b"salt-a", b"ip:203.0.113.9", hashlib.sha256).hexdigest()
    assert report._network_hashes("203.0.113.9", "salt-b") != (net, key)


def test_ipv4_and_ipv6_hashes_are_domain_separated():
    # The prefixes in the HMAC input keep the families apart.
    v4, _ = report._network_hashes("10.0.0.1", "s")
    assert v4 == hmac.new(b"s", b"v4:10.0.0.0/24", hashlib.sha256).hexdigest()
    v6, _ = report._network_hashes("2001:db8::1", "s")
    assert v6 == hmac.new(b"s", b"v6:2001:db8::/48", hashlib.sha256).hexdigest()


def test_ip_counter_key_holds_only_the_hash(ddb_table, clock):
    assert post(payload())[0] == 202
    ip_counters = [pk for pk in counters(ddb_table) if pk.startswith("RL#A#")]
    assert ip_counters == [f"RL#A#{expected_hmac('ip:' + SOURCE_IP)}#2026-10-06T12"]


# --- AC-6: TTLs ---------------------------------------------------------------


def test_report_and_counters_have_ttls(ddb_table, clock):
    assert post(payload())[0] == 202
    items = {i["pk"]["S"]: i for i in scan_all(ddb_table)}
    assert len(items) == 3

    report_item = items["R#2026-10-06"]
    expected = int(FIXED_NOW.timestamp()) + 30 * 86400
    assert int(report_item["expires_at"]["N"]) == expected
    assert expected == int(
        datetime(2026, 11, 5, 12, 34, 56, tzinfo=timezone.utc).timestamp()
    )

    install = items[f"RL#I#{INSTALL_ID}#2026-10-06"]
    assert install["sk"] == {"S": "-"}
    assert install["n"] == {"N": "1"}
    # End of the UTC day plus one day.
    assert int(install["expires_at"]["N"]) == int(
        datetime(2026, 10, 8, tzinfo=timezone.utc).timestamp()
    )

    (ip_pk,) = [pk for pk in items if pk.startswith("RL#A#")]
    ip_counter = items[ip_pk]
    assert ip_counter["sk"] == {"S": "-"}
    assert ip_counter["n"] == {"N": "1"}
    # End of the UTC hour plus one hour.
    assert int(ip_counter["expires_at"]["N"]) == int(
        datetime(2026, 10, 6, 14, tzinfo=timezone.utc).timestamp()
    )


def test_counter_ttls_at_day_and_year_boundaries():
    now = datetime(2026, 12, 31, 23, 59, 59, 999999, tzinfo=timezone.utc)
    assert report._install_counter_ttl(now) == int(
        datetime(2027, 1, 2, tzinfo=timezone.utc).timestamp()
    )
    assert report._ip_counter_ttl(now) == int(
        datetime(2027, 1, 1, 1, tzinfo=timezone.utc).timestamp()
    )


# --- AC-7: 20 per install per UTC day -----------------------------------------


def test_21st_report_from_one_install_in_a_day_is_429(ddb_table, clock):
    for i in range(report.INSTALL_DAILY_LIMIT):
        # A different IP for each, so only the install limit applies.
        assert post(payload(), ip=f"198.51.100.{i}")[0] == 202
    status, body, _ = post(payload(), ip="198.51.100.200")
    assert (status, body) == (429, {"error": "rate_limited"})
    assert len(reports(ddb_table)) == 20


def test_install_limit_is_per_install(ddb_table, clock):
    for _ in range(report.INSTALL_DAILY_LIMIT):
        assert post(payload())[0] == 202
    assert post(payload())[0] == 429
    assert post(payload(install_id=install_id(1)))[0] == 202


def test_install_limit_resets_on_the_next_utc_day(ddb_table, clock):
    clock.now = datetime(2026, 10, 6, 23, 30, tzinfo=timezone.utc)
    for _ in range(report.INSTALL_DAILY_LIMIT):
        assert post(payload())[0] == 202
    assert post(payload())[0] == 429
    clock.now = datetime(2026, 10, 7, 0, 0, tzinfo=timezone.utc)
    assert post(payload())[0] == 202


def test_install_limit_ignores_install_id_case(ddb_table, clock):
    for i in range(report.INSTALL_DAILY_LIMIT):
        iid = INSTALL_ID.upper() if i % 2 else INSTALL_ID
        assert post(payload(install_id=iid))[0] == 202
    assert post(payload(install_id=INSTALL_ID.upper()))[0] == 429


# --- AC-8: 60 per source IP per hour ------------------------------------------


def _fill_ip_quota(ip=SOURCE_IP):
    """Send 60 accepted reports from ``ip`` using three installs."""
    for i in range(report.IP_HOURLY_LIMIT):
        iid = install_id(i // report.INSTALL_DAILY_LIMIT)
        assert post(payload(install_id=iid), ip=ip)[0] == 202


def test_61st_report_from_one_ip_in_an_hour_is_429(ddb_table, clock):
    _fill_ip_quota()
    status, body, _ = post(payload(install_id=install_id(3)))
    assert (status, body) == (429, {"error": "rate_limited"})
    assert len(reports(ddb_table)) == 60


def test_ip_limit_is_per_full_address(ddb_table, clock):
    _fill_ip_quota("203.0.113.1")
    # Same /24, different address: its own counter.
    assert post(payload(install_id=install_id(3)), ip="203.0.113.2")[0] == 202


def test_ip_limit_resets_on_the_next_hour(ddb_table, clock):
    clock.now = datetime(2026, 10, 6, 12, 59, 59, tzinfo=timezone.utc)
    _fill_ip_quota()
    assert post(payload(install_id=install_id(3)))[0] == 429
    clock.now = datetime(2026, 10, 6, 13, 0, tzinfo=timezone.utc)
    assert post(payload(install_id=install_id(3)))[0] == 202


def test_ip_limit_applies_to_ipv6_spellings(ddb_table, clock):
    _fill_ip_quota("2001:db8::1")
    assert post(payload(install_id=install_id(3)), ip="2001:0db8:0:0:0:0:0:1")[0] == 429


# --- AC-9: a 429 writes nothing -----------------------------------------------


def test_install_429_leaves_no_item_and_no_increment(ddb_table, clock):
    for i in range(report.INSTALL_DAILY_LIMIT):
        assert post(payload(), ip=f"198.51.100.{i}")[0] == 202
    before_counters = counters(ddb_table)
    before_reports = reports(ddb_table)
    assert before_counters[f"RL#I#{INSTALL_ID}#2026-10-06"] == 20

    assert post(payload(), ip="198.51.100.200")[0] == 429

    # The new IP's counter was not created, and nothing else changed.
    assert counters(ddb_table) == before_counters
    assert reports(ddb_table) == before_reports


def test_ip_429_leaves_no_item_and_no_increment(ddb_table, clock):
    _fill_ip_quota()
    before_counters = counters(ddb_table)
    before_reports = reports(ddb_table)
    ip_pk = f"RL#A#{expected_hmac('ip:' + SOURCE_IP)}#2026-10-06T12"
    assert before_counters[ip_pk] == 60

    assert post(payload(install_id=install_id(3)))[0] == 429

    # The fourth install's counter was not created.
    assert f"RL#I#{install_id(3)}#2026-10-06" not in counters(ddb_table)
    assert counters(ddb_table) == before_counters
    assert reports(ddb_table) == before_reports


def test_moto_reports_cancellation_reasons_by_position(ddb_table, clock):
    """The 429 logic relies on the per-item reasons; check moto gives them."""
    for _ in range(report.INSTALL_DAILY_LIMIT):
        assert post(payload())[0] == 202
    fields, _ = report._validate(make_event(payload()))
    items = report._transact_items(fields, "n", "k", clock.now)
    with pytest.raises(ClientError) as exc:
        ddb_table.transact_write_items(TransactItems=items)
    reasons = [r["Code"] for r in exc.value.response["CancellationReasons"]]
    assert reasons == ["ConditionalCheckFailed", "None", "None"]


# --- AC-10: rejected requests use no quota ------------------------------------


def test_malformed_requests_use_no_quota(ddb_table, clock):
    bad = [
        payload(platform="web"),
        payload(kind="fax"),
        payload(sender=""),
        payload(text="x" * 1001),
        payload(app_version=""),
    ]
    for _ in range(30):
        for body in bad:
            assert post(body)[0] == 400
        assert post(payload(), method="GET")[0] == 405
        assert post(payload(), path="/x")[0] == 404
    assert scan_all(ddb_table) == []
    for _ in range(report.INSTALL_DAILY_LIMIT):
        assert post(payload())[0] == 202


def test_validation_runs_before_salt_and_dynamodb(no_ddb, monkeypatch):
    monkeypatch.delenv("IP_HASH_SALT")
    monkeypatch.delenv("TABLE_NAME")
    assert post(payload(app_version=""))[:2] == (400, {"error": "app_version"})


# --- AC-11: no AWS credentials ------------------------------------------------


def test_tests_use_dummy_aws_environment():
    # Outside mock_aws: the autouse fixture's dummy values, never a real
    # profile or credentials file.
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    assert creds.access_key == "testing"
    assert creds.secret_key == "testing"
    assert boto3.Session().profile_name == "default"
    assert boto3.Session().region_name == "us-east-1"


def test_handler_client_is_created_inside_moto(ddb_table):
    assert report._client is None
    client = report._dynamodb()
    assert client.meta.region_name == "us-east-1"
    assert client.meta.endpoint_url == "https://dynamodb.us-east-1.amazonaws.com"
    # The request is served by moto: the table exists only in memory.
    assert client.describe_table(TableName="reports")["Table"]["TableName"] == (
        "reports"
    )


# --- Transaction conflicts and errors that propagate --------------------------


def _cancelled(*codes):
    return ClientError(
        {
            "Error": {"Code": "TransactionCanceledException", "Message": "x"},
            "CancellationReasons": [{"Code": c} for c in codes],
        },
        "TransactWriteItems",
    )


class StubClient:
    """A DynamoDB client whose ``transact_write_items`` follows a script."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def transact_write_items(self, TransactItems):
        self.calls.append(TransactItems)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return {}


@pytest.fixture
def stub(monkeypatch):
    sleeps = []
    monkeypatch.setattr(report.time, "sleep", sleeps.append)

    def install(*outcomes):
        client = StubClient(*outcomes)
        client.sleeps = sleeps
        monkeypatch.setattr(report, "_client", client)
        return client

    return install


def test_one_conflict_is_retried_with_the_same_items(stub):
    client = stub(_cancelled("None", "TransactionConflict", "None"), None)
    assert post(payload())[:2] == (202, {})
    assert len(client.calls) == 2
    assert client.calls[0] is client.calls[1]
    assert len(client.sleeps) == 1
    assert 0 <= client.sleeps[0] <= 0.1


def test_two_conflicts_are_429(stub):
    conflict = _cancelled("TransactionConflict", "None", "None")
    client = stub(conflict, conflict)
    assert post(payload())[:2] == (429, {"error": "rate_limited"})
    assert len(client.calls) == 2
    assert len(client.sleeps) == 1


@pytest.mark.parametrize(
    "codes",
    [
        ("ConditionalCheckFailed", "TransactionConflict", "None"),
        ("TransactionConflict", "ConditionalCheckFailed", "None"),
    ],
)
def test_limit_reached_wins_over_conflict(stub, codes):
    client = stub(_cancelled(*codes))
    assert post(payload())[0] == 429
    assert len(client.calls) == 1


def test_failed_report_put_propagates(stub):
    stub(_cancelled("None", "None", "ConditionalCheckFailed"))
    with pytest.raises(ClientError):
        post(payload())


@pytest.mark.parametrize(
    "error",
    [
        _cancelled("None", "None", "ValidationError"),
        _cancelled(),
        ClientError(
            {"Error": {"Code": "ProvisionedThroughputExceededException"}},
            "TransactWriteItems",
        ),
        ClientError(
            {"Error": {"Code": "ResourceNotFoundException"}}, "TransactWriteItems"
        ),
        RuntimeError("network"),
    ],
)
def test_other_errors_propagate(stub, error):
    client = stub(error)
    with pytest.raises(type(error)):
        post(payload())
    assert len(client.calls) == 1


def test_missing_table_propagates(ddb_table, monkeypatch):
    monkeypatch.setenv("TABLE_NAME", "no-such-table")
    with pytest.raises(ClientError):
        post(payload())


@pytest.mark.parametrize("value", [None, ""])
def test_missing_salt_propagates_without_writing(ddb_table, monkeypatch, value):
    if value is None:
        monkeypatch.delenv("IP_HASH_SALT")
    else:
        monkeypatch.setenv("IP_HASH_SALT", value)
    with pytest.raises(RuntimeError, match="IP_HASH_SALT"):
        post(payload())
    assert scan_all(ddb_table) == []


@pytest.mark.parametrize("ip", ["not-an-ip", "", "203.0.113.1/24"])
def test_invalid_source_ip_propagates_without_writing(ddb_table, ip):
    with pytest.raises(ValueError):
        post(payload(), ip=ip)
    assert scan_all(ddb_table) == []


def test_dynamodb_client_is_cached(ddb_table):
    assert report._dynamodb() is report._dynamodb()


def test_handler_reads_table_name_at_call_time(ddb_table, monkeypatch):
    # Table name is not cached: a later change in the environment is honoured.
    monkeypatch.setenv("TABLE_NAME", "other")
    with pytest.raises(ClientError):
        post(payload())
    monkeypatch.setenv("TABLE_NAME", "reports")
    assert post(payload())[0] == 202


def test_clock_crossing_keeps_counters_apart(ddb_table, clock):
    assert post(payload())[0] == 202
    clock.now = FIXED_NOW + timedelta(days=1)
    assert post(payload())[0] == 202
    assert sorted(counters(ddb_table)) == sorted(
        [
            f"RL#I#{INSTALL_ID}#2026-10-06",
            f"RL#I#{INSTALL_ID}#2026-10-07",
            f"RL#A#{expected_hmac('ip:' + SOURCE_IP)}#2026-10-06T12",
            f"RL#A#{expected_hmac('ip:' + SOURCE_IP)}#2026-10-07T12",
        ]
    )
