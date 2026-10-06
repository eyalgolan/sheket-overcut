"""Tests for ``sheket.normalize`` against the contract corpus."""

from sheket.normalize import is_e164, normalize_sender


def test_normalize_corpus(normalize_case):
    assert normalize_sender(normalize_case["in"]) == normalize_case["out"]


def test_corpus_has_18_normalize_cases(corpus):
    assert len(corpus["normalize"]) == 18


def test_phone_outputs_are_e164(corpus):
    phones = [
        c["out"]
        for c in corpus["normalize"]
        if c["out"] is not None and c["out"].startswith("+")
    ]
    assert phones
    for out in phones:
        assert is_e164(out), out


def test_curated_senders_are_already_normalised(curated):
    senders = curated["sms_allow_senders"] + curated["never_block"]
    assert senders
    for sender in senders:
        assert normalize_sender(sender) == sender, sender
