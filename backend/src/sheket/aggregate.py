"""Pure blocklist builder for the aggregate Lambda.

The binding definition is spec section 6 (``docs/spec.md``): section 6.1
defines the blocklist document, whose ``version`` only increases, and section
6.3 the publication rule and the ``force_block`` / ``never_block`` overrides.
The structure follows design Phase 3 (the design comment on issue #1).
``contract/README.md`` (Schema notes) explains why ``date-time`` format
checking needs the ``rfc3339-validator`` package.

This module is pure: no AWS and no I/O. The Lambda handler that loads the
reports and stores the blocklist is added in #6.
"""

import json
import logging
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone

from jsonschema import Draft202012Validator, FormatChecker

from sheket.normalize import is_e164, normalize_sender

# Fixed by spec 6.3 ("within the last 7 days"); not a parameter.
WINDOW = timedelta(days=7)
SCHEMA_VERSION = 1
KINDS = ("call", "sms")

logger = logging.getLogger(__name__)

# Without rfc3339-validator, jsonschema silently skips the date-time check on
# generated_at (contract/README.md, Schema notes). An explicit raise, not an
# assert, so the guard survives ``python -O``.
if "date-time" not in FormatChecker.checkers:
    raise RuntimeError(
        "date-time format checking is unavailable: install rfc3339-validator "
        "(see contract/README.md, Schema notes)"
    )


def _parse_overrides(
    curated_never: Iterable[str], overrides: Iterable[object]
) -> tuple[set[str], set[str], set[str]]:
    """Parse operator override items; return ``(force_call, force_sms, never)``.

    Only ``item.get("sk")`` is read. Two forms are accepted (spec 6.3):
    ``force_block#<kind>#<sender>`` and ``never_block#<sender>``. The sender
    is the rest of the key, so a ``#`` inside it is preserved, and it is
    normalised with ``normalize_sender``. A ``force_block#call`` sender must
    also be E.164. A malformed item is logged and skipped, never raised, so
    one bad override cannot stop the blocklist from being built.

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
            logger.error("override skipped: missing or non-str sk: %r", sk)
            continue

        if sk.startswith("force_block#"):
            parts = sk.split("#", 2)
            if len(parts) != 3 or not parts[2]:
                logger.error("override skipped: malformed force_block: %r", sk)
                continue
            _, kind, raw = parts
            if kind not in KINDS:
                logger.error("override skipped: unknown kind: %r", sk)
                continue
            sender = normalize_sender(raw)
            if sender is None:
                logger.error("override skipped: sender does not normalise: %r", sk)
                continue
            if kind == "call":
                if not is_e164(sender):
                    logger.error("override skipped: call sender not E.164: %r", sk)
                    continue
                force_call.add(sender)
            else:
                force_sms.add(sender)
        elif sk.startswith("never_block#"):
            parts = sk.split("#", 1)
            if len(parts) != 2 or not parts[1]:
                logger.error("override skipped: malformed never_block: %r", sk)
                continue
            sender = normalize_sender(parts[1])
            if sender is None:
                logger.error("override skipped: sender does not normalise: %r", sk)
                continue
            never_overrides.add(sender)
        else:
            logger.error("override skipped: unknown prefix: %r", sk)

    never = set(curated_never) | never_overrides
    return force_call, force_sms, never


_REPORT_FIELDS = ("kind", "sender", "install_id", "net_hash", "received_at")


def _published(
    reports: Iterable[object], now: int, min_installs: int, min_networks: int
) -> tuple[set[str], set[str]]:
    """Apply the publication rule (spec 6.3); return ``(call_set, sms_set)``.

    A report counts only if its ``received_at`` is within ``WINDOW`` of
    ``now`` (Unix seconds); a naive timestamp is treated as UTC. The sender
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
    cutoff = datetime.fromtimestamp(now, timezone.utc) - WINDOW
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
    entries (spec 6.3). Lists are sorted so the output is deterministic.

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

    # The curated-only lists below are taken as they are: never_block is not
    # applied to them. never_block guards against blocking a sender, and every
    # curated sms_allow_senders entry is also in never_block, so subtracting it
    # would empty the allow list and break the seed blocklist.
    call_prefixes = sorted(curated["call_prefixes"])
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
