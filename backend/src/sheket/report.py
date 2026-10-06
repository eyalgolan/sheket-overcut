"""Report handler: ``POST /v1/reports`` behind a Lambda Function URL.

The binding definition is spec section 6.2 (``docs/spec.md``); the module
layout follows design Phase 2 (design comment on issue #1). The Function URL
delivers API Gateway payload format version 2.0.

Provisional values, named here in one place:

- The request body is capped at 8 KiB (``MAX_BODY_BYTES``).
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
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import random
import re
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
