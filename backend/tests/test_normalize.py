import pytest

from sheket.normalize import is_e164, normalize_sender


def test_normalize_corpus(normalize_case):
    assert normalize_sender(normalize_case["in"]) == normalize_case["out"]


def test_corpus_has_normalize_cases(normalize_cases):
    # Guards against an empty or renamed list silently skipping test_normalize_corpus.
    assert normalize_cases


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("+1234567", True),  # shortest: 7 digits
        ("+123456789012345", True),  # longest: 15 digits
        ("+123456", False),
        ("+1234567890123456", False),
        ("+0555001234", False),
        ("+972555001234\n", False),
        ("972555001234", False),
    ],
)
def test_is_e164(value, expected):
    assert is_e164(value) is expected


def test_corpus_outputs_are_fixed_points(normalize_cases):
    # A stored (already normalised) sender must normalise to itself.
    for out in {c["out"] for c in normalize_cases if c["out"] is not None}:
        assert normalize_sender(out) == out


def test_curated_senders_are_already_normalised(curated):
    # contract/README.md: senders in curated.json are stored in normalised form.
    senders = (
        curated["sms_senders"] + curated["sms_allow_senders"] + curated["never_block"]
    )
    assert senders
    for sender in senders:
        assert normalize_sender(sender) == sender


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        # Rule 1: "+<digits>" is kept once separators are removed, if it is E.164.
        ("+1 (202) 555-0100", "+12025550100"),
        ("+0555001234", None),
        ("+123456", None),
        ("+1234567890123456", None),
        ("+", None),
        # Rule 2: 972 followed by 8 or 9 digits.
        ("97221234567", "+97221234567"),
        ("9722123456", None),
        ("9725550012345", None),
        # Rule 3: national landline (0 + 8 digits) and mobile (0 + 9 digits).
        ("02-1234567", "+97221234567"),
        ("0212345", None),
        ("05550012345", None),
        # Rule 4: short service numbers, 3-5 digits, no leading 0.
        ("1201", "1201"),
        ("12345", "12345"),
        ("012", None),
        ("12", None),
        # Rule 5: any other phone-like input, country unknown.
        ("123456", None),
        ("2025550100", None),
        ("--", None),
        ("( )", None),
        # Surrounding whitespace of any kind is trimmed.
        ("\t055-500-1234\n", "+972555001234"),
        ("\n", None),
    ],
)
def test_phone_like_rules(raw, expected):
    assert normalize_sender(raw) == expected


@pytest.mark.parametrize("raw", ["*12", "*507", "*123456"])
def test_star_codes_kept_as_written(raw):
    assert normalize_sender(raw) == raw


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("BankHapoalim", "bankhapoalim"),
        ("A" * 20, "a" * 20),
        ("A" * 21, None),
        # Length is measured after casefold: "ß" becomes "ss".
        ("ß" * 10, "ss" * 10),
        ("ß" * 11, None),
    ],
)
def test_sender_ids(raw, expected):
    assert normalize_sender(raw) == expected


@pytest.mark.parametrize("raw", ["Bank Leumi", "bank\tleumi", "bank leumi"])
def test_sender_id_with_internal_whitespace_rejected(raw):
    # Provisional answer to open owner Decision 3 (issue #2): reject.
    assert normalize_sender(raw) is None


@pytest.mark.parametrize(
    "value",
    [
        "+٩٧٢٥٥٥٠٠١٢٣٤",  # Arabic-Indic digits are not [0-9]
        " +972555001234",
        "+972 555001234",
    ],
)
def test_is_e164_rejects_non_ascii_digits_and_spaces(value):
    assert is_e164(value) is False


def test_non_ascii_digits_are_never_a_phone_number():
    assert not is_e164(normalize_sender("٠٥٥٥٠٠١٢٣٤") or "")
