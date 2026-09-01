"""Exercise library, live strength workouts and deterministic progress API."""

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness import (
    BodyIssuePayload,
    ExercisePatch,
    ExercisePayload,
    ExerciseSetupPatch,
    ExerciseSetupPayload,
    MergePayload,
    SessionCheckinPayload,
    StrengthSessionExercisePayload,
    StrengthSessionFinish,
    StrengthSessionPayload,
    StrengthSetComponentPayload,
    StrengthSetGroupPayload,
    WorkoutDefinitionPayload,
    WorkoutVersionPayload,
)
from app.services.fitness import strength, templates
from app.services.fitness.common import (
    CanonicalIdentityChangedError,
    FitnessConflictError,
    FitnessNotFoundError,
)

router = APIRouter()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, CanonicalIdentityChangedError):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "canonical_identity_changed",
                "entity_type": exc.entity_type,
                "target_id": exc.target_id,
                "target_summary": exc.target_summary,
            },
        ) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if isinstance(exc, ValueError):
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    raise exc


async def _commit(db, operation):
    try:
        result = await operation
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/exercises")
async def exercises(
    q: str | None = Query(default=None, max_length=200),
    favourites: bool = False,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.list_exercises(db, user=current_user, query=q, favourites=favourites)


@router.post("/exercises", status_code=status.HTTP_201_CREATED)
async def create_exercise(
    body: ExercisePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, strength.upsert_exercise(db, user=current_user, body=body))


@router.post("/exercises/merge/preview")
async def preview_exercise_merge(
    body: MergePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await strength.preview_exercise_merge(
            db,
            user=current_user,
            source_id=str(body.source_id),
            target_id=str(body.target_id),
        )
    except Exception as exc:
        _raise_domain(exc)


@router.post("/exercises/merge")
async def merge_exercises(
    body: MergePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.merge_exercises(
            db,
            user=current_user,
            source_id=str(body.source_id),
            target_id=str(body.target_id),
        ),
    )


@router.get("/exercises/{exercise_id}")
async def exercise(
    exercise_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await strength.get_exercise(db, user=current_user, exercise_id=exercise_id)
    except Exception as exc:
        _raise_domain(exc)


@router.patch("/exercises/{exercise_id}")
async def update_exercise(
    exercise_id: str,
    body: ExercisePatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.patch_exercise(db, user=current_user, exercise_id=exercise_id, body=body),
    )


@router.post("/exercises/{exercise_id}/favourite")
async def favourite_exercise(
    exercise_id: str,
    favourite: bool = True,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.set_exercise_favourite(
            db,
            user=current_user,
            exercise_id=exercise_id,
            favourite=favourite,
        ),
    )


@router.get("/exercise-setups")
async def exercise_setups(
    exercise_id: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.list_setups(db, user=current_user, exercise_id=exercise_id)


@router.post("/exercise-setups", status_code=status.HTTP_201_CREATED)
async def create_exercise_setup(
    body: ExerciseSetupPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, strength.upsert_setup(db, user=current_user, body=body))


@router.post("/exercise-setups/merge/preview")
async def preview_setup_merge(
    body: MergePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await strength.preview_setup_merge(
            db,
            user=current_user,
            source_id=str(body.source_id),
            target_id=str(body.target_id),
        )
    except Exception as exc:
        _raise_domain(exc)


@router.post("/exercise-setups/merge")
async def merge_setups(
    body: MergePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.merge_setups(
            db,
            user=current_user,
            source_id=str(body.source_id),
            target_id=str(body.target_id),
        ),
    )


@router.patch("/exercise-setups/{setup_id}")
async def update_exercise_setup(
    setup_id: str,
    body: ExerciseSetupPatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.patch_setup(db, user=current_user, setup_id=setup_id, body=body),
    )


@router.get("/workout-definitions")
async def workout_definitions(
    sport_key: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await templates.list_workout_definitions(db, user=current_user, sport_key=sport_key)


@router.post("/workout-definitions", status_code=status.HTTP_201_CREATED)
async def create_workout_definition(
    body: WorkoutDefinitionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        templates.upsert_workout_definition(db, user=current_user, body=body),
    )


@router.patch("/workout-definitions/{definition_id}")
async def update_workout_definition(
    definition_id: str,
    body: WorkoutDefinitionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        templates.upsert_workout_definition(
            db, user=current_user, body=body, record_id=definition_id
        ),
    )


@router.post(
    "/workout-definitions/{definition_id}/versions",
    status_code=status.HTTP_201_CREATED,
)
async def create_workout_definition_version(
    definition_id: str,
    body: WorkoutVersionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        templates.create_workout_version(
            db, user=current_user, definition_id=definition_id, body=body
        ),
    )


@router.get("/strength/templates")
async def strength_templates(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await templates.list_workout_definitions(db, user=current_user, sport_key="strength")


@router.post("/strength/templates", status_code=status.HTTP_201_CREATED)
async def create_strength_template(
    body: WorkoutDefinitionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if body.sport_key != "strength":
        raise HTTPException(
            status_code=422, detail="A strength template must use sport_key strength"
        )
    return await _commit(
        db,
        templates.upsert_workout_definition(db, user=current_user, body=body),
    )


@router.post(
    "/strength/templates/{definition_id}/versions",
    status_code=status.HTTP_201_CREATED,
)
async def create_strength_template_version(
    definition_id: str,
    body: WorkoutVersionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        templates.create_workout_version(
            db,
            user=current_user,
            definition_id=definition_id,
            body=body,
            sport_key="strength",
        ),
    )


@router.post("/strength/templates/{definition_id}/copy")
async def copy_strength_template(
    definition_id: str,
    version_id: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await templates.copy_workout_version(
            db,
            user=current_user,
            definition_id=definition_id,
            version_id=version_id,
        )
    except Exception as exc:
        _raise_domain(exc)


@router.get("/strength/sessions")
async def strength_sessions(
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=100),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await strength.list_strength_sessions(
        db, user=current_user, offset=offset, limit=limit
    )
    await db.commit()
    return result


@router.get("/strength/suggestions")
async def strength_suggestions(
    available_minutes: int | None = Query(default=None, ge=10, le=240),
    equipment: list[str] = Query(default=[]),
    limit: int = Query(default=8, ge=1, le=20),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.strength_suggestions(
        db,
        user=current_user,
        available_minutes=available_minutes,
        equipment=equipment,
        limit=limit,
    )


@router.post("/strength/sessions", status_code=status.HTTP_201_CREATED)
async def create_strength_session(
    body: StrengthSessionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, strength.upsert_strength_session(db, user=current_user, body=body))


@router.get("/strength/sessions/{session_id}")
async def strength_session(
    session_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await strength.get_strength_session(db, user=current_user, activity_id=session_id)
        await db.commit()
        return result
    except Exception as exc:
        _raise_domain(exc)


@router.patch("/strength/sessions/{session_id}")
async def update_strength_session(
    session_id: str,
    body: StrengthSessionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.upsert_strength_session(db, user=current_user, body=body, record_id=session_id),
    )


@router.post("/strength/sessions/{session_id}/exercises", status_code=status.HTTP_201_CREATED)
async def add_session_exercise(
    session_id: str,
    body: StrengthSessionExercisePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if str(body.activity_id) != session_id:
        raise HTTPException(status_code=422, detail="activity_id must match session_id")
    return await _commit(db, strength.upsert_session_exercise(db, user=current_user, body=body))


@router.post(
    "/strength/session-exercises/{exercise_id}/set-groups", status_code=status.HTTP_201_CREATED
)
async def add_set_group(
    exercise_id: str,
    body: StrengthSetGroupPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if str(body.session_exercise_id) != exercise_id:
        raise HTTPException(status_code=422, detail="session_exercise_id must match path")
    return await _commit(db, strength.upsert_set_group(db, user=current_user, body=body))


@router.patch("/strength/set-groups/{group_id}")
async def update_set_group(
    group_id: str,
    body: StrengthSetGroupPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.upsert_set_group(db, user=current_user, body=body, record_id=group_id),
    )


@router.post("/strength/set-groups/{group_id}/components", status_code=status.HTTP_201_CREATED)
async def add_set_component(
    group_id: str,
    body: StrengthSetComponentPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if str(body.set_group_id) != group_id:
        raise HTTPException(status_code=422, detail="set_group_id must match path")
    return await _commit(db, strength.upsert_set_component(db, user=current_user, body=body))


@router.patch("/strength/set-components/{component_id}")
async def update_set_component(
    component_id: str,
    body: StrengthSetComponentPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.upsert_set_component(db, user=current_user, body=body, record_id=component_id),
    )


@router.delete("/strength/set-groups/{group_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_set_group(
    group_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _commit(db, strength.delete_set_group(db, user=current_user, group_id=group_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/strength/sessions/{session_id}/finish")
async def finish_session(
    session_id: str,
    body: StrengthSessionFinish,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.finish_strength_session(db, user=current_user, activity_id=session_id, body=body),
    )


@router.get("/session-checkins")
async def session_checkins(
    activity_id: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.list_checkins(db, user=current_user, activity_id=activity_id)


@router.post("/session-checkins", status_code=status.HTTP_201_CREATED)
async def create_session_checkin(
    body: SessionCheckinPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, strength.upsert_checkin(db, user=current_user, body=body))


@router.patch("/session-checkins/{checkin_id}")
async def update_session_checkin(
    checkin_id: str,
    body: SessionCheckinPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.upsert_checkin(db, user=current_user, body=body, record_id=checkin_id),
    )


@router.get("/body-issues")
async def body_issues(
    active_only: bool = False,
    activity_id: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.list_body_issues(
        db,
        user=current_user,
        active_only=active_only,
        activity_id=activity_id,
    )


@router.get("/body-locations")
async def body_locations(
    _current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.list_body_locations(db)


@router.post("/body-issues", status_code=status.HTTP_201_CREATED)
async def create_body_issue(
    body: BodyIssuePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, strength.upsert_body_issue(db, user=current_user, body=body))


@router.patch("/body-issues/{issue_id}")
async def update_body_issue(
    issue_id: str,
    body: BodyIssuePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        strength.upsert_body_issue(db, user=current_user, body=body, record_id=issue_id),
    )


@router.delete("/body-issues/{issue_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_body_issue(
    issue_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _commit(db, strength.delete_body_issue(db, user=current_user, issue_id=issue_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/strength/exercises/{exercise_id}/progress")
async def strength_exercise_progress(
    exercise_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await strength.exercise_progress(db, user=current_user, exercise_id=exercise_id)
    except Exception as exc:
        _raise_domain(exc)


@router.get("/strength/muscle-groups")
async def strength_muscle_groups(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strength.muscle_group_summary(db, user=current_user)
