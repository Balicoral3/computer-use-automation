"""Pytest fixtures.

We spin the mock bank app in a background thread on a dynamic port and
launch a single Playwright Chromium instance for the whole session.
"""

from __future__ import annotations

import socket
import threading
import time

import pytest
from playwright.sync_api import sync_playwright
from werkzeug.serving import make_server


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="session")
def target_app_url():
    from src.target_app.app import app as flask_app

    flask_app.config["TESTING"] = True
    port = _free_port()
    server = make_server("127.0.0.1", port, flask_app, threaded=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    time.sleep(0.3)
    url = f"http://127.0.0.1:{port}"
    yield url
    server.shutdown()
    thread.join(timeout=2)


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        yield browser
        browser.close()


@pytest.fixture
def page(browser):
    ctx = browser.new_context(viewport={"width": 1280, "height": 800})
    p = ctx.new_page()
    p.set_default_timeout(8_000)
    yield p
    ctx.close()