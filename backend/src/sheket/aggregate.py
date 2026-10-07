"""Blocklist builder and aggregate Lambda handler.

The binding definition is spec section 6 (``docs/spec.md``): section 6.1
defines the blocklist document, whose ``version`` only increases, and section
6.3 the publication rule and the ``force_block`` / ``never_block`` overrides.
The structure follows design Phase 3 (the design comment on issue #1).
``contract/README.md`` (Schema notes) explains why ``date-time`` format
checking needs the ``rfc3339-validator`` package.

The builder (``build_blocklist``, ``validate_blocklist``,
``serialize_blocklist``) is pure: no AWS and no I/O. The Lambda handler, entry
point ``sheket.aggregate.handler``, runs on a schedule. It reads the last
7 days of reports and the ``OVERRIDE`` items from DynamoDB and the previous
``v1/blocklist.json`` from S3, then builds -> validates -> serialises. It
writes only when the content changed or the forced refresh is due, and prints
one EMF ``AggregateSucceeded`` line per successful run. The contract files are
loaded at call time from the packaged ``sheket/contract/`` next to this module
(design Phase 3.3).

Provisional values, named here in one place:

- The 6-hour forced refresh (``FORCED_REFRESH``) is the design's provisional
  answer to open owner Decision 5: whether apps measure "list more than 24
  hours old" from ``generated_at`` or from their last successful check.
  Android PR #42 measures from the last successful check; if that is
  confirmed, drop it.

Configuration comes from the environment, read at call time, never at import:

- ``TABLE_NAME``: the DynamoDB table name.
- ``BUCKET_NAME``: the S3 bucket holding ``v1/blocklist.json``.
- ``MIN_INSTALLS``, ``MIN_NETWORKS``: the spec 6.3 publication thresholds,
  wired by Terraform variables. Each must be a base-10 integer >= 1.
"""

import json
import logging
import os
import re
import time
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import NamedTuple

import boto3
from botocore.exceptions import ClientError
from jsonschema import Draft202012Validator, FormatChecker

from sheket.normalize import is_e164, normalize_sender

# Fixed by spec 6.3 ("within the last 7 days"); not a parameter.
WINDOW = timedelta(days=7)
SCHEMA_VERSION = 1
KINDS = ("call", "sms")

BLOCKLIST_KEY = "v1/blocklist.json"
CONTENT_TYPE = "application/json; charset=utf-8"
# Spec 5: the CDN cache TTL is 5 minutes.
CACHE_CONTROL = "public, max-age=300"
OVERRIDE_PK = "OVERRIDE"
# Packaged location (design 3.3). A module attribute so tests can point it at
# the repository's contract/.
CONTRACT_DIR = Path(__file__).parent / "contract"
# Provisional answer to open owner Decision 5; remove together with the age
# check in `_should_write` if apps measure staleness from their last
# successful check.
FORCED_REFRESH = timedelta(hours=6)
# The largest previous version whose `version + 1` still converts in
# `_generated_at`: 253402300799 is 9999-12-31T23:59:59Z, the last second
# `datetime` can represent.
MAX_VERSION = (
    int(datetime(9999, 12, 31, 23, 59, 59, tzinfo=timezone.utc).timestamp()) - 1
)
# EMF heartbeat (`_emit_success`); the stale-list alarm (#8) watches it.
METRIC_NAMESPACE = "Sheket"
FUNCTION_NAME = "aggregate"
# Use with fullmatch only: an anchoring "$" would accept a trailing newline.
_THRESHOLD = re.compile(r"[0-9]+")

logger = logging.getLogger(__name__)
# The Lambda runtime's root logger level would otherwise hide INFO records.
logger.setLevel(logging.INFO)

_ddb_client = None
_s3_client = None

# Without rfc3339-validator, jsonschema silently skips the date-time check on
# generated_at (contract/README.md, Schema notes). An explicit raise, not an
# assert, so the guard survives ``python -O``.
if "date-time" not in FormatChecker.checkers:
    raise RuntimeError(
        "date-time format checking is unavailable: install rfc3339-validator "
        "(see contract/README.md, Schema notes)"
    )


