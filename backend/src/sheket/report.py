"""Report handler: ``POST /v1/reports`` behind a Lambda Function URL.

The binding definition is spec section 6.2 (``docs/spec.md``); the module
layout follows design Phase 2 (design comment on issue #1). The Function URL
delivers API Gateway payload format version 2.0; the entry point is
``sheket.report.handler``.

Responses: ``202 {}`` accepted; ``400 {"error": "<field>"}`` malformed;
``404`` any other path; ``405`` any other method; ``429`` rate limited.
Each request logs one INFO outcome line and never logs request content or
the source IP.

Provisional values, named here in one place:

- The request body is capped at 8 KiB (``MAX_BODY_BYTES``), measured on the
  raw body bytes after any base64 decoding.
- ``app_version`` must fully match ``[0-9A-Za-z.+\\-]{1,32}``
  (``_APP_VERSION``).
- A "day" for the per-install limit is a UTC calendar day.
- IPv4 sources are grouped by /24, as the spec says. IPv6 sources are grouped
  by /48 (provisional answer to owner Decision 2).
- A ``call`` report that carries ``text`` is rejected with
  ``400 {"error": "text"}`` (provisional answer to owner Decision 6).

Configuration comes from the environment, read at call time, never at import:

- ``TABLE_NAME``: the DynamoDB table name.
- ``IP_HASH_SALT``: the HMAC key for source-IP hashes. It is never in source.

Patterns use ``[0-9]`` rather than ``\\d``, which in Python also matches
non-ASCII Unicode digits.
"""

import base64
import binascii
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import random
import re
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

from sheket.normalize import is_e164, normalize_sender

ROUTE_PATH = "/v1/reports"
MAX_BODY_BYTES = 8192
MAX_TEXT_CHARS = 1000
INSTALL_DAILY_LIMIT = 20
IP_HOURLY_LIMIT = 60
REPORT_TTL_SECONDS = 30 * 86400
PLATFORMS = frozenset({"ios", "android"})
KINDS = frozenset({"call", "sms"})
# Use with fullmatch only: an anchoring "$" would accept a trailing newline.
_APP_VERSION = re.compile(r"[0-9A-Za-z.+\-]{1,32}")
IPV4_PREFIX = 24
IPV6_PREFIX = 48

logger = logging.getLogger(__name__)
# The Lambda runtime's root logger level would otherwise hide INFO records.
logger.setLevel(logging.INFO)

_client = None


def _response(status: int, payload: dict, headers: dict | None = None) -> dict:
    """Build a payload v2.0 response with a JSON body."""
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **(headers or {})},
        "body": json.dumps(payload),
    }


def _now() -> datetime:
    """Return the current UTC time; the single clock source for the module."""
    return datetime.now(timezone.utc)


def _salt() -> str:
    """Return ``IP_HASH_SALT``; raise RuntimeError if it is missing or empty."""
    salt = os.environ.get("IP_HASH_SALT")
    if not salt:
        raise RuntimeError("IP_HASH_SALT is not set")
    return salt


def _hmac(salt: str, msg: str) -> str:
    """Return the hex HMAC-SHA256 of ``msg`` keyed with ``salt``."""
    return hmac.new(salt.encode(), msg.encode(), hashlib.sha256).hexdigest()


def _network_hashes(source_ip: str, salt: str) -> tuple[str, str]:
    """Return ``(net_hash, ip_key)`` for a source IP.

    ``net_hash`` hashes the source network: the /24 for IPv4, the /48 for
    IPv6. An IPv4-mapped IPv6 address is treated as its IPv4 address.
    ``ip_key`` hashes the full address in canonical compressed form, for the
    per-IP rate limit. An invalid or missing source IP is a platform fault, so
    the ValueError or TypeError propagates.
    """
    ip = ipaddress.ip_address(source_ip)
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped

    if isinstance(ip, ipaddress.IPv4Address):
        network = ipaddress.ip_network(f"{ip}/{IPV4_PREFIX}", strict=False)
        net_hash = _hmac(salt, "v4:" + str(network))
    else:
        network = ipaddress.ip_network(f"{ip}/{IPV6_PREFIX}", strict=False)
        net_hash = _hmac(salt, "v6:" + str(network))

    ip_key = _hmac(salt, "ip:" + str(ip))
    return net_hash, ip_key


def _dynamodb():
    """Return the DynamoDB client, created on first use.

    The region comes from the environment. Tests reset ``_client`` to None.
    """
    global _client
    if _client is None:
        _client = boto3.client("dynamodb")
    return _client


def _table_name() -> str:
    """Return ``TABLE_NAME``, read on every call."""
    return os.environ["TABLE_NAME"]


