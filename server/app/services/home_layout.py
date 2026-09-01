"""Fictional fallback layout for unconfigured/demo Home Assistant screens."""

from app.models.home import HomeLayoutResponse


HOME_LAYOUT = HomeLayoutResponse.model_validate(
    {
        "width": 900,
        "height": 820,
        "floors": [
            {
                "id": 0,
                "name": "Example floor",
                "rooms": [
                    {
                        "id": "example_living_room",
                        "label": "Example Living Room",
                        "bounds": {"x": 100, "y": 180, "width": 350, "height": 440},
                        "light_entity_ids": ["light.example_living_room"],
                        "label_at": [275, 400],
                    },
                    {
                        "id": "example_kitchen",
                        "label": "Example Kitchen",
                        "bounds": {"x": 450, "y": 180, "width": 350, "height": 440},
                        "light_entity_ids": [],
                        "label_at": [625, 400],
                    },
                ],
                "walls": [
                    [100, 180, 800, 180],
                    [800, 180, 800, 620],
                    [800, 620, 100, 620],
                    [100, 620, 100, 180],
                    [450, 180, 450, 620],
                ],
                "stairs": [],
            },
            {"id": 1, "name": "Unused example floor", "rooms": [], "walls": [], "stairs": []},
        ],
        "temperatures": [
            {"floor": 0, "entity_ids": ["sensor.example_temperature"], "at": [625, 400]},
        ],
        "doors": [
            {
                "floor": 0,
                "entity_ids": ["binary_sensor.example_front_door"],
                "at": [450, 620],
                "label": "Example Front Door",
            },
        ],
    }
)
