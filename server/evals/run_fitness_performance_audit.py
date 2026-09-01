#!/usr/bin/env python3
"""Read-only post-deploy latency and response-bound audit for Fitness screens."""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import httpx


@dataclass(frozen=True)
class ReadPath:
    name: str
    path: Callable[[date, str | None], str]
    cold_limit_ms: float
    warm_p95_limit_ms: float
    max_response_bytes: int
    validate: Callable[[Any], str | None]


@dataclass(frozen=True)
class Sample:
    elapsed_ms: float
    response_bytes: int
    body: Any


def _object_with(*keys: str) -> Callable[[Any], str | None]:
    def validate(body: Any) -> str | None:
        if not isinstance(body, dict):
            return "response is not an object"
        missing = set(keys) - set(body)
        return f"missing keys: {sorted(missing)}" if missing else None

    return validate


def _activity_history(body: Any) -> str | None:
    if not isinstance(body, list):
        return "response is not an array"
    if len(body) > 50:
        return f"returned {len(body)} activities; page limit is 50"
    if not body:
        return "no activity is available for the required detail audit"
    if not isinstance(body[0], dict) or not body[0].get("id"):
        return "first activity has no identifier"
    return None


READ_PATHS = (
    ReadPath(
        "overview",
        lambda day, _activity_id: f"/fitness/overview?date={day.isoformat()}",
        1_500,
        750,
        32 * 1_024,
        _object_with("date", "primary_action", "quick_actions"),
    ),
    ReadPath(
        "today_card",
        lambda day, _activity_id: f"/fitness/today-card?date={day.isoformat()}",
        1_000,
        500,
        16 * 1_024,
        _object_with("date", "primary_action"),
    ),
    ReadPath(
        "weekly_review",
        lambda day, _activity_id: (
            "/fitness/weekly-review?week_start="
            f"{(day - timedelta(days=day.weekday())).isoformat()}"
        ),
        1_500,
        750,
        64 * 1_024,
        _object_with("week_start", "week_end", "totals", "opportunity"),
    ),
    ReadPath(
        "activity_history",
        lambda _day, _activity_id: "/fitness/activities?offset=0&limit=50",
        2_500,
        1_250,
        512 * 1_024,
        _activity_history,
    ),
    ReadPath(
        "activity_detail",
        lambda _day, activity_id: f"/fitness/activities/{activity_id}",
        2_000,
        1_000,
        512 * 1_024,
        _object_with("activity", "summary_metrics", "available_stream_metrics"),
    ),
    ReadPath(
        "progress",
        lambda _day, _activity_id: "/fitness/progress",
        4_000,
        2_000,
        2 * 1_024 * 1_024,
        _object_with("goals", "weight_trend", "recent_activities", "exercise_progress"),
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Audit production Fitness GET endpoints. Coach context assembly remains in the "
            "local scale test so this runner never invokes Hermes."
        )
    )
    parser.add_argument("--base-url", default="https://hausklar.example.invalid/api")
    parser.add_argument("--email", default=os.environ.get("HAUSKLAR_PERF_EMAIL"))
    parser.add_argument("--password", default=os.environ.get("HAUSKLAR_PERF_PASSWORD"))
    parser.add_argument(
        "--access-token",
        default=os.environ.get("HAUSKLAR_PERF_ACCESS_TOKEN"),
        help="Use an existing short-lived token instead of creating a login session.",
    )
    parser.add_argument("--date", type=date.fromisoformat, default=datetime.now(timezone.utc).date())
    parser.add_argument("--runs", type=int, choices=range(3, 16), default=5)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--output")
    return parser.parse_args()


def _percentile(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * percentile) - 1)
    return ordered[index]


def _redact_activity_id(value: str, activity_id: str | None) -> str:
    return value.replace(activity_id, "<activity_id>") if activity_id else value


async def _token(args: argparse.Namespace) -> str:
    if args.access_token:
        return args.access_token
    if not args.email or not args.password:
        raise SystemExit(
            "Set HAUSKLAR_PERF_ACCESS_TOKEN or both HAUSKLAR_PERF_EMAIL and "
            "HAUSKLAR_PERF_PASSWORD"
        )
    timeout = httpx.Timeout(args.timeout)
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            f"{args.base_url.rstrip('/')}/auth/login",
            json={"email": args.email, "password": args.password},
        )
        response.raise_for_status()
        return response.json()["access_token"]