def _reject_constant(name: str) -> None:
    """Reject the non-standard JSON constants NaN, Infinity and -Infinity."""
    raise ValueError(f"invalid JSON constant: {name}")


def _parse_body(event: dict) -> dict | None:
    """Return the request body as a JSON object, or None if it is malformed.

    The size cap applies to the raw bytes after any base64 decoding. The bytes
    are decoded as strict UTF-8 before parsing, because ``json.loads`` on bytes
    would auto-detect UTF-16 and UTF-32.
    """
    raw = event.get("body")
    if not isinstance(raw, str):
        return None
    try:
        if event.get("isBase64Encoded"):
            data = base64.b64decode(raw, validate=True)
        else:
            data = raw.encode("utf-8")
    except (binascii.Error, ValueError):
        # UnicodeEncodeError (a lone surrogate) is a ValueError subclass.
        return None
    if len(data) > MAX_BODY_BYTES:
        return None
    try:
        body = json.loads(data.decode("utf-8"), parse_constant=_reject_constant)
    except (ValueError, RecursionError):
        # UnicodeDecodeError and json.JSONDecodeError are ValueError subclasses.
        return None
    return body if isinstance(body, dict) else None


def _is_utf8_encodable(s: str) -> bool:
    """Return False if ``s`` holds a lone surrogate, such as from ``\\ud800``."""
    try:
        s.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _parse_install_id(value: object) -> str | None:
    """Return the canonical lowercase UUID, or None if ``value`` is not one.

    Only the 36-character hyphenated form is accepted; braces, ``urn:uuid:``
    and the hyphen-less form are rejected.
    """
    if not isinstance(value, str) or len(value) != 36:
        return None
    try:
        canonical = str(uuid.UUID(value))
    except ValueError:
        return None
    return canonical if canonical == value.lower() else None


def _validate(event: dict) -> tuple[dict | None, str | None]:
    """Parse and validate a report request; no I/O, no environment reads.

    Return ``(fields, None)`` on success or ``(None, field)`` naming the first
    failing field. Fields are checked in this fixed order: body, install_id,
    platform, kind, sender, text, app_version. Unknown fields are ignored.
    A malformed request is rejected before any rate-limit quota is used
    (AC-10).
    """
    body = _parse_body(event)
    if body is None:
        return None, "body"

    install_id = _parse_install_id(body.get("install_id"))
    if install_id is None:
        return None, "install_id"

    platform = body.get("platform")
    if not isinstance(platform, str) or platform not in PLATFORMS:
        return None, "platform"

    kind = body.get("kind")
    if not isinstance(kind, str) or kind not in KINDS:
        return None, "kind"

    sender = normalize_sender(body.get("sender"))
    if sender is None:
        return None, "sender"
    if kind == "call" and not is_e164(sender):
        return None, "sender"
    if not _is_utf8_encodable(sender):
        return None, "sender"

    text = body.get("text")
    if text is not None:
        if kind == "call":
            # Provisional answer to owner Decision 6.
            return None, "text"
        if not isinstance(text, str) or not _is_utf8_encodable(text):
            return None, "text"
        if len(text) > MAX_TEXT_CHARS:
            return None, "text"

    app_version = body.get("app_version")
    if not isinstance(app_version, str) or not _APP_VERSION.fullmatch(app_version):
        return None, "app_version"

    return {
        "install_id": install_id,
        "platform": platform,
        "kind": kind,
        "sender": sender,
        "text": text,
        "app_version": app_version,
    }, None


# Fixed positions in the transaction; the 429 logic reads cancellation
# reasons by index.
_INSTALL_IDX = 0
_IP_IDX = 1
_WRITE_ATTEMPTS = 2


def _received_at(now: datetime) -> str:
    """Return ``now`` as ISO-8601 UTC with milliseconds, e.g. ``...T12:00:00.123Z``."""
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def _day(now: datetime) -> str:
    """Return the UTC calendar day of ``now`` as ``YYYY-MM-DD``."""
    return now.strftime("%Y-%m-%d")


def _hour(now: datetime) -> str:
    """Return the UTC hour of ``now`` as ``YYYY-MM-DDTHH``."""
    return now.strftime("%Y-%m-%dT%H")


def _report_ttl(now: datetime) -> int:
    """Return the report's ``expires_at``: ``REPORT_TTL_SECONDS`` after ``now``."""
    return int(now.timestamp()) + REPORT_TTL_SECONDS


def _install_counter_ttl(now: datetime) -> int:
    """Return the install counter's ``expires_at``: one day after the day ends."""
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return int((day_start + timedelta(days=1)).timestamp()) + 86400


def _ip_counter_ttl(now: datetime) -> int:
    """Return the IP counter's ``expires_at``: one hour after the hour ends."""
    hour_start = now.replace(minute=0, second=0, microsecond=0)
    return int((hour_start + timedelta(hours=1)).timestamp()) + 3600


