from fastapi import HTTPException

def require_host_integration_admin(current_user: dict) -> None:
    """Restrict household integrations to an administrator of that household."""
    if current_user.get("role") != "admin":
        raise HTTPException(
            status_code=403,
            detail="This integration is available only to a household administrator",
        )
