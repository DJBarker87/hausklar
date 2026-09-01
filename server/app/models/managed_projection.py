"""Safe links for authenticated records projected into Calendar and Tasks."""

from typing import Literal

from pydantic import BaseModel


class ManagedSource(BaseModel):
    kind: Literal[
        "finance_commitment",
        "finance_renewal",
        "finance_order",
        "library_loan",
        "school_club",
        "toast_club",
    ]
    source_id: str
    deep_link: str
    label: str
