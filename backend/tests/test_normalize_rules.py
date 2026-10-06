"""Edge-case tests for ``sheket.normalize`` beyond the 18 corpus cases.

``contract/corpus.json`` stays the source of truth; these tests pin the rules
the design derives from it (design Phase 1.3) and the provisional answer to
owner Decision 3 (sender IDs with internal whitespace are rejected).
"""

import pytest

from sheket.normalize import E164, is_e164, normalize_sender

# --- is_e164 -----------------------------------------------------------------


def test_e164_pattern_matches_schema_call_numbers_pattern(contract_loader):
    schema = contract_loader("blocklist.schema.json")
    pattern = schema["properties"]["call_numbers"]["items"]["pattern"]
    assert E164.pattern == pattern == r"^\+[1-9][0-9]{6,14}$"


@pytest.mark.parametrize(
    "s",
    [
        "+972555001234",
        "+12125550100",
        "+1234567",  # 7 digits: shortest allowed
        "+123456789012345",  # 15 digits: longest allowed
    ],
)
def test_is_e164_accepts(s):
    assert is_e164(s) is True


@pytest.mark.parametrize(
    "s",
    [
        "",
        "+",
        "972555001234",  # no leading +
        "+0972555001234",  # leading zero after +
        "+123456",  # 6 digits: too short
        "+1234567890123456",  # 16 digits: too long
        "+972 55 500 1234",  # separators are not stripped
        "+972555001234\n",  # trailing newline must not slip past $
        " +972555001234",
        "+٩٧٢٥٥٥٠٠١٢٣٤",  # Arabic-Indic digits are not [0-9]
        "*2700",
        "100",
    ],
)
def test_is_e164_rejects(s):
    assert is_e164(s) is False


@pytest.mark.parametrize("value", [None, 972555001234, b"+972555001234", ["+1234567"]])
def test_is_e164_rejects_non_str(value):
    assert is_e164(value) is False


# --- normalize_sender: input that is not a sender ----------------------------


@pytest.mark.parametrize("value", [None, 555001234, 0, b"0555001234", [], {}])
def test_non_str_input_returns_none(value):
    assert normalize_sender(value) is None


@pytest.mark.parametrize("raw", ["\t", "\n", " \t\r\n ", " ", " "])
def test_whitespace_only_returns_none(raw):
    assert normalize_sender(raw) is None


@pytest.mark.parametrize("raw", ["-", "+", "()", "( )", "- -", "+()-"])
def test_phone_shaped_junk_without_digits_returns_none(raw):
    assert normalize_sender(raw) is None


# --- normalize_sender: phone numbers -----------------------------------------


@pytest.mark.parametrize(
    "raw",
    [
        "055-500-1234",
        "0555001234",
        "972555001234",
        "+972555001234",
        "+972 55 500 1234",
        "+972-55-500-1234",
        "(055) 500-1234",
        "+972 (55) 500-1234",
        "\t055 500 1234\n",
    ],
)
def test_spellings_of_one_israeli_mobile_number_converge(raw):
    assert normalize_sender(raw) == "+972555001234"


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("03-555-0123", "+97235550123"),  # 0 + 8 digits (landline)
        ("035550123", "+97235550123"),
        ("97235550123", "+97235550123"),  # 972 + 8 digits
        ("+1 212 555 0100", "+12125550100"),  # foreign, kept as written
        ("+44 20 7946 0000", "+442079460000"),
    ],
)
def test_phone_rules(raw, expected):
    assert normalize_sender(raw) == expected


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("+972 (0)55 500 1234", "+972555001234"),
        ("+9720555001234", "+972555001234"),
        ("9720555001234", "+972555001234"),
        ("+972 (0)2 123 4567", "+97221234567"),
        # Same as the national spelling "05550012": 0 + 7 digits is too short.
        ("97205550012", None),
        # A short service number is kept as written, never trunk-stripped.
        ("97201", "97201"),
    ],
)
def test_trunk_zero_after_972_is_dropped(raw, expected):
    assert normalize_sender(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "05550012345",  # 0 + 10 digits: too long for a national number
        "0555001",  # 0 + 6 digits: too short
        "9725550012345",  # 972 + 10 digits
        "12125550100",  # no +, not Israeli: country unknown
        "123456",  # 6 digits: not a short service number
        "99",  # 2 digits: too short for a short service number
        "012",  # short number may not start with 0
        "+0555001234",  # + then 0 is never E.164
        "+123456",  # + then 6 digits: too short for E.164
        "+1234567890123456",  # + then 16 digits: too long for E.164
    ],
)
def test_unplaceable_numbers_return_none(raw):
    assert normalize_sender(raw) is None


@pytest.mark.parametrize("raw", ["100", "101", "112", "1201", "12345"])
def test_short_service_numbers_stay_as_written(raw):
    assert normalize_sender(raw) == raw


def test_short_service_number_is_trimmed():
    assert normalize_sender("  112 ") == "112"


def test_phone_outputs_always_match_schema_pattern():
    for raw in ["0555001234", "972555001234", "+972555001234", "+1 212 555 0100"]:
        out = normalize_sender(raw)
        assert out is not None and is_e164(out), (raw, out)


# --- normalize_sender: star codes --------------------------------------------


@pytest.mark.parametrize("raw", ["*2700", "*507", "*3857", "*12", "*123456"])
def test_star_codes_stay_as_written(raw):
    assert normalize_sender(raw) == raw


def test_star_code_is_trimmed():
    assert normalize_sender("  *2700  ") == "*2700"


