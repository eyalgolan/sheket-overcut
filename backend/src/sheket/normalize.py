"""Shared sender normaliser.

The source of truth for the expected behaviour is the ``normalize`` section of
``contract/corpus.json``. A sender normalises to an E.164 number, a short
service number or star code as written, or a trimmed, case-folded sender ID.

A sender ID contains at least one letter and does not start with ``+`` or
``*``. Number-shaped input that is not a valid number (dotted or slashed
spellings, non-ASCII digits, out-of-range star codes) is rejected rather than
kept as a sender ID, so one number never splits into several senders
(``contract/README.md``).

Owner Decision 3 (sender IDs with internal spaces) is open; this module
provisionally rejects them.

Patterns use ``[0-9]`` rather than ``\\d``, which in Python also matches
non-ASCII Unicode digits.
"""

import re

# Must equal call_numbers.items.pattern in contract/blocklist.schema.json.
E164 = re.compile(r"^\+[1-9][0-9]{6,14}$")

_PHONE_CHARS = re.compile(r"\+?[0-9 ()\-]*")
_STAR_CODE = re.compile(r"\*[0-9]{2,6}")
_IL_INTERNATIONAL = re.compile(r"972[0-9]{8,9}")
_IL_NATIONAL = re.compile(r"0[0-9]{8,9}")
_SHORT_NUMBER = re.compile(r"[1-9][0-9]{2,4}")
_MAX_SENDER_ID_LEN = 20


def is_e164(s: object) -> bool:
    """Return True only for a str that fully matches ``E164``."""
    return isinstance(s, str) and E164.fullmatch(s) is not None


def normalize_sender(raw: object) -> str | None:
    """Normalise a raw sender; return the normalised form or None.

    See the ``normalize`` cases in ``contract/corpus.json``, the source of
    truth. Sender IDs must contain a letter and must not start with ``+`` or
    ``*``. Sender IDs containing whitespace are rejected (provisional answer
    to owner Decision 3).
    """
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s:
        return None

    if _PHONE_CHARS.fullmatch(s):
        had_plus = s.startswith("+")
        digits = re.sub(r"[+ ()\-]", "", s)
        if not digits:
            return None
        if had_plus or _IL_INTERNATIONAL.fullmatch(digits):
            candidate = "+" + digits
        elif _IL_NATIONAL.fullmatch(digits):
            candidate = "+972" + digits[1:]
        elif _SHORT_NUMBER.fullmatch(digits):
            return digits
        else:
            return None
        return candidate if is_e164(candidate) else None

    if _STAR_CODE.fullmatch(s):
        return s

    # Number-shaped input that did not normalise above is never a sender ID.
    if s[0] in "+*" or not any(c.isalpha() for c in s):
        return None

    f = s.casefold()
    if len(f) > _MAX_SENDER_ID_LEN:
        return None
    if any(c.isspace() for c in f):
        return None
    return f
