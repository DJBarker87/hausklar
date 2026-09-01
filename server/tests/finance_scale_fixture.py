"""Deterministic five-year, ten-account Finance performance fixture."""

from datetime import date, timedelta

from app.services.finance.foundation import accessible_finance_spaces

SCALE_START = date(2021, 8, 4)
SCALE_END = date(2026, 8, 3)
SCALE_ACCOUNT_COUNT = 10
SCALE_DAY_COUNT = (SCALE_END - SCALE_START).days + 1
SCALE_TRANSACTION_COUNT = SCALE_ACCOUNT_COUNT * SCALE_DAY_COUNT


async def seed_representative_finance_scale(db, *, user: dict) -> tuple[str, str]:
    """Insert deterministic rows with six personal and four household accounts."""
    spaces = {space.kind: space.id for space in await accessible_finance_spaces(db, user=user)}
    now = "2026-08-03T12:00:00+00:00"
    accounts = []
    for index in range(SCALE_ACCOUNT_COUNT):
        space_id = spaces["personal"] if index < 6 else spaces["household"]
        accounts.append(
            (
                f"scale-account-{index:02d}",
                space_id,
                f"Scale account {index:02d}",
                user["family_id"],
                now,
                now,
                user["id"],
            )
        )
    await db.executemany(
        """
        INSERT INTO finance_accounts
            (id, space_id, label, account_type, currency, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, 'CURRENT', 'GBP', ?, ?, ?, ?)
        """,
        accounts,
    )

    batch = []
    day = SCALE_START
    day_index = 0
    while day <= SCALE_END:
        for account_index, account in enumerate(accounts):
            account_id, space_id = account[0], account[1]
            amount_minor = -(100 + ((day_index * 17 + account_index * 101) % 9_900))
            description = (
                f"Scale marker {day.isoformat()}"
                if day_index == SCALE_DAY_COUNT - 1 and account_index == 0
                else f"Fixture merchant {account_index % 12:02d}"
            )
            batch.append(
                (
                    f"scale-tx-{day_index:04d}-{account_index:02d}",
                    space_id,
                    account_id,
                    day.isoformat(),
                    amount_minor,
                    description,
                    description.upper(),
                    now,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                )
            )
        if len(batch) >= 5_000:
            await db.executemany(
                """
                INSERT INTO finance_transactions
                    (id, space_id, account_id, canonical_date, amount_minor,
                     currency, state, transaction_kind, source_kind, description,
                     cleaned_description, data_through_at, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, 'GBP', 'POSTED', 'CASEY', 'MANUAL',
                        ?, ?, ?, ?, ?, ?, ?)
                """,
                batch,
            )
            batch.clear()
        day += timedelta(days=1)
        day_index += 1
    if batch:
        await db.executemany(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor,
                 currency, state, transaction_kind, source_kind, description,
                 cleaned_description, data_through_at, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, 'GBP', 'POSTED', 'CASEY', 'MANUAL',
                    ?, ?, ?, ?, ?, ?, ?)
            """,
            batch,
        )
    await db.commit()
    return spaces["personal"], spaces["household"]
