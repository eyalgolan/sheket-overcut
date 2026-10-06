"""Tests for ``sheket.aggregate``: the pure blocklist builder.

The binding definition is spec section 6 (``docs/spec.md``): 6.1 for the
document and its ``version``, 6.3 for the publication rule and the
``force_block`` / ``never_block`` overrides. ``contract/`` holds the acceptance
documents, read here only through the ``conftest.py`` fixtures and never
written. Comments name the acceptance criterion of issue #4 each block covers.
"""

import copy
import importlib.util
import json
import logging
import random
from datetime import datetime, timedelta, timezone

import pytest
from jsonschema import Draft202012Validator, FormatChecker, ValidationError

from sheket import aggregate
from sheket.aggregate import (
    WINDOW,
    build_blocklist,
    serialize_blocklist,
    validate_blocklist,
)

NOW = 1791201600  # 2026-10-05T12:00:00Z
KEY_ORDER = [
    "schema",
    "version",
    "generated_at",
    "call_numbers",
    "call_prefixes",
    "sms_senders",
    "sms_keywords",
    "sms_allow_senders",
]
CALL = "+972555001234"
CALL_2 = "+972555009876"
SMS = "examplelist"


@pytest.fixture(scope="session")
def schema(contract_loader):
    return contract_loader("blocklist.schema.json")


@pytest.fixture(scope="session")
def seed_text(contract_dir):
    return (contract_dir / "seed-blocklist.json").read_text(encoding="utf-8")


