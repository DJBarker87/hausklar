import pytest

from app.db.bootstrap_family import validate_password


def test_bootstrap_has_no_default_password():
    with pytest.raises(ValueError):
        validate_password("", ["Example Household", "Alex Example"])


@pytest.mark.parametrize("password", ["password", "password123", "hausklar"])
def test_bootstrap_rejects_common_passwords(password):
    with pytest.raises(ValueError):
        validate_password(password, ["Example Household", "Alex Example"])
