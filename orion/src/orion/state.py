"""Atomic JSON state-file read/write.

All state files in ``state/`` are written as ``*.json.tmp`` then renamed.
Never truncate-and-write-in-place — partial writes would break
re-attachment.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def read(path: Path) -> dict[str, Any]:
    with path.open("r") as f:
        return json.load(f)


def write(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tmp.open("w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
