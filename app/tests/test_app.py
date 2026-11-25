"""Fast, deterministic tests. These gate every deployment."""
import os
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from main import app  # noqa: E402

client = TestClient(app)


def test_health_is_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_version_reports_commit_and_env():
    r = client.get("/version")
    assert r.status_code == 200
    body = r.json()
    for key in ("name", "version", "commit", "environment"):
        assert key in body


def test_index_greets_the_code_busters():
    r = client.get("/")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Code Busters" in r.text


def test_index_shows_the_running_commit():
    """The SHA on the page is the whole point of the live demo."""
    r = client.get("/")
    assert "Commit" in r.text


def test_unknown_path_is_404():
    assert client.get("/nope").status_code == 404
