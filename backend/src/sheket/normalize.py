"""Shared sender normaliser.

The binding definition is spec section 6 (``docs/spec.md``) and
``contract/README.md``; the ``normalize`` cases in ``contract/corpus.json`` make
it executable. The rules, in the order the code applies them, are listed in
``normalize_sender``.

Patterns use ``[0-9]`` rather than ``\\d``, which in Python also matches
non-ASCII Unicode digits.
"""

import re

# Must equal call_numbers.items.pattern in contract/blocklist.schema.json.
E164 = re.compile(r"^\+[1-9][0-9]{6,14}$")

_PHONE_CHARS = re.compile(r"\+?[0-9 ()\-]*")
_STAR_CODE = re.compile(r"\*[0-9]{2,6}")
_IL_INTERNATIONAL = re.compile(r"972[0-9]{8,9}")
# 0 then a non-zero digit: "00" is the international dialling prefix.
_IL_NATIONAL = re.compile(r"0[1-9][0-9]{7,8}")
_SHORT_NUMBER = re.compile(r"[1-9][0-9]{2,4}")
_MAX_SENDER_ID_LEN = 20


def is_e164(s: object) -> bool:
    """Return True only for a str that fully matches ``E164``."""
    return isinstance(s, str) and E164.fullmatch(s) is not None


def normalize_sender(raw: object) -> str | None:
    """Normalise a raw sender; return the normalised form or None.

    Rules, in the order the code applies them (design Phase 1.3):

    1. Input that is not a ``str`` returns None. Trim it with ``str.strip()``,
       which removes Unicode whitespace, including ``\\x1c``-``\\x1f`` and
       ``\\x85``. Empty after trimming returns None.
    2. Phone-like input: an optional leading ``+``, then only ASCII digits,
       space, ``(``, ``)`` and ``-``. Remove the separators; if no digits are
       left, return None. Then, in order:

       - ``+`` followed by digits is kept as written; ``(0)`` is not special.
       - ``972`` followed by 8-9 digits becomes ``+972...``.
       - ``0[1-9]`` followed by 7-8 more digits (a national number) becomes
         ``+972`` plus the digits without the leading 0. ``00...`` is the
         international dialling prefix and returns None.
       - 3-5 digits with no leading 0 is a short service number, returned
         with the separators removed (``1-0-0`` gives ``100``).
       - Anything else returns None (design rule 5), for example Israeli
         1-700/1-800 numbers such as ``1800500500``.

       A result from the ``+``, ``972`` or national rule must pass
       ``is_e164``, or the function returns None.
    3. Star code: ``*`` followed by 2-6 ASCII digits, kept as written.
    4. Anything else is a sender ID, case-folded with full Unicode
       ``str.casefold()`` (so ``ß`` becomes ``ss``).
    5. A sender ID longer than 20 code points, measured after case-folding,
       returns None.
    6. A sender ID containing any ``str.isspace()`` character returns None
       (provisional answer to owner Decision 3).
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

    f = s.casefold()
    if len(f) > _MAX_SENDER_ID_LEN:
        return None
    if any(c.isspace() for c in f):
        return None
    return f
