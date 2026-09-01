"""Static release contracts for the isolated Fitness parser container."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_uvicorn_never_logs_callback_query_secrets():
    dockerfile = (ROOT / "server/Dockerfile").read_text()

    assert "--no-access-log" in dockerfile
