"""Shared pytest setup: loads the acceptance cases from contract/."""

import json
from pathlib import Path
from typing import Any

import pytest

# tests -> backend -> repo root; resolved from this file so it never depends on the working directory.
CONTRACT_DIR = Path(__file__).resolve().parents[2] / "contract"


def load_contract(name: str) -> Any:
    """Read and parse a JSON file from contract/ (read-only)."""
    return json.loads((CONTRACT_DIR / name).read_text(encoding="utf-8"))


def pytest_generate_tests(metafunc: pytest.Metafunc) -> None:
    if "normalize_case" in metafunc.fixturenames:
        cases = load_contract("corpus.json")["normalize"]
        metafunc.parametrize("normalize_case", cases, ids=[repr(c["in"]) for c in cases])


@pytest.fixture
def normalize_cases() -> list:
    return load_contract("corpus.json")["normalize"]


@pytest.fixture
def curated() -> dict:
    return load_contract("curated.json")