def _dynamodb():
    """Return the DynamoDB client, created on first use.

    The region comes from the environment. Tests reset ``_ddb_client`` to None.
    """
    global _ddb_client
    if _ddb_client is None:
        _ddb_client = boto3.client("dynamodb")
    return _ddb_client


def _s3():
    """Return the S3 client, created on first use.

    The region comes from the environment. Tests reset ``_s3_client`` to None.
    """
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


def _now() -> int:
    """Return the current time in Unix seconds.

    The single clock source for the module: called once per run, and patched
    by tests.
    """
    return int(time.time())


class _Config(NamedTuple):
    table: str
    bucket: str
    min_installs: int
    min_networks: int


def _threshold(name: str) -> int:
    """Return environment variable ``name`` as a base-10 integer >= 1.

    Only ASCII digits are accepted (no sign, no whitespace, no underscores),
    so a typo fails loudly instead of being coerced. A missing variable raises
    KeyError; any other bad value raises ValueError naming the variable.
    """
    raw = os.environ[name]
    if not _THRESHOLD.fullmatch(raw) or int(raw) < 1:
        raise ValueError(f"{name} must be a base-10 integer >= 1")
    return int(raw)


def _config() -> _Config:
    """Read the configuration from the environment on every call.

    A missing variable raises KeyError and a bad threshold raises ValueError,
    so the run fails loudly and the previous blocklist stays in place.
    """
    return _Config(
        table=os.environ["TABLE_NAME"],
        bucket=os.environ["BUCKET_NAME"],
        min_installs=_threshold("MIN_INSTALLS"),
        min_networks=_threshold("MIN_NETWORKS"),
    )


def _load_contract() -> tuple[dict, dict]:
    """Load ``(curated, schema)`` from ``CONTRACT_DIR`` as UTF-8 JSON.

    Read at call time, not at import, so tests can point ``CONTRACT_DIR`` at
    the repository's ``contract/``.
    """
    curated = json.loads((CONTRACT_DIR / "curated.json").read_text(encoding="utf-8"))
    schema = json.loads(
        (CONTRACT_DIR / "blocklist.schema.json").read_text(encoding="utf-8")
    )
    return curated, schema


def _parse_overrides(
    curated_never: Iterable[str], overrides: Iterable[object]
) -> tuple[set[str], set[str], set[str]]:
    """Parse operator override items; return ``(force_call, force_sms, never)``.

    Only ``item.get("sk")`` is read. Two forms are accepted (spec 6.3):
    ``force_block#<kind>#<sender>`` and ``never_block#<sender>``. The sender
    is the rest of the key, so a ``#`` inside it is preserved, and it is
    normalised with ``normalize_sender``. A ``force_block#call`` sender must
    also be E.164. A malformed item is logged and skipped, never raised, so
    one bad override cannot stop the blocklist from being built. The skip log
    carries only the reason, the key prefix and a known kind, never the key
    or the sender.

    ``curated_never`` holds the ``never_block`` values from
    ``contract/curated.json``, which are already normalised; they are merged
    into ``never`` as they are.
    """
    force_call: set[str] = set()
    force_sms: set[str] = set()
    never_overrides: set[str] = set()

    for item in overrides:
        sk = item.get("sk") if isinstance(item, dict) else None
        if not isinstance(sk, str):
            logger.error(
                "override skipped: missing or non-str sk (type=%s)", type(sk).__name__
            )
            continue

        if sk.startswith("force_block#"):
            parts = sk.split("#", 2)
            if len(parts) != 3 or not parts[2]:
                logger.error("override skipped: malformed key (prefix=force_block)")
                continue
            _, kind, raw = parts
            if kind not in KINDS:
                logger.error("override skipped: unknown kind (prefix=force_block)")
                continue
            sender = normalize_sender(raw)
            if sender is None:
                logger.error(
                    "override skipped: sender does not normalise "
                    "(prefix=force_block, kind=%s)",
                    kind,
                )
                continue
            if kind == "call":
                if not is_e164(sender):
                    logger.error(
                        "override skipped: sender not E.164 "
                        "(prefix=force_block, kind=call)"
                    )
                    continue
                force_call.add(sender)
            else:
                force_sms.add(sender)
        elif sk.startswith("never_block#"):
            parts = sk.split("#", 1)
            if len(parts) != 2 or not parts[1]:
                logger.error("override skipped: malformed key (prefix=never_block)")
                continue
            sender = normalize_sender(parts[1])
            if sender is None:
                logger.error(
                    "override skipped: sender does not normalise (prefix=never_block)"
                )
                continue
            never_overrides.add(sender)
        else:
            logger.error("override skipped: unknown key prefix")

    never = set(curated_never) | never_overrides
    return force_call, force_sms, never