def ts(seconds_ago=0, now=NOW):
    """RFC 3339 UTC ``received_at`` for ``seconds_ago`` before ``now``."""
    return (
        datetime.fromtimestamp(now - seconds_ago, timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def report(sender=CALL, install="i1", net="n1", kind="call", received_at=None):
    return {
        "kind": kind,
        "sender": sender,
        "install_id": install,
        "net_hash": net,
        "received_at": ts() if received_at is None else received_at,
    }


def build(curated, reports=(), overrides=(), now=NOW, previous_version=0, **kw):
    return build_blocklist(
        curated,
        list(reports),
        list(overrides),
        now,
        previous_version,
        kw.get("min_installs", 3),
        kw.get("min_networks", 2),
    )


def three_on_two(sender=CALL, kind="call"):
    """Three distinct installs on two distinct networks: the spec threshold."""
    return [
        report(sender, "i1", "n1", kind),
        report(sender, "i2", "n1", kind),
        report(sender, "i3", "n2", kind),
    ]


# --- AC-1 / AC-2: publication rule and its boundaries --------------------------


def test_three_installs_on_two_networks_publish(curated):
    doc = build(curated, three_on_two())
    assert doc["call_numbers"] == [CALL]


def test_two_installs_do_not_publish(curated):
    reports = [report(install="i1", net="n1"), report(install="i2", net="n2")]
    assert build(curated, reports)["call_numbers"] == []


def test_three_installs_on_one_network_do_not_publish(curated):
    reports = [report(install=i, net="n1") for i in ("i1", "i2", "i3")]
    assert build(curated, reports)["call_numbers"] == []


def test_one_install_reporting_many_times_counts_once(curated):
    # i1 reports ten times from two networks; with i2 that is still 2 installs.
    reports = [report(install="i1", net=f"n{k % 2}") for k in range(10)]
    reports.append(report(install="i2", net="n0"))
    assert build(curated, reports)["call_numbers"] == []
    # A third distinct install crosses the threshold.
    reports.append(report(install="i3", net="n0"))
    assert build(curated, reports)["call_numbers"] == [CALL]


def test_report_older_than_seven_days_does_not_count(curated):
    old = WINDOW.total_seconds() + 1
    reports = three_on_two()
    reports[2]["received_at"] = ts(old)
    assert build(curated, reports)["call_numbers"] == []


def test_report_exactly_seven_days_old_counts(curated):
    reports = three_on_two()
    reports[2]["received_at"] = ts(WINDOW.total_seconds())
    assert build(curated, reports)["call_numbers"] == [CALL]


def test_window_is_seven_days():
    assert WINDOW == timedelta(days=7)


def test_received_at_offsets_and_naive_timestamps_are_compared_in_utc(curated):
    # 2 hours before NOW written with a +02:00 offset is NOW - 2h in UTC
    # (counts); a naive timestamp is read as UTC.
    within = datetime.fromtimestamp(NOW - 7200, timezone(timedelta(hours=2)))
    reports = three_on_two()
    reports[0]["received_at"] = within.isoformat()
    reports[1]["received_at"] = "2026-10-05T11:00:00"
    assert build(curated, reports)["call_numbers"] == [CALL]


@pytest.mark.parametrize(
    ("min_installs", "min_networks", "published"),
    [(1, 1, True), (3, 2, True), (3, 3, False), (4, 2, False), (2, 1, True)],
)
def test_thresholds_are_parameters(curated, min_installs, min_networks, published):
    doc = build(
        curated,
        three_on_two(),
        min_installs=min_installs,
        min_networks=min_networks,
    )
    assert doc["call_numbers"] == ([CALL] if published else [])


def test_groups_are_counted_per_sender(curated):
    # Three installs on two networks, but split across two senders.
    reports = [
        report(CALL, "i1", "n1"),
        report(CALL, "i2", "n2"),
        report(CALL_2, "i3", "n1"),
    ]
    assert build(curated, reports)["call_numbers"] == []


def test_kinds_are_published_separately(curated):
    # Provisional answer to owner Decision 1: sms reports publish only to
    # sms_senders and call reports only to call_numbers, even for one number.
    sms_doc = build(curated, three_on_two(CALL, kind="sms"))
    assert sms_doc["sms_senders"] == [CALL]
    assert sms_doc["call_numbers"] == []

    call_doc = build(curated, three_on_two(CALL, kind="call"))
    assert call_doc["call_numbers"] == [CALL]
    assert call_doc["sms_senders"] == []


def test_call_and_sms_reports_are_not_pooled(curated):
    reports = [
        report(CALL, "i1", "n1", "call"),
        report(CALL, "i2", "n2", "call"),
        report(CALL, "i3", "n1", "sms"),
    ]
    doc = build(curated, reports)
    assert doc["call_numbers"] == []
    assert doc["sms_senders"] == []


def test_sms_sender_id_is_published(curated):
    assert build(curated, three_on_two(SMS, kind="sms"))["sms_senders"] == [SMS]


def test_curated_never_block_blocks_publication(curated):
    protected = "clalit"
    assert protected in curated["never_block"]
    doc = build(curated, three_on_two(protected, kind="sms"))
    assert protected not in doc["sms_senders"]


# --- Malformed reports are skipped, not fatal ----------------------------------


@pytest.mark.parametrize(
    "bad",
    [
        "not a dict",
        None,
        {},
        {**report(), "kind": "fax"},
        {**report(), "kind": None},
        {**report(), "sender": ""},
        {**report(), "sender": 972555001234},
        {**report(), "install_id": None},
        {k: v for k, v in report().items() if k != "net_hash"},
        {**report(), "received_at": "yesterday"},
        {**report(), "received_at": 1791201600},
        {**report(), "sender": "100"},  # call report, not E.164
        {**report(), "sender": "exampleparty"},  # call report, not E.164
    ],
    ids=repr,
)
def test_malformed_report_is_skipped_with_error_log(curated, schema, caplog, bad):
    caplog.set_level(logging.ERROR, logger="sheket.aggregate")
    doc = build(curated, [bad, *three_on_two(CALL_2)])
    assert doc["call_numbers"] == [CALL_2]
    validate_blocklist(doc, schema)
    errors = [r for r in caplog.records if r.levelno == logging.ERROR]
    assert len(errors) == 1


def test_malformed_report_cannot_be_counted_towards_threshold(curated):
    reports = three_on_two()
    reports[2]["received_at"] = "garbage"
    assert build(curated, reports)["call_numbers"] == []


def test_report_logs_never_carry_sender_install_or_network(curated, caplog):
    caplog.set_level(logging.DEBUG, logger="sheket.aggregate")
    secret = "+972555007777"
    reports = [
        {**report(secret, "install-secret", "net-secret"), "received_at": "x"},
        {**report("Secret-Id", "install-secret", "net-secret"), "kind": "call"},
        {**report(secret, "install-secret", "net-secret"), "kind": "fax"},
        {**report(secret, "install-secret", "net-secret"), "install_id": ""},
    ]
    build(curated, reports)
    assert len(caplog.records) == len(reports)
    for rec in caplog.records:
        text = rec.getMessage()
        for value in (secret, "Secret-Id", "install-secret", "net-secret"):
            assert value not in text


# --- AC-3 / AC-4: overrides ----------------------------------------------------


def test_force_block_adds_call_and_sms_senders_without_reports(curated):
    overrides = [
        {"sk": f"force_block#call#{CALL}"},
        {"sk": "force_block#sms#ExampleParty"},
    ]
    doc = build(curated, overrides=overrides)
    assert doc["call_numbers"] == [CALL]
    assert doc["sms_senders"] == ["exampleparty"]


def test_force_block_sender_is_normalised(curated):
    overrides = [
        {"sk": "force_block#call#055-500-1234"},
        {"sk": "force_block#sms#  ExampleList  "},
    ]
    doc = build(curated, overrides=overrides)
    assert doc["call_numbers"] == [CALL]
    assert doc["sms_senders"] == [SMS]


def test_force_block_sender_keeps_hash(curated):
    doc = build(curated, overrides=[{"sk": "force_block#sms#A#B"}])
    assert doc["sms_senders"] == ["a#b"]


def test_never_block_removes_published_sender(curated):
    doc = build(curated, three_on_two(), [{"sk": f"never_block#{CALL}"}])
    assert doc["call_numbers"] == []


def test_never_block_wins_over_force_block(curated):
    overrides = [
        {"sk": f"force_block#call#{CALL}"},
        {"sk": "never_block#0555001234"},  # same number, other spelling
        {"sk": "force_block#sms#ExampleList"},
        {"sk": "never_block#EXAMPLELIST"},
    ]
    doc = build(curated, three_on_two(), overrides)
    assert doc["call_numbers"] == []
    assert doc["sms_senders"] == []


def test_never_block_removes_curated_entries(curated):
    custom = copy.deepcopy(curated)
    custom["call_numbers"] = [CALL, CALL_2]
    custom["sms_senders"] = [SMS, "exampleparty"]
    overrides = [{"sk": f"never_block#{CALL}"}, {"sk": "never_block#ExampleParty"}]
    doc = build(custom, overrides=overrides)
    assert doc["call_numbers"] == [CALL_2]
    assert doc["sms_senders"] == [SMS]


def test_curated_never_block_wins_over_force_block(curated):
    assert "clalit" in curated["never_block"]
    doc = build(curated, overrides=[{"sk": "force_block#sms#Clalit"}])
    assert "clalit" not in doc["sms_senders"]


def test_never_set_is_curated_never_block_united_with_overrides(curated):
    force, sms, never = aggregate._parse_overrides(
        curated["never_block"], [{"sk": "never_block#Some-Bank"}]
    )
    assert force == sms == set()
    assert never == set(curated["never_block"]) | {"some-bank"}


def test_never_block_does_not_touch_curated_only_lists(curated):
    # Every curated allow sender is also in never_block; the allow list must
    # survive, and so must keywords and prefixes.
    assert set(curated["sms_allow_senders"]) <= set(curated["never_block"])
    custom = copy.deepcopy(curated)
    custom["call_prefixes"] = ["+97255501"]
    doc = build(custom, overrides=[{"sk": "never_block#+97255501"}])
    assert doc["sms_allow_senders"] == sorted(curated["sms_allow_senders"])
    assert doc["call_prefixes"] == ["+97255501"]


@pytest.mark.parametrize(
    "bad",
    [
        "not a dict",
        None,
        {},
        {"pk": "override"},
        {"sk": 42},
        {"sk": ""},
        {"sk": "allow#x"},
        {"sk": "force_block"},
        {"sk": "force_block#"},
        {"sk": "force_block#call"},
        {"sk": "force_block#call#"},
        {"sk": "force_block#fax#x"},
        {"sk": "force_block#sms#   "},
        {"sk": "force_block#sms#" + "x" * 21},  # sender ID too long
        {"sk": "force_block#call#100"},  # short number, not E.164
        {"sk": "force_block#call#*2700"},
        {"sk": "force_block#call#ExampleParty"},
        {"sk": "force_block#call#00972555001234"},
        {"sk": "never_block"},
        {"sk": "never_block#"},
        {"sk": "never_block#two words"},
    ],
    ids=repr,
)
def test_invalid_override_is_skipped_with_error_log(curated, schema, caplog, bad):
    caplog.set_level(logging.ERROR, logger="sheket.aggregate")
    good = {"sk": f"force_block#call#{CALL_2}"}
    doc = build(curated, overrides=[bad, good])
    assert doc["call_numbers"] == [CALL_2]
    assert doc["sms_senders"] == []
    validate_blocklist(doc, schema)
    errors = [r for r in caplog.records if r.levelno == logging.ERROR]
    assert len(errors) == 1


def test_invalid_never_block_override_does_not_remove_anything(curated):
    doc = build(curated, three_on_two(), [{"sk": "never_block#   "}])
    assert doc["call_numbers"] == [CALL]


# --- AC-5 / AC-9: shape, key order, sorting, seed ------------------------------


def test_output_key_order_and_no_never_block(curated):
    doc = build(curated, three_on_two(), [{"sk": "never_block#x"}])
    assert list(doc) == KEY_ORDER
    assert "never_block" not in doc
    assert "never_block" not in serialize_blocklist(doc)


def test_empty_build_equals_seed_byte_for_byte_apart_from_version(curated, seed_text):
    doc = build(curated, now=NOW + 12345)
    seed = json.loads(seed_text)
    assert doc["version"] != seed["version"]
    doc["version"] = seed["version"]
    doc["generated_at"] = seed["generated_at"]
    assert serialize_blocklist(doc) == seed_text


def test_build_at_seed_version_reproduces_seed_exactly(curated, seed_text):
    seed = json.loads(seed_text)
    doc = build(curated, now=seed["version"])
    assert serialize_blocklist(doc) == seed_text
    assert serialize_blocklist(doc).encode("utf-8") == seed_text.encode("utf-8")


def test_lists_are_sorted(curated):
    custom = copy.deepcopy(curated)
    custom["call_prefixes"] = ["+9725552", "+97255501"]
    custom["sms_allow_senders"] = ["zeta", "alpha", "mid"]
    custom["sms_keywords"] = [
        {"text": "b", "strength": "weak"},
        {"text": "a", "strength": "strong"},
    ]
    overrides = [
        {"sk": f"force_block#call#{CALL_2}"},
        {"sk": f"force_block#call#{CALL}"},
        {"sk": "force_block#sms#Zed"},
        {"sk": "force_block#sms#Abc"},
    ]
    doc = build(custom, overrides=overrides)
    assert doc["call_numbers"] == [CALL, CALL_2]
    assert doc["call_prefixes"] == ["+97255501", "+9725552"]
    assert doc["sms_senders"] == ["abc", "zed"]
    assert [k["text"] for k in doc["sms_keywords"]] == ["a", "b"]
    assert doc["sms_allow_senders"] == ["alpha", "mid", "zeta"]


def test_serialisation_format():
    doc = {"schema": 1, "text": "קלפי"}
    assert (
        serialize_blocklist(doc) == json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    )
    assert serialize_blocklist(doc).endswith("}\n")
    assert "קלפי" in serialize_blocklist(doc)  # not \u-escaped


def test_output_is_deterministic_regardless_of_input_order(curated):
    reports = three_on_two() + three_on_two(SMS, "sms")
    overrides = [
        {"sk": f"force_block#call#{CALL_2}"},
        {"sk": "force_block#sms#ExampleParty"},
        {"sk": "never_block#100"},
    ]
    first = serialize_blocklist(build(curated, reports, overrides))
    rng = random.Random(4)
    for _ in range(5):
        rng.shuffle(reports)
        rng.shuffle(overrides)
        assert serialize_blocklist(build(curated, reports, overrides)) == first


def test_inputs_are_not_mutated(curated):
    custom = copy.deepcopy(curated)
    reports = three_on_two() + [{"kind": "fax"}]
    overrides = [{"sk": f"force_block#call#{CALL_2}"}, {"sk": "never_block#x"}]
    before = copy.deepcopy((custom, reports, overrides))
    doc = build(custom, reports, overrides)
    assert (custom, reports, overrides) == before
    for key in ("call_prefixes", "sms_keywords", "sms_allow_senders"):
        assert doc[key] is not custom[key]
    assert all(a is not b for a, b in zip(doc["sms_keywords"], custom["sms_keywords"]))


def test_reports_may_be_a_one_shot_iterable(curated):
    doc = build_blocklist(curated, iter(three_on_two()), iter([]), NOW, 0, 3, 2)
    assert doc["call_numbers"] == [CALL]


# --- AC-10 / AC-11: version and generated_at -----------------------------------


@pytest.mark.parametrize(
    ("now", "previous", "expected"),
    [
        (NOW, 0, NOW),
        (NOW, NOW - 1, NOW),
        (NOW, NOW, NOW + 1),  # same second: still increases
        (NOW, NOW + 500, NOW + 501),  # clock behind the previous list
        (NOW + 0.9, 0, NOW),  # float now is truncated
    ],
)
def test_version_only_increases(curated, now, previous, expected):
    doc = build(curated, now=now, previous_version=previous)
    assert doc["version"] == expected
    assert isinstance(doc["version"], int)
    assert doc["version"] > previous


def test_consecutive_builds_have_increasing_versions(curated):
    version = 0
    for _ in range(3):
        version_next = build(curated, previous_version=version)["version"]
        assert version_next > version
        version = version_next


@pytest.mark.parametrize(
    ("version", "expected"),
    [
        (NOW, "2026-10-05T12:00:00Z"),
        (1791149668, "2026-10-04T21:34:28Z"),
        (1, "1970-01-01T00:00:01Z"),
    ],
)
def test_generated_at_is_version_as_rfc3339_utc(curated, version, expected):
    doc = build(curated, now=version)
    assert doc["version"] == version
    assert doc["generated_at"] == expected


def test_generated_at_follows_bumped_version(curated):
    doc = build(curated, now=NOW, previous_version=NOW)
    assert doc["generated_at"] == "2026-10-05T12:00:01Z"


# --- AC-6 / AC-7 / AC-8: schema validation with format checking ----------------


def test_format_checker_checks_date_time():
    assert "date-time" in FormatChecker.checkers
    checker = FormatChecker()
    assert checker.conforms("2026-10-05T12:00:00Z", "date-time")
    assert not checker.conforms("2026-10-05 noon", "date-time")
    assert not checker.conforms("2026-13-05T12:00:00Z", "date-time")


def test_bad_generated_at_fails_validation(contract_loader, schema):
    doc = contract_loader("test-blocklist.json")
    doc = {**doc, "generated_at": "not a date"}
    with pytest.raises(ValidationError) as exc:
        validate_blocklist(doc, schema)
    assert exc.value.validator == "format"


def test_test_blocklist_validates_with_format_checking(contract_loader, schema):
    doc = contract_loader("test-blocklist.json")
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    assert list(validator.iter_errors(doc)) == []
    validate_blocklist(doc, schema)


def test_seed_blocklist_validates_with_format_checking(contract_loader, schema):
    validate_blocklist(contract_loader("seed-blocklist.json"), schema)


@pytest.mark.parametrize(
    "case",
    ["empty", "published", "forced", "never", "bumped", "mixed"],
)
def test_every_output_validates(curated, schema, case):
    reports, overrides, previous = [], [], 0
    if case in ("published", "mixed"):
        reports = three_on_two() + three_on_two(SMS, "sms")
    if case in ("forced", "mixed"):
        overrides += [
            {"sk": f"force_block#call#{CALL_2}"},
            {"sk": "force_block#sms#ExampleParty"},
            {"sk": "force_block#sms#*2700"},
        ]
    if case in ("never", "mixed"):
        overrides += [{"sk": f"never_block#{CALL}"}, {"sk": "bogus"}]
        reports = reports or three_on_two()
    if case == "bumped":
        previous = NOW + 10**6
    doc = build(curated, reports, overrides, previous_version=previous)
    validate_blocklist(doc, schema)
    validate_blocklist(json.loads(serialize_blocklist(doc)), schema)


@pytest.mark.parametrize(
    "mutate",
    [
        lambda d: d.update(never_block=[]),  # additionalProperties: false
        lambda d: d.update(schema=2),
        lambda d: d.update(version="1"),
        lambda d: d["call_numbers"].append("0555001234"),
        lambda d: d["sms_senders"].append(""),
    ],
    ids=["never_block-key", "schema-2", "version-str", "bad-call", "empty-sender"],
)
def test_invalid_documents_are_rejected(curated, schema, mutate):
    doc = build(curated)
    mutate(doc)
    with pytest.raises(ValidationError):
        validate_blocklist(doc, schema)


def test_import_fails_without_date_time_checker(monkeypatch):
    # Load a fresh copy of the module with date-time checking removed: the
    # import-time guard must refuse to load (contract/README.md, Schema notes).
    monkeypatch.delitem(FormatChecker.checkers, "date-time")
    spec = importlib.util.spec_from_file_location(
        "sheket._aggregate_guard_probe", aggregate.__file__
    )
    module = importlib.util.module_from_spec(spec)
    with pytest.raises(RuntimeError, match="rfc3339-validator"):
        spec.loader.exec_module(module)
