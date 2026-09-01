"""Apple Health webhook receiver for Health Auto Export app."""

import json
import uuid
from datetime import datetime, timezone


async def process_webhook(data: dict, db, family_id: str | None = None) -> dict:
    """Receive and process data from the Health Auto Export app.

    Expected payload format:
    {
        "data": {
            "metrics": [
                {
                    "name": "heart_rate",
                    "units": "bpm",
                    "data": [
                        {"date": "2026-01-15T10:30:00Z", "qty": 72.0}
                    ]
                },
                ...
            ]
        }
    }
    """
    metrics = data.get("data", {}).get("metrics", [])
    if not metrics:
        return {"status": "ignored", "reason": "no metrics in payload"}

    saved = []
    now = datetime.now(timezone.utc).isoformat()

    for metric in metrics:
        metric_name = metric.get("name", "unknown")
        metric_unit = metric.get("units", "")
        data_points = metric.get("data", [])

        for point in data_points:
            qty = point.get("qty")
            if qty is None:
                continue

            record_id = str(uuid.uuid4())
            recorded_at = point.get("date", now)

            metadata = json.dumps({
                "source_name": metric.get("name"),
                "original_unit": metric.get("units"),
            })

            await db.execute(
                """
                INSERT INTO health_data
                    (id, source, data_type, value, unit, recorded_at, metadata,
                     family_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record_id,
                    "apple_health",
                    metric_name,
                    float(qty),
                    metric_unit,
                    recorded_at,
                    metadata,
                    family_id,
                    now,
                    now,
                ),
            )
            saved.append(record_id)

    await db.commit()
    return {"status": "saved", "count": len(saved), "ids": saved}
