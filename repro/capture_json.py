"""Read capture files written by capture-header.sh.

The header ends at a line that is exactly ``===== capture body =====``.
Everything after that line is the command's own output.
"""

from __future__ import annotations

import json
from pathlib import Path

BODY_MARK = "===== capture body ====="


def split_capture(text: str) -> str:
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.strip() == BODY_MARK:
            return "".join(lines[i + 1 :])
    return text


def load_capture_text(path) -> str:
    return split_capture(Path(path).read_text(errors="replace"))


def load_capture_json(path):
    text = load_capture_text(path).strip()
    if not text:
        return {"items": []}
    return json.loads(text)
