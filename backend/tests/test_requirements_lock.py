"""Drift guard for the hashed dependency locks (review finding M-4).

``requirements.txt`` lists the direct runtime dependencies. The Lambda layer
is built from ``requirements-lock.txt`` (the whole tree, pinned with hashes)
by ``scripts/build_layer.sh``, and CI installs ``requirements-dev.txt``. These
tests fail when the three files, or the build script, drift apart.
"""

import re
from pathlib import Path

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]

_NAME_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*==\s*([^\s;\\]+)")
_HASH_RE = re.compile(r"--hash=sha256:([0-9a-f]{64})")


def _normalise(name):
    """Return the PEP 503 normalised form of a project name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def _logical_lines(path):
    """Yield requirement lines with comments stripped and continuations joined."""
    buf = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = re.sub(r"(^|\s)#.*$", "", raw).rstrip()
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        if buf.strip():
            yield buf.strip()
        buf = ""
    if buf.strip():
        yield buf.strip()


def parse_requirements(path):
    """Return ``{name: (version, frozenset(hashes))}`` for the ``==`` pins in ``path``.

    Option lines (``-r``, ``-c``, ``--...``) are skipped; they are not pins.
    """
    pins = {}
    for line in _logical_lines(path):
        if line.startswith("-"):
            continue
        match = _NAME_RE.match(line)
        assert match, f"{path.name}: unpinned or unparseable requirement: {line!r}"
        name = _normalise(match.group(1))
        assert name not in pins, f"{path.name}: duplicate pin for {name}"
        pins[name] = (match.group(3), frozenset(_HASH_RE.findall(line)))
    return pins


def test_lock_pins_every_direct_dependency_at_the_same_version():
    direct = parse_requirements(BACKEND_DIR / "requirements.txt")
    lock = parse_requirements(BACKEND_DIR / "requirements-lock.txt")
    assert direct, "requirements.txt has no pins"
    for name, (version, _) in direct.items():
        assert name in lock, f"{name} is missing from requirements-lock.txt"
        assert lock[name][0] == version, (
            f"{name}: requirements.txt pins {version}, "
            f"requirements-lock.txt pins {lock[name][0]}"
        )


def test_every_lock_entry_is_hashed():
    lock = parse_requirements(BACKEND_DIR / "requirements-lock.txt")
    for name, (_, hashes) in lock.items():
        assert hashes, f"{name} has no --hash in requirements-lock.txt"


def test_dev_requirements_match_the_lock_versions_and_hashes():
    lock = parse_requirements(BACKEND_DIR / "requirements-lock.txt")
    dev = parse_requirements(BACKEND_DIR / "requirements-dev.txt")
    for name, (version, hashes) in lock.items():
        assert name in dev, f"{name} is missing from requirements-dev.txt"
        dev_version, dev_hashes = dev[name]
        assert dev_version == version, (
            f"{name}: requirements-lock.txt pins {version}, "
            f"requirements-dev.txt pins {dev_version}"
        )
        assert dev_hashes == hashes, (
            f"{name}: hash sets differ between requirements-lock.txt "
            f"and requirements-dev.txt"
        )


def test_build_layer_installs_the_lock_with_require_hashes():
    script = (BACKEND_DIR / "scripts" / "build_layer.sh").read_text(encoding="utf-8")
    code = "\n".join(
        line for line in script.splitlines() if not line.lstrip().startswith("#")
    )
    assert "--require-hashes" in code
    assert re.search(r"-r\s+requirements-lock\.txt\b", code)
    assert not re.search(r"-r\s+requirements\.txt\b", code)


# --- The parser the guards above rely on ------------------------------------

_HASH_A = "a" * 64
_HASH_B = "b" * 64


def test_parser_reads_hashed_continuation_lines(tmp_path):
    lock = tmp_path / "lock.txt"
    lock.write_text(
        "# header comment\n"
        "-c other.txt\n"
        "--index-url https://example.invalid/simple\n"
        "Rpds_Py==1.2.3 \\\n"
        f"    --hash=sha256:{_HASH_A} \\\n"
        f"    --hash=sha256:{_HASH_B}\n"
        "    # via referencing\n"
        "moto[dynamodb,s3]==5.2.3 ; python_version >= '3.9' \\\n"
        f"    --hash=sha256:{_HASH_A}\n",
        encoding="utf-8",
    )
    assert parse_requirements(lock) == {
        "rpds-py": ("1.2.3", frozenset({_HASH_A, _HASH_B})),
        "moto": ("5.2.3", frozenset({_HASH_A})),
    }


def test_parser_reports_an_unhashed_pin_as_hashless(tmp_path):
    lock = tmp_path / "lock.txt"
    lock.write_text("six==1.17.0\n", encoding="utf-8")
    assert parse_requirements(lock) == {"six": ("1.17.0", frozenset())}


def test_parser_rejects_an_unpinned_requirement(tmp_path):
    lock = tmp_path / "lock.txt"
    lock.write_text("attrs>=26\n", encoding="utf-8")
    with pytest.raises(AssertionError, match="unpinned"):
        parse_requirements(lock)


def test_parser_rejects_a_duplicate_pin(tmp_path):
    lock = tmp_path / "lock.txt"
    lock.write_text("six==1.17.0\nSix==1.16.0\n", encoding="utf-8")
    with pytest.raises(AssertionError, match="duplicate"):
        parse_requirements(lock)
