"""Shared pytest fixtures that load the read-only files in ``contract/``."""

import json
from pathlib import Path

import pytest

CONTRACT_DIR = Path(__file__).resolve().parents[2] / "contract"


def load_contract(name):
    """Load and return a JSON file from ``contract/``. Never writes."""
    with open(CONTRACT_DIR / name, "r", encoding="utf-8") as fh:
        return json.load(fh)


@pytest.fixture(scope="session")
def corpus():
    return load_contract("corpus.json")


@pytest.fixture(scope="session")
def curated():
    return load_contract("curated.json")


def pytest_generate_tests(metafunc):
    if "normalize_case" in metafunc.fixturenames:
        cases = load_contract("corpus.json")["normalize"]
        metafunc.parametrize(
            "normalize_case", cases, ids=[repr(c["in"]) for c in cases]
        )
