"""Run the mock legacy bank app."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.target_app.app import app

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)