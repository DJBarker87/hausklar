"""Pydantic models for the family members endpoint."""

from pydantic import BaseModel


class FamilyMemberResponse(BaseModel):
    id: str
    name: str
    member_type: str  # 'user' or 'child'
    avatar_url: str | None = None