_REPORT_FIELDS = ("kind", "sender", "install_id", "net_hash", "received_at")


def _published(
    reports: Iterable[object], now: int, min_installs: int, min_networks: int
) -> tuple[set[str], set[str]]:
    """Apply the publication rule (spec 6.3); return ``(call_set, sms_set)``.

    A report counts only if its ``received_at`` lies in ``[now - WINDOW,
    now]`` (``now`` in Unix seconds, both ends inclusive); a naive timestamp
    is treated as UTC. A report dated after ``now`` is logged and skipped, so
    it cannot keep counting until the clock catches up with it. The sender
    is normalised with ``normalize_sender`` first, so spelling variants
    (``Clalit``, ``CLALIT``) form one group and match ``never_block``; a
    ``call`` sender must also be E.164 after normalising. Reports are
    grouped by ``(kind, sender)``, and a group is published when it has at
    least ``min_installs`` distinct ``install_id`` values and at least
    ``min_networks`` distinct ``net_hash`` values, so one install reporting
    many times counts once.

    A malformed report is logged and skipped, never raised. Logs carry only
    the reason and the kind, never the sender, install ID or network hash.
    """
    now_dt = datetime.fromtimestamp(now, timezone.utc)
    cutoff = now_dt - WINDOW
    installs: dict[tuple[str, str], set[str]] = {}
    nets: dict[tuple[str, str], set[str]] = {}

    for report in reports:
        if not isinstance(report, dict):
            logger.error("report skipped: not a dict")
            continue
        kind = report.get("kind")
        safe_kind = kind if kind in KINDS else None
        bad = next(
            (
                f
                for f in _REPORT_FIELDS
                if not isinstance(report.get(f), str) or not report.get(f)
            ),
            None,
        )
        if bad is not None:
            logger.error(
                "report skipped: missing or invalid %s (kind=%r)", bad, safe_kind
            )
            continue
        if kind not in KINDS:
            logger.error("report skipped: unknown kind")
            continue
        try:
            received = datetime.fromisoformat(report["received_at"])
        except ValueError:
            logger.error("report skipped: unparsable received_at (kind=%r)", kind)
            continue
        if received.tzinfo is None:
            received = received.replace(tzinfo=timezone.utc)
        sender = normalize_sender(report["sender"])
        if sender is None:
            logger.error("report skipped: sender does not normalise (kind=%r)", kind)
            continue
        if kind == "call" and not is_e164(sender):
            logger.error("report skipped: sender not E.164 (kind=%r)", kind)
            continue
        if received > now_dt:
            logger.error("report skipped: received_at in the future (kind=%r)", kind)
            continue
        if received < cutoff:
            continue
        key = (kind, sender)
        installs.setdefault(key, set()).add(report["install_id"])
        nets.setdefault(key, set()).add(report["net_hash"])

    call_set: set[str] = set()
    sms_set: set[str] = set()
    for key, ids in installs.items():
        if len(ids) >= min_installs and len(nets[key]) >= min_networks:
            kind, sender = key
            # Provisional answer to open owner Decision 1: kinds stay
            # separate. A call group publishes only to call_set and an sms
            # group only to sms_set.
            (call_set if kind == "call" else sms_set).add(sender)
    return call_set, sms_set


