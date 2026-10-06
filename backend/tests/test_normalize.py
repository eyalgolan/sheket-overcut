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
