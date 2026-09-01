"""Owner-private visibility preferences for the optional Fitness workspace."""

from pydantic import BaseModel, ConfigDict, StrictBool


class FitnessWorkspaceModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class FitnessWorkspaceUpdate(FitnessWorkspaceModel):
    enabled: StrictBool | None = None
    pinned: StrictBool | None = None
    show_nutrition_today: StrictBool | None = None


class FitnessWorkspaceResponse(FitnessWorkspaceModel):
    enabled: bool
    pinned: bool
    show_nutrition_today: bool
