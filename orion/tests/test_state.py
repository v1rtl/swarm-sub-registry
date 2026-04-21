"""Tests for orion.state — atomic JSON file I/O.

state.py has a real implementation (it's the one primitive the rest of
the harness can't work around), so these tests run for real rather than
being stubs.
"""

from pathlib import Path

from orion.state import read, write


def test_write_read_roundtrip(tmp_path: Path) -> None:
    path = tmp_path / "deployment.json"
    data = {"chain_id": 1337, "contracts": {"Token": "0xabc"}}

    write(path, data)

    assert read(path) == data


def test_write_does_not_leave_tmp_after_success(tmp_path: Path) -> None:
    """The .tmp handoff must complete — no half-written state lingering."""
    path = tmp_path / "state.json"

    write(path, {"a": 1})

    assert path.exists()
    assert not (tmp_path / "state.json.tmp").exists()


def test_write_creates_parent_dirs(tmp_path: Path) -> None:
    path = tmp_path / "deep" / "nested" / "state.json"

    write(path, {"k": "v"})

    assert read(path) == {"k": "v"}


def test_write_sorts_keys(tmp_path: Path) -> None:
    """Sorted keys keep state.json diffs reviewable across runs."""
    path = tmp_path / "s.json"
    write(path, {"z": 1, "a": 2})

    contents = path.read_text()
    assert contents.index('"a"') < contents.index('"z"')


def test_write_overwrites_existing(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    write(path, {"v": 1})
    write(path, {"v": 2})

    assert read(path) == {"v": 2}
