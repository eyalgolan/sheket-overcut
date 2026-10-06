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
