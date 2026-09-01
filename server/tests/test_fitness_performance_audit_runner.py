"""Hermetic contracts for the post-deploy Fitness performance runner."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "evals" / "run_fitness_performance_audit.py"
SPEC = importlib.util.spec_from_file_location("fitness_performance_audit", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


def test_remote_audit_covers_only_bounded_read_paths():
    assert [path.name for path in AUDIT.READ_PATHS] == [
        "overview",
        "today_card",
        "weekly_review",
        "activity_history",
        "activity_detail",
        "progress",
    ]
    assert all(path.max_response_bytes > 0 for path in AUDIT.READ_PATHS)
    assert all(path.cold_limit_ms >= path.warm_p95_limit_ms for path in AUDIT.READ_PATHS)
    assert "coach" not in {path.name for path in AUDIT.READ_PATHS}


def test_runner_thresholds_fail_closed_and_redact_activity_ids():
    path = AUDIT.ReadPath(
        "example",
        lambda _day, _activity_id: "/fitness/example",
        100,
        50,
        1_024,
        lambda body: None if body == {"ok": True} else "bad shape",
    )
    good = AUDIT.Sample(25, 100, {"ok": True})
    assert AUDIT._failure(path, good, [good, good, good]) == []

    bad = AUDIT.Sample(101, 1_025, {"ok": False})
    failures = AUDIT._failure(path, bad, [AUDIT.Sample(51, 1_025, {"ok": False})] * 3)
    assert any("bad shape" in failure for failure in failures)
    assert any("cold" in failure for failure in failures)
    assert any("warm p95" in failure for failure in failures)
    assert any("response" in failure for failure in failures)
    assert AUDIT._redact_activity_id(
        "/fitness/activities/private-id",
        "private-id",
    ) == "/fitness/activities/<activity_id>"


def test_runner_percentiles_use_nearest_rank():
    assert AUDIT._percentile([5.0, 1.0, 3.0], 0.5) == 3.0
    assert AUDIT._percentile([5.0, 1.0, 3.0], 0.95) == 5.0