def _generated_at(version: int) -> str:
    """Return ``version`` (Unix seconds) as an RFC 3339 UTC string ending in Z."""
    return datetime.fromtimestamp(version, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_blocklist(
    curated: dict,
    reports: Iterable[object],
    overrides: Iterable[object],
    now: int,
    previous_version: int,
    min_installs: int,
    min_networks: int,
) -> dict:
    """Build a new blocklist document (spec 6.1) from its inputs.

    ``version`` is ``max(now, previous_version + 1)``, so it only ever
    increases (spec 6.1). ``call_numbers`` and ``sms_senders`` are the
    curated entries plus the published senders (spec 6.3 publication rule)
    plus the ``force_block`` overrides, minus every ``never_block`` sender;
    ``never_block`` therefore beats ``force_block`` and also removes curated
    entries (spec 6.3). A curated ``call_prefixes`` entry that covers an
    E.164 ``never_block`` number is dropped, since keeping it would still
    block that number. Lists are sorted so the output is deterministic.

    The inputs are never mutated; every list and dict in the result is new.
    """
    version = max(int(now), int(previous_version) + 1)
    force_call, force_sms, never = _parse_overrides(curated["never_block"], overrides)
    published_call, published_sms = _published(reports, now, min_installs, min_networks)

    call_numbers = sorted(
        (set(curated["call_numbers"]) | published_call | force_call) - never
    )
    sms_senders = sorted(
        (set(curated["sms_senders"]) | published_sms | force_sms) - never
    )

    # A curated prefix that covers a never_block number would keep that number
    # blocked (Android matches by prefix, iOS expands it), so never_block could
    # not "remove one regardless" (spec 6.3, 7). The schema has no per-prefix
    # exception, so the covering prefix is dropped and logged for the
    # operator. Only E.164 entries can sit inside a prefix; short numbers,
    # star codes and sender IDs never match one.
    never_numbers = [n for n in never if is_e164(n)]
    call_prefixes = []
    for prefix in sorted(set(curated["call_prefixes"])):
        if any(n.startswith(prefix) for n in never_numbers):
            logger.error(
                "curated call prefix dropped: it covers a never_block number: %r",
                prefix,
            )
            continue
        call_prefixes.append(prefix)

    # The remaining curated-only lists are taken as they are: never_block is
    # not applied to them. They never block a sender (keywords match text, the
    # allow list exempts senders), and every curated sms_allow_senders entry is
    # also in never_block, so subtracting it would empty the allow list and
    # break the seed blocklist.
    sms_keywords = [
        {"text": k["text"], "strength": k["strength"]}
        for k in sorted(curated["sms_keywords"], key=lambda k: k["text"])
    ]
    sms_allow_senders = sorted(curated["sms_allow_senders"])

    return {
        "schema": SCHEMA_VERSION,
        "version": version,
        "generated_at": _generated_at(version),
        "call_numbers": call_numbers,
        "call_prefixes": call_prefixes,
        "sms_senders": sms_senders,
        "sms_keywords": sms_keywords,
        "sms_allow_senders": sms_allow_senders,
    }


def validate_blocklist(doc: dict, schema: dict) -> None:
    """Validate ``doc`` against the blocklist JSON Schema ``schema``.

    Raises ``jsonschema.SchemaError`` if ``schema`` is not a valid Draft 2020-12
    schema and ``jsonschema.ValidationError`` if ``doc`` does not conform.

    The schema is a parameter rather than loaded at import because the bundled
    ``sheket/contract/`` copy exists only in the Lambda package (design Phase
    3.3). The #6 handler loads it and calls build -> validate -> serialize.

    Format checking is mandatory (``contract/README.md``, Schema notes):
    without a ``FormatChecker`` the ``date-time`` format of ``generated_at``
    would not be checked at all.
    """
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(doc)


def serialize_blocklist(doc: dict) -> str:
    """Return ``doc`` as UTF-8-ready JSON text with a trailing newline.

    Keys are not sorted: the key order comes from ``build_blocklist`` and must
    match ``contract/seed-blocklist.json`` byte for byte.
    """
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def _query_all(**kwargs) -> list[dict]:
    """Run a DynamoDB query over every page; return the items as plain dicts.

    ``LastEvaluatedKey`` is followed as ``ExclusiveStartKey`` until it is
    absent; the caller's ``kwargs`` are not mutated. Only string (``S``)
    attributes are kept, as ``{name: value}``; any other attribute is dropped,
    so a malformed item reaches the builder with a field missing and is
    logged and skipped there, never raised here.
    """
    params = dict(kwargs)
    items: list[dict] = []
    while True:
        page = _dynamodb().query(**params)
        for raw in page.get("Items", []):
            items.append(
                {
                    name: value["S"]
                    for name, value in raw.items()
                    if isinstance(value, dict) and isinstance(value.get("S"), str)
                }
            )
        last_key = page.get("LastEvaluatedKey")
        if not last_key:
            return items
        params["ExclusiveStartKey"] = last_key


def _load_reports(table: str, now: int) -> list[dict]:
    """Load the reports of the last ``WINDOW`` from their UTC day partitions.

    Reports are stored under ``pk = "R#YYYY-MM-DD"`` with ``sk`` starting with
    ``received_at`` (``sheket.report``). Every day from the cutoff's day to
    ``now``'s day is queried; the oldest partition is narrowed with
    ``sk >= cutoff`` (``now`` is whole seconds, so a report exactly at the
    cutoff is included). This only limits the read: the builder's
    ``received_at`` check stays the exact window filter and also drops
    reports dated after ``now``. Logs carry counts only, never item contents.
    """
    now_dt = datetime.fromtimestamp(now, timezone.utc)
    cutoff = now_dt - WINDOW
    cut = cutoff.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    first_day = cutoff.date()
    last_day = now_dt.date()

    reports: list[dict] = []
    partitions = 0
    day = first_day
    while day <= last_day:
        values = {":pk": {"S": f"R#{day.strftime('%Y-%m-%d')}"}}
        condition = "pk = :pk"
        if day == first_day:
            condition = "pk = :pk AND sk >= :cut"
            values[":cut"] = {"S": cut}
        reports.extend(
            _query_all(
                TableName=table,
                KeyConditionExpression=condition,
                ExpressionAttributeValues=values,
                ProjectionExpression="kind, sender, install_id, net_hash, received_at",
            )
        )
        partitions += 1
        day += timedelta(days=1)

    logger.info("loaded %d reports from %d day partitions", len(reports), partitions)
    return reports


def _load_overrides(table: str) -> list[dict]:
    """Load the operator ``OVERRIDE`` items; only ``sk`` is read (spec 6.3)."""
    return _query_all(
        TableName=table,
        KeyConditionExpression="pk = :o",
        ExpressionAttributeValues={":o": {"S": OVERRIDE_PK}},
        ProjectionExpression="sk",
    )


def _load_previous(bucket: str) -> tuple[dict | None, int]:
    """Read the published ``v1/blocklist.json``; return ``(doc, version)``.

    A missing object (``NoSuchKey``) is the first run and gives ``(None, 0)``;
    any other S3 error propagates, so the run fails and the published
    blocklist stays in place. An object that is not strict UTF-8 JSON holding
    an object, or an object whose ``version`` is not an integer >= 0, also
    gives ``(None, 0)``; both are logged with the reason only, never the
    content. A whole-valued float ``version`` (e.g. ``9999999999.0``, valid
    under the schema) counts as an integer and is returned as an ``int``. A
    ``version`` above ``MAX_VERSION`` is also unusable (logged, giving
    ``(None, 0)``), so the run writes a fresh list at version ``now`` instead
    of failing every run in ``_generated_at``. An unusable previous object
    therefore means the next run always writes, so a malformed published
    document is replaced even when its content compares equal, and
    ``version = max(now, previous_version + 1)`` still keeps the version
    increasing.
    """
    try:
        response = _s3().get_object(Bucket=bucket, Key=BLOCKLIST_KEY)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "NoSuchKey":
            logger.info("no previous blocklist: first run")
            return None, 0
        raise

    body = response["Body"].read()
    try:
        doc = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        logger.error("previous blocklist unusable: %s", type(e).__name__)
        return None, 0
    if not isinstance(doc, dict):
        logger.error(
            "previous blocklist unusable: not a JSON object (type=%s)",
            type(doc).__name__,
        )
        return None, 0

    version = doc.get("version")
    if isinstance(version, float) and version.is_integer() and version >= 0:
        version = int(version)
    if not isinstance(version, int) or isinstance(version, bool) or version < 0:
        logger.error(
            "previous blocklist version invalid (type=%s); using 0",
            type(version).__name__,
        )
        return None, 0
    if version > MAX_VERSION:
        logger.error(
            "previous blocklist version out of range (above %d); using 0", MAX_VERSION
        )
        return None, 0
    return doc, version


def _content(doc: dict) -> dict:
    """Return a new dict of ``doc`` without ``version`` and ``generated_at``."""
    return {k: v for k, v in doc.items() if k not in ("version", "generated_at")}


def _should_write(new_doc: dict, previous_doc: dict | None, now: int) -> bool:
    """Return True when ``new_doc`` must be written over ``previous_doc``.

    Always on the first run (or an unusable previous object) and whenever the
    content, everything except ``version`` and ``generated_at``, changed.
    Unchanged content is rewritten only once the forced refresh is due.
    """
    if previous_doc is None or _content(new_doc) != _content(previous_doc):
        return True

    # The only code that depends on open owner Decision 5 (provisional 6-hour
    # forced refresh, see FORCED_REFRESH). Dropping the refresh means deleting
    # FORCED_REFRESH and this age check; unchanged content is then never
    # rewritten. An unreadable generated_at forces a write.
    generated = previous_doc.get("generated_at")
    if not isinstance(generated, str):
        return True
    try:
        generated_at = datetime.fromisoformat(generated)
    except ValueError:
        return True
    if generated_at.tzinfo is None:
        generated_at = generated_at.replace(tzinfo=timezone.utc)
    return datetime.fromtimestamp(now, timezone.utc) - generated_at >= FORCED_REFRESH


def _emit_success(written: bool, doc: dict) -> None:
    """Print one CloudWatch Embedded Metric Format ``AggregateSucceeded`` line.

    The metric is ``AggregateSucceeded = 1`` in namespace ``Sheket`` with the
    dimension ``Function = aggregate``; ``written``, ``call_numbers`` and
    ``sms_senders`` are plain properties (not metrics) for the audit trail.
    ``print``, not the logger: EMF needs the raw single-line JSON on stdout.
    Not emitted when the run raises, so the stale-list alarm (#8) sees a
    missing heartbeat.
    """
    payload = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": METRIC_NAMESPACE,
                    "Dimensions": [["Function"]],
                    "Metrics": [{"Name": "AggregateSucceeded", "Unit": "Count"}],
                }
            ],
        },
        "Function": FUNCTION_NAME,
        "AggregateSucceeded": 1,
        "written": written,
        "call_numbers": len(doc["call_numbers"]),
        "sms_senders": len(doc["sms_senders"]),
    }
    print(json.dumps(payload, separators=(",", ":")))


