"""First-class term-time school clubs."""

from datetime import date

from fastapi import APIRouter, Depends, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.school_club import (
    SchoolClubCancellation,
    SchoolClubCancellationResponse,
    SchoolClubCreate,
    SchoolClubResponse,
    SchoolClubUpdate,
)
from app.services import school_clubs


router = APIRouter()


@router.get("/", response_model=list[SchoolClubResponse])
async def list_school_clubs(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await school_clubs.list_clubs(db, family_id=current_user["family_id"])


@router.post("/", response_model=SchoolClubResponse, status_code=status.HTTP_201_CREATED)
async def create_school_club(
    body: SchoolClubCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await school_clubs.create_club(db, current_user=current_user, body=body)


@router.put("/{club_id}", response_model=SchoolClubResponse)
async def update_school_club(
    club_id: str,
    body: SchoolClubUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await school_clubs.update_club(
        db,
        current_user=current_user,
        club_id=club_id,
        body=body,
    )


@router.delete("/{club_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_school_club(
    club_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await school_clubs.delete_club(db, current_user=current_user, club_id=club_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put(
    "/{club_id}/dates/{occurrence_date}/cancel",
    response_model=SchoolClubCancellationResponse,
)
async def cancel_school_club_date(
    club_id: str,
    occurrence_date: date,
    body: SchoolClubCancellation,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await school_clubs.cancel_occurrence(
        db,
        current_user=current_user,
        club_id=club_id,
        occurrence_date=occurrence_date,
        body=body,
    )


@router.delete(
    "/{club_id}/dates/{occurrence_date}/cancel",
    response_model=SchoolClubCancellationResponse,
)
async def restore_school_club_date(
    club_id: str,
    occurrence_date: date,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await school_clubs.restore_occurrence(
        db,
        current_user=current_user,
        club_id=club_id,
        occurrence_date=occurrence_date,
    )
