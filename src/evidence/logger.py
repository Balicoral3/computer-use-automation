"""Structured JSON logger + evidence writer."""

from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

from ..safety.redaction import redact_value


class RunLogger:
    def __init__(self, root: Path | str = "evidence", run_id: Optional[str] = None,
                 kind: str = "run") -> None:
        self.root = Path(root)
        self.run_id = run_id or f"{kind}-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.dir = self.root / self.run_id
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "screenshots").mkdir(exist_ok=True)
        (self.dir / "dom").mkdir(exist_ok=True)
        self._log_path = self.dir / "run.jsonl"
        self._t0 = time.time()

    def log(self, event: str, **fields: Any) -> None:
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "t_rel": round(time.time() - self._t0, 3),
            "run_id": self.run_id,
            "event": event,
            **{k: redact_value(v) for k, v in fields.items()},
        }
        with self._log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def screenshot_path(self, name: str) -> Path:
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)
        return self.dir / "screenshots" / f"{safe}.png"

    def dom_path(self, name: str) -> Path:
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)
        return self.dir / "dom" / f"{safe}.html"

    def write_result(self, result: Dict[str, Any]) -> Path:
        path = self.dir / "result.json"
        path.write_text(
            json.dumps(redact_value(result), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    @property
    def path(self) -> Path:
        return self.dir