def handler(event, context) -> None:
    """Aggregate Lambda entry point; ``event`` and ``context`` are unused.

    Reads the configuration and the contract, takes the clock once, loads the
    reports, the overrides and the previous blocklist, builds the new
    document and validates it before anything is written. The document is
    written to ``v1/blocklist.json`` only when ``_should_write`` says so, and
    one log line records the outcome with counts only.

    Any exception propagates: Lambda reports an error, the Errors alarm fires
    and the published blocklist stays in place (spec 7). The success
    heartbeat is emitted only after a successful run.
    """
    cfg = _config()
    curated, schema = _load_contract()
    now = _now()

    reports = _load_reports(cfg.table, now)
    overrides = _load_overrides(cfg.table)
    previous_doc, previous_version = _load_previous(cfg.bucket)

    doc = build_blocklist(
        curated,
        reports,
        overrides,
        now,
        previous_version,
        cfg.min_installs,
        cfg.min_networks,
    )
    # Before any write: an invalid document raises and nothing is written.
    validate_blocklist(doc, schema)

    written = _should_write(doc, previous_doc, now)
    if written:
        _s3().put_object(
            Bucket=cfg.bucket,
            Key=BLOCKLIST_KEY,
            Body=serialize_blocklist(doc).encode("utf-8"),
            ContentType=CONTENT_TYPE,
            CacheControl=CACHE_CONTROL,
        )

    logger.info(
        "blocklist %s: version=%d call_numbers=%d sms_senders=%d",
        "written" if written else "unchanged",
        doc["version"] if written else previous_version,
        len(doc["call_numbers"]),
        len(doc["sms_senders"]),
    )
    _emit_success(written, doc)
