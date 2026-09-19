"""Persistence for capability artifacts: file-based, versioned, reviewable."""

from __future__ import annotations

import json
from pathlib import Path
from typing import List

from .schema import CapabilityArtifact


class ArtifactStore:
    """File-backed store. Each artifact is a JSON file named <id>.json."""

    def __init__(self, root: Path | str = "artifacts"):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, artifact_id: str) -> Path:
        return self.root / f"{artifact_id}.json"

    def save(self, artifact: CapabilityArtifact) -> Path:
        path = self._path(artifact.id)
        path.write_text(
            json.dumps(artifact.model_dump(mode="json"), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    def load(self, artifact_id: str) -> CapabilityArtifact:
        path = self._path(artifact_id)
        if not path.exists():
            raise FileNotFoundError(f"No artifact at {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        return CapabilityArtifact.model_validate(data)

    def list_ids(self) -> List[str]:
        return sorted(p.stem for p in self.root.glob("*.json"))

    def exists(self, artifact_id: str) -> bool:
        return self._path(artifact_id).exists()