def _report_item(fields: dict, net_hash: str, now: datetime) -> dict:
    """Build the report item in DynamoDB attribute-value form.

    ``text`` is present only when the request carried it. No source IP, raw
    or otherwise, is ever stored.
    """
    received_at = _received_at(now)
    item = {
        "pk": {"S": f"R#{_day(now)}"},
        "sk": {"S": f"{received_at}#{uuid.uuid4()}"},
        "install_id": {"S": fields["install_id"]},
        "platform": {"S": fields["platform"]},
        "kind": {"S": fields["kind"]},
        "sender": {"S": fields["sender"]},
        "app_version": {"S": fields["app_version"]},
        "received_at": {"S": received_at},
        "net_hash": {"S": net_hash},
        "expires_at": {"N": str(_report_ttl(now))},
    }
    if fields["text"] is not None:
        item["text"] = {"S": fields["text"]}
    return item


def _counter_update(pk: str, limit: int, expires_at: int) -> dict:
    """Build a conditional increment of the counter at ``pk``, capped at ``limit``."""
    return {
        "Update": {
            "TableName": _table_name(),
            "Key": {"pk": {"S": pk}, "sk": {"S": "-"}},
            "UpdateExpression": "SET expires_at = :exp ADD #n :one",
            "ConditionExpression": "attribute_not_exists(#n) OR #n < :lim",
            "ExpressionAttributeNames": {"#n": "n"},
            "ExpressionAttributeValues": {
                ":exp": {"N": str(expires_at)},
                ":one": {"N": "1"},
                ":lim": {"N": str(limit)},
            },
        }
    }


def _transact_items(
    fields: dict, net_hash: str, ip_key: str, now: datetime
) -> list[dict]:
    """Build the transaction: install counter, IP counter, report, in that order."""
    return [
        _counter_update(
            f"RL#I#{fields['install_id']}#{_day(now)}",
            INSTALL_DAILY_LIMIT,
            _install_counter_ttl(now),
        ),
        _counter_update(
            f"RL#A#{ip_key}#{_hour(now)}",
            IP_HOURLY_LIMIT,
            _ip_counter_ttl(now),
        ),
        {
            "Put": {
                "TableName": _table_name(),
                "Item": _report_item(fields, net_hash, now),
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        },
    ]


def _write(items: list[dict]) -> bool:
    """Run the transaction; return True if stored, False if rate limited.

    A failed counter condition means a limit is reached. A transaction
    conflict is retried once after a short jitter; a second conflict is
    treated as rate limited (design Phase 2.6). A cancelled transaction
    commits nothing, so the same items, report ``sk`` included, are reused.
    Any other failure propagates.
    """
    for attempt in range(_WRITE_ATTEMPTS):
        try:
            _dynamodb().transact_write_items(TransactItems=items)
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            codes = [r.get("Code") for r in e.response.get("CancellationReasons", [])]
            if any(
                len(codes) > idx and codes[idx] == "ConditionalCheckFailed"
                for idx in (_INSTALL_IDX, _IP_IDX)
            ):
                return False
            if "TransactionConflict" not in codes:
                # Includes a failed Put at index 2: an sk collision.
                raise
            if attempt + 1 < _WRITE_ATTEMPTS:
                time.sleep(random.uniform(0, 0.1))
    return False


def handler(event: dict, context: object) -> dict:
    """Handle a Function URL payload v2.0 request for ``POST /v1/reports``.

    Validation runs before any salt, source-IP, clock or DynamoDB work
    (AC-10). Unexpected errors propagate to the Lambda Errors alarm (design
    Phase 2.6). Exactly one INFO line is logged per outcome, carrying only
    fixed outcome names and validated values (AC-5).
    """
    if event.get("rawPath") != ROUTE_PATH:
        logger.info("report outcome=%s", "not_found")
        return _response(404, {"error": "not_found"})
    if event["requestContext"]["http"]["method"] != "POST":
        logger.info("report outcome=%s", "method_not_allowed")
        return _response(405, {"error": "method_not_allowed"}, {"Allow": "POST"})

    fields, field = _validate(event)
    if fields is None:
        logger.info("report outcome=%s field=%s", "rejected", field)
        return _response(400, {"error": field})

    now = _now()
    net_hash, ip_key = _network_hashes(
        event["requestContext"]["http"]["sourceIp"], _salt()
    )
    items = _transact_items(fields, net_hash, ip_key, now)
    outcome = "accepted" if _write(items) else "rate_limited"
    logger.info(
        "report outcome=%s kind=%s platform=%s",
        outcome,
        fields["kind"],
        fields["platform"],
    )
    if outcome == "accepted":
        return _response(202, {})
    return _response(429, {"error": "rate_limited"})
