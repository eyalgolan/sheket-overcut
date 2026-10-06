"""Normalise SMS/call senders per the `normalize` cases in contract/corpus.json."""

import re

# The `call_numbers` pattern ^\+[1-9][0-9]{6,14}$ from contract/blocklist.schema.json,
# applied with fullmatch.
E164 = re.compile(r"\+[1-9][0-9]{6,14}")
PHONE_LIKE = re.compile(r"\+?[0-9 ()\-]+")
STAR_CODE = re.compile(r"\*[0-9]{2,6}")
SENDER_ID_MAX = 20

_IL_INTERNATIONAL = re.compile(r"972[0-9]{8,9}")
_IL_NATIONAL = re.compile(r"0[0-9]{8,9}")
_SHORT_NUMBER = re.compile(r"[1-9][0-9]{2,4}")


def is_e164(s: str) -> bool:
    return E164.fullmatch(s) is not None


def normalize_sender(raw: str) -> str | None:
    """Return the canonical form of an SMS/call sender, or None if it is not valid.

    Phone numbers become E.164 (Israeli national/international forms are
    expanded), short service numbers and star codes are kept as-is, and
    alphanumeric sender IDs are casefolded.
    """
    s = raw.strip()
    if not s:
        return None

    if PHONE_LIKE.fullmatch(s):
        d = re.sub(r"[ ()\-]", "", s)
        if d.startswith("+"):
            return d if is_e164(d) else None
        if _IL_INTERNATIONAL.fullmatch(d):
            candidate = "+" + d
        elif _IL_NATIONAL.fullmatch(d):
            candidate = "+972" + d[1:]
        elif _SHORT_NUMBER.fullmatch(d):
            return d
        else:
            return None
        return candidate if is_e164(candidate) else None

    if STAR_CODE.fullmatch(s):
        return s

    # Length is measured after casefold, which can lengthen (e.g. "ß" -> "ss").
    f = s.casefold()
    # Rejecting internal whitespace is the provisional answer to open owner
    # Decision 3 (issue #2): the safe default, since loosening later is safe
    # for stored data.
    if not 1 <= len(f) <= SENDER_ID_MAX or any(ch.isspace() for ch in f):
        return None
    return f