async def _sample(
    client: httpx.AsyncClient,
    *,
    base_url: str,
    path: str,
) -> Sample:
    started = time.perf_counter()
    response = await client.get(f"{base_url.rstrip('/')}{path}")
    elapsed_ms = (time.perf_counter() - started) * 1_000
    response.raise_for_status()
    try:
        body = response.json()
    except ValueError as exc:
        raise RuntimeError("response was not JSON") from exc
    return Sample(
        elapsed_ms=elapsed_ms,
        response_bytes=len(response.content),
        body=body,
    )


def _failure(path: ReadPath, cold: Sample, warm: list[Sample]) -> list[str]:
    failures = []
    shape_error = path.validate(cold.body)
    if shape_error:
        failures.append(shape_error)
    warm_p95 = _percentile([sample.elapsed_ms for sample in warm], 0.95)
    maximum_bytes = max([cold.response_bytes, *(sample.response_bytes for sample in warm)])
    if cold.elapsed_ms > path.cold_limit_ms:
        failures.append(
            f"cold {cold.elapsed_ms:.1f}ms exceeded {path.cold_limit_ms:.0f}ms"
        )
    if warm_p95 > path.warm_p95_limit_ms:
        failures.append(
            f"warm p95 {warm_p95:.1f}ms exceeded {path.warm_p95_limit_ms:.0f}ms"
        )
    if maximum_bytes > path.max_response_bytes:
        failures.append(
            f"response {maximum_bytes}B exceeded {path.max_response_bytes}B"
        )
    return failures


async def main() -> int:
    args = parse_args()
    token = await _token(args)
    headers = {"Authorization": f"Bearer {token}"}
    timeout = httpx.Timeout(args.timeout)
    activity_id = None
    results = []

    for path in READ_PATHS:
        if path.name == "activity_detail" and activity_id is None:
            results.append(
                {
                    "name": path.name,
                    "passed": False,
                    "failures": ["activity history supplied no detail target"],
                }
            )
            continue
        request_path = path.path(args.date, activity_id)
        report_path = _redact_activity_id(request_path, activity_id)
        try:
            async with httpx.AsyncClient(headers=headers, timeout=timeout) as cold_client:
                cold = await _sample(
                    cold_client,
                    base_url=args.base_url,
                    path=request_path,
                )
            async with httpx.AsyncClient(headers=headers, timeout=timeout) as warm_client:
                await _sample(warm_client, base_url=args.base_url, path=request_path)
                warm = [
                    await _sample(warm_client, base_url=args.base_url, path=request_path)
                    for _ in range(args.runs)
                ]
        except (httpx.HTTPError, RuntimeError) as exc:
            error = _redact_activity_id(str(exc), activity_id)
            results.append(
                {
                    "name": path.name,
                    "path": report_path,
                    "passed": False,
                    "failures": [error],
                }
            )
            print(f"FAIL {path.name}: {error}")
            continue
        failures = _failure(path, cold, warm)
        if path.name == "activity_history" and isinstance(cold.body, list) and cold.body:
            candidate = cold.body[0]
            if isinstance(candidate, dict) and candidate.get("id"):
                activity_id = str(candidate["id"])
        warm_values = [sample.elapsed_ms for sample in warm]
        result = {
            "name": path.name,
            "path": report_path,
            "passed": not failures,
            "failures": failures,
            "cold_ms": round(cold.elapsed_ms, 3),
            "warm_median_ms": round(_percentile(warm_values, 0.5), 3),
            "warm_p95_ms": round(_percentile(warm_values, 0.95), 3),
            "max_response_bytes": max(
                [cold.response_bytes, *(sample.response_bytes for sample in warm)]
            ),
            "limits": {
                "cold_ms": path.cold_limit_ms,
                "warm_p95_ms": path.warm_p95_limit_ms,
                "response_bytes": path.max_response_bytes,
            },
        }
        results.append(result)
        marker = "PASS" if result["passed"] else "FAIL"
        print(
            f"{marker} {path.name}: cold {result['cold_ms']:.1f}ms, "
            f"warm p95 {result['warm_p95_ms']:.1f}ms, "
            f"{result['max_response_bytes']}B"
        )

    passed = sum(result["passed"] for result in results)
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "base_url": args.base_url,
        "reference_date": args.date.isoformat(),
        "read_only_fitness_requests": True,
        "coach_context": "covered locally without Hermes",
        "summary": {
            "passed": passed,
            "failed": len(results) - passed,
            "total": len(results),
            "warm_runs": args.runs,
        },
        "results": results,
    }
    output = args.output
    if not output:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output = str(
            Path(__file__).parent
            / "results"
            / f"fitness-performance-audit-{stamp}.json"
        )
    output_path = Path(output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{passed}/{len(results)} passed. Report: {output_path}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