# --- normalize_sender: sender IDs --------------------------------------------


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("ExampleParty", "exampleparty"),
        ("  Leumi  ", "leumi"),
        ("gov.il", "gov.il"),
        ("Bank-Hapoalim", "bank-hapoalim"),
        ("Unknown", "unknown"),
        ("a", "a"),
    ],
)
def test_sender_ids_are_trimmed_and_casefolded(raw, expected):
    assert normalize_sender(raw) == expected


def test_sender_id_of_exactly_20_characters_is_kept():
    raw = "A" * 20
    assert normalize_sender(raw) == "a" * 20


def test_sender_id_of_21_characters_returns_none():
    assert normalize_sender("A" * 21) is None


def test_sender_id_length_is_measured_after_casefold():
    # "ß" case-folds to "ss": 11 characters in, 22 after case-folding.
    assert normalize_sender("ß" * 11) is None
    assert normalize_sender("ß" * 10) == "ss" * 10


def test_surrounding_whitespace_does_not_count_towards_length():
    assert normalize_sender("   " + "A" * 20 + "   ") == "a" * 20


@pytest.mark.parametrize(
    "raw",
    [
        "Example Party",
        "Example\tParty",
        "Example\nParty",
        "Example Party",
        "this is a sentence, not a sender",
    ],
)
def test_sender_ids_with_internal_whitespace_return_none(raw):
    # Provisional answer to owner Decision 3: reject internal whitespace.
    assert normalize_sender(raw) is None


@pytest.mark.parametrize(
    "raw",
    [
        "٠٥٥٥٠٠١٢٣٤",  # Arabic-Indic digits
        "+٩٧٢٥٥٥٠٠١٢٣٤",  # + then Arabic-Indic digits
        "０５５５００１２３４",  # fullwidth digits
        "055.500.1234",  # dotted spelling
        "+972.55.500.1234",
        "055/500/1234",  # slashed spelling
        "++972555001234",  # doubled +
        "*",  # bare star
        "*1",  # star code too short
        "*1234567",  # star code too long
        "*١٢٣٤",  # star code with Arabic-Indic digits
    ],
)
def test_number_shaped_input_is_never_a_sender_id(raw):
    # contract/README.md: every spelling of one number is one sender, so a
    # number that cannot be normalised is rejected, not kept as a sender ID.
    assert normalize_sender(raw) is None


@pytest.mark.parametrize(
    "raw, expected", [("G-482913", "g-482913"), ("Bank1", "bank1")]
)
def test_sender_ids_with_digits_and_a_letter_are_kept(raw, expected):
    assert normalize_sender(raw) == expected


@pytest.mark.parametrize(
    "raw", ["0555001234", "+972 55 500 1234", "ExampleParty", "*2700", "100", "gov.il"]
)
def test_normalize_is_idempotent(raw):
    once = normalize_sender(raw)
    assert normalize_sender(once) == once


# --- other contract files ----------------------------------------------------


def test_corpus_normalize_outputs_are_fixed_points(corpus):
    for case in corpus["normalize"]:
        out = case["out"]
        if out is not None:
            assert normalize_sender(out) == out, case


# Expected results for the corpus inputs that are not already E.164. Each
# table's keys must equal those inputs exactly, so a new corpus case fails
# until its expected result is written down here.
_CALL_NUMBERS_EXPECTED = {
    "": None,
    "055-500-1234": "+972555001234",
    "0555010000": "+972555010000",
    "972555001234": "+972555001234",
    "+972 55 500 1234": "+972555001234",
    "Unknown": "unknown",
}

_SMS_SENDERS_EXPECTED = {
    "": None,
    "  examplelist ": "examplelist",
    "+972 55 500 4321": "+972555004321",
    "055-500-4321": "+972555004321",
    "BECHIROT": "bechirot",
    "Bechirot": "bechirot",
    "BankHapoalim": "bankhapoalim",
    "Clalit": "clalit",
    "EXAMPLEPARTY": "exampleparty",
    "ExampleParty": "exampleparty",
    "ExampleAllow": "exampleallow",
    "Google": "google",
    "Leumi": "leumi",
    "Maccabi": "maccabi",
    "WhatsApp": "whatsapp",
}


def _assert_exact(inputs, expected):
    assert inputs
    assert {s for s in inputs if not is_e164(s)} == set(expected)
    for s in inputs:
        want = s if is_e164(s) else expected[s]
        assert normalize_sender(s) == want, s


def test_corpus_call_numbers_normalise_exactly(corpus):
    _assert_exact([c["number"] for c in corpus["calls"]], _CALL_NUMBERS_EXPECTED)


def test_corpus_sms_senders_normalise_exactly(corpus):
    _assert_exact([c["sender"] for c in corpus["sms"]], _SMS_SENDERS_EXPECTED)


def test_test_blocklist_senders_normalise_exactly(contract_loader):
    blocklist = contract_loader("test-blocklist.json")
    senders = blocklist["sms_senders"] + blocklist["sms_allow_senders"]
    assert senders
    for sender in senders:
        expected = sender if is_e164(sender) else sender.casefold()
        assert normalize_sender(sender) == expected, sender
    assert blocklist["call_numbers"]
    for number in blocklist["call_numbers"]:
        assert normalize_sender(number) == number


# --- conftest ----------------------------------------------------------------


def test_contract_dir_is_resolved_from_the_test_file(
    contract_dir, contract_loader, tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    assert contract_dir.is_absolute()
    assert contract_dir.name == "contract"
    assert (contract_dir / "corpus.json").is_file()
    assert len(contract_loader("corpus.json")["normalize"]) == 18


def test_load_contract_does_not_modify_contract_files(contract_dir, contract_loader):
    path = contract_dir / "corpus.json"
    before = (path.read_bytes(), path.stat().st_mtime_ns)
    contract_loader("corpus.json")
    assert (path.read_bytes(), path.stat().st_mtime_ns) == before
