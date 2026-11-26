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


def test_short_host_reduces_a_fargate_name_to_its_ip():
    from main import _short_host

    assert _short_host("ip-10-42-10-168.eu-central-1.compute.internal") == "10.42.10.168"
    assert _short_host("ip-10-42-11-9.eu-central-1.compute.internal") == "10.42.11.9"


def test_short_host_leaves_anything_else_alone():
    from main import _short_host

    # A local container id, and a name that only looks like a Fargate one.
    assert _short_host("4f3c9a1b2d7e") == "4f3c9a1b2d7e"
    assert _short_host("ip-weird.local") == "ip-weird.local"
    assert _short_host("ip-a-b-c-d.eu-central-1.compute.internal") == (
        "ip-a-b-c-d.eu-central-1.compute.internal"
    )
