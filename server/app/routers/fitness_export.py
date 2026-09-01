"""Authenticated owner-private Fitness export."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from app.auth import get_current_user
from app.database import get_db
from app.services.fitness.data_export import build_fitness_export


router = APIRouter()


@router.get("/export")
async def export_fitness_data(
    current_user: dict = Depends(get_current_user), db=Depends(get_db)
):
    archive = await build_fitness_export(db, user=current_user)

    def chunks():
        try:
            while chunk := archive.read(256 * 1024):
                yield chunk
        finally:
            archive.close()

    filename = f"hausklar-fitness-export-{datetime.now(timezone.utc).date().isoformat()}.zip"
    return StreamingResponse(
        chunks(),
        media_type="application/zip",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Cache-Control": "private, no-store",
        },
    )
