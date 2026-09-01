"""Consumer-facing contracts for the owner-private Fitness first run."""

from datetime import date, datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field, StrictBool

from app.models.fitness import FitnessModel


DayName = Literal[
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
]
TimeOfDay = Literal["Morning", "Lunchtime", "Evening", "Flexible"]
MainOutcome = Literal[
    "Feel fitter",
    "Build strength",
    "Run further",
    "Improve energy",
    "Support my weight",
    "Move consistently",
]
ActivityName = Literal[
    "Walking",
    "Running",
    "Strength",
    "Cycling",
    "Swimming",
    "Mobility",
]
SourceConnection = Literal["Apple Health", "Garmin", "Withings", "Intervals.icu"]
CoachStyle = Literal[
    "Calm and encouraging",
    "Balanced and practical",
    "Direct and challenging",
]
PreferenceText = Annotated[str, Field(min_length=1, max_length=120)]


class OnboardingAvailability(FitnessModel):
    day: DayName
    time_of_day: TimeOfDay
    duration_minutes: int = Field(ge=10, le=180)


class OnboardingDraftUpdate(FitnessModel):
    main_outcome: MainOutcome | None = None
    availability: list[OnboardingAvailability] | None = Field(default=None, max_length=14)
    activities: list[ActivityName] | None = Field(default=None, max_length=6)
    equipment: list[PreferenceText] | None = Field(default=None, max_length=30)
    food_preferences: list[PreferenceText] | None = Field(default=None, max_length=30)
    source_connections: list[SourceConnection] | None = Field(default=None, max_length=4)
    coach_style: CoachStyle | None = None
    use_family_calendar: StrictBool | None = None
    use_household_meals: StrictBool | None = None
    use_weather: StrictBool | None = None
    memory_enabled: StrictBool | None = None
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class OnboardingWeekSession(FitnessModel):
    day: DayName
    date: date
    start_time: str = Field(pattern=r"^\d{2}:\d{2}$")
    activity: ActivityName
    title: str
    duration_minutes: int
    reason: str


class OnboardingWeekPreview(FitnessModel):
    preview_id: UUID
    week_start: date
    summary: str
    sessions: list[OnboardingWeekSession]


class OnboardingConfirmation(FitnessModel):
    completed_at: datetime
    goal_id: UUID
    session_ids: list[UUID]


class OnboardingProfileResponse(FitnessModel):
    id: UUID
    status: Literal["draft", "skipped", "complete"]
    main_outcome: MainOutcome | None = None
    availability: list[OnboardingAvailability] = Field(default_factory=list)
    activities: list[ActivityName] = Field(default_factory=list)
    equipment: list[PreferenceText] = Field(default_factory=list)
    food_preferences: list[PreferenceText] = Field(default_factory=list)
    source_connections: list[SourceConnection] = Field(default_factory=list)
    coach_style: CoachStyle | None = None
    use_family_calendar: bool = False
    use_household_meals: bool = False
    use_weather: bool = False
    memory_enabled: bool = False
    preview: OnboardingWeekPreview | None = None
    confirmation: OnboardingConfirmation | None = None


class OnboardingPreviewRequest(FitnessModel):
    week_start: date | None = None


class OnboardingConfirmRequest(FitnessModel):
    preview_id: UUID


class OnboardingConfirmResponse(FitnessModel):
    status: Literal["complete"] = "complete"
    completed_at: datetime
    goal_id: UUID
    session_ids: list[UUID]
    week: OnboardingWeekPreview
