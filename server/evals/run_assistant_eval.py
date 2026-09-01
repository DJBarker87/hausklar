#!/usr/bin/env python3
"""Run the 100-case assistant catalogue without persisting or executing actions."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).parent))
from assistant_scenarios import SCENARIOS  # noqa: E402

REFUSAL_WORDS = re.compile(
    r"\b(can(?:not|['’]t)|unable|not able|not available|not permitted|do not have|"
    r"don['’]t have|won['’]t|will not|unsupported|cannot help|can['’]t help)\b",
    flags=re.IGNORECASE,
)
CLARIFICATION_WORDS = re.compile(
    r"\b(which|what|when|where|who|need|detail|clarif|day|date|time|mean)\b",
    flags=re.IGNORECASE,
)
GERMAN_WORDS = re.compile(
    r"\b(ich|du|dir|das|die|der|ein|eine|für|ist|sind|kann|können|bitte|"
    r"bereit|nicht|noch|wird|habe|haben|am|um|und|oder|wir|ihr)\b",
    flags=re.IGNORECASE,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://hausklar.example.invalid/api")
    parser.add_argument("--email", default=os.environ.get("HAUSKLAR_EVAL_EMAIL"))
    parser.add_argument("--password", default=os.environ.get("HAUSKLAR_EVAL_PASSWORD"))
    parser.add_argument(
        "--concurrency",
        type=int,
        default=1,
        choices=(1, 2),
        help="Use 1 for the production bridge; 2 is reserved for contention testing.",
    )
    parser.add_argument("--category")
    parser.add_argument("--ids", help="Comma-separated scenario IDs")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--output")
    return parser.parse_args()


def assess(scenario: dict, status_code: int, body: dict) -> tuple[bool, list[str]]:
    failures: list[str] = []
    if status_code != 200:
        return False, [f"HTTP {status_code}: {body.get('detail', 'unknown error')}"]

    answer = body.get("answer")
    actions = body.get("actions")
    if not isinstance(answer, str) or len(answer.strip()) < 8:
        failures.append("missing or trivial answer")
    if scenario.get("language") == "de" and isinstance(answer, str):
        if not GERMAN_WORDS.search(answer):
            failures.append("response was not recognisably German")
    if not isinstance(actions, list):
        return False, failures + ["actions is not an array"]

    actual_actions = [item.get("kind") for item in actions if isinstance(item, dict)]
    expected = scenario["expect"]
    if expected == "action":
        if not actual_actions:
            failures.append("expected at least one action")
        unexpected = set(actual_actions) - set(scenario["allowed_actions"])
        if unexpected:
            failures.append(f"unexpected actions: {sorted(unexpected)}")
        missing = set(scenario["required_actions"]) - set(actual_actions)
        if missing:
            failures.append(f"missing actions: {sorted(missing)}")
    else:
        allowed = set(scenario["allowed_actions"])
        unexpected = set(actual_actions) - allowed
        if unexpected or (actual_actions and not allowed):
            failures.append(f"unexpected actions: {actual_actions}")
        if expected == "refusal" and isinstance(answer, str) and not REFUSAL_WORDS.search(answer):
            failures.append("response did not clearly refuse the request")
        if expected == "clarification" and isinstance(answer, str):
            if "?" not in answer and not CLARIFICATION_WORDS.search(answer):
                failures.append("response did not clearly request clarification")
    return not failures, failures


async def login(client: httpx.AsyncClient, args: argparse.Namespace) -> str:
    if not args.email or not args.password:
        raise SystemExit("Set HAUSKLAR_EVAL_EMAIL and HAUSKLAR_EVAL_PASSWORD")
    response = await client.post(
        f"{args.base_url.rstrip('/')}/auth/login",
        json={"email": args.email, "password": args.password},
    )
    response.raise_for_status()
    return response.json()["access_token"]


async def run_case(
    client: httpx.AsyncClient,
    semaphore: asyncio.Semaphore,
    base_url: str,
    headers: dict[str, str],
    item: dict,
) -> dict:
    payload = {
        "message": item["prompt"],
        "history": item["history"],
        "client_now": datetime.now(timezone.utc).isoformat(),
        "timezone": "Europe/London",
        "dry_run": True,
    }
    queued_at = time.monotonic()
    status_code = 0
    body: dict = {}
    error = None
    async with semaphore:
        started = time.monotonic()
        for attempt in range(3):
            try:
                response = await client.post(
                    f"{base_url.rstrip('/')}/assistant/message",
                    headers=headers,
                    json=payload,
                )
                status_code = response.status_code
                body = response.json()
                # A 429 is a durable budget decision. Retrying it immediately only
                # burns more evaluator time and can conceal an invalid test setup.
                if status_code not in {502, 503, 504}:
                    break
            except (httpx.HTTPError, ValueError) as exc:
                error = str(exc)
            await asyncio.sleep(2**attempt)
        finished = time.monotonic()

    passed, failures = assess(item, status_code, body)
    if error and not body:
        failures.append(error)
        passed = False
    return {
        **item,
        "passed": passed,
        "failures": failures,
        "status_code": status_code,
        "latency_seconds": round(finished - started, 3),
        "queue_wait_seconds": round(started - queued_at, 3),
        "response": body,
    }


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(len(ordered) * percentile))
    return round(ordered[index], 3)


async def main() -> int:
    args = parse_args()
    selected = [
        item for item in SCENARIOS if not args.category or item["category"] == args.category
    ]
    if args.ids:
        requested_ids = {value.strip() for value in args.ids.split(",") if value.strip()}
        selected = [item for item in selected if item["id"] in requested_ids]
    if args.limit:
        selected = selected[: args.limit]

    timeout = httpx.Timeout(150.0, connect=20.0)
    evaluation_started = time.monotonic()
    async with httpx.AsyncClient(timeout=timeout) as client:
        token = await login(client, args)
        headers = {"Authorization": f"Bearer {token}"}
        semaphore = asyncio.Semaphore(args.concurrency)
        tasks = [
            asyncio.create_task(
                run_case(client, semaphore, args.base_url, headers, item)
            )
            for item in selected
        ]
        results = []
        for completed, task in enumerate(asyncio.as_completed(tasks), start=1):
            result = await task
            results.append(result)
            marker = "PASS" if result["passed"] else "FAIL"
            print(f"[{completed:03d}/{len(tasks):03d}] {marker} {result['id']} {result['prompt']}")

    results.sort(key=lambda item: item["id"])
    passed = sum(item["passed"] for item in results)
    category_counts = Counter(item["category"] for item in results)
    category_passes = Counter(item["category"] for item in results if item["passed"])
    latencies = [item["latency_seconds"] for item in results]
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "base_url": args.base_url,
        "dry_run": True,
        "summary": {
            "total": len(results),
            "passed": passed,
            "failed": len(results) - passed,
            "wall_seconds": round(time.monotonic() - evaluation_started, 3),
            "latency_seconds": {
                "min": min(latencies, default=None),
                "median": _percentile(latencies, 0.5),
                "p95": _percentile(latencies, 0.95),
                "max": max(latencies, default=None),
                "mean": round(sum(latencies) / len(latencies), 3) if latencies else None,
            },
            "by_category": {
                category: {
                    "passed": category_passes[category],
                    "total": category_counts[category],
                }
                for category in sorted(category_counts)
            },
        },
        "results": results,
    }

    output = args.output
    if not output:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output = str(Path(__file__).parent / "results" / f"assistant-eval-{stamp}.json")
    output_path = Path(output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"\n{passed}/{len(results)} passed. Report: {output_path}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
