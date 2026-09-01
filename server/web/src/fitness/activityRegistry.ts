import type { FitnessActivityRegistry, FitnessActivitySportDefinition } from "./contract";

const fallbackSports: FitnessActivitySportDefinition[] = [
  { key: "running", display_name: "Running" },
  { key: "strength", display_name: "Strength" },
  { key: "walking", display_name: "Walking" },
  { key: "hiking", display_name: "Hiking" },
  { key: "cycling", display_name: "Cycling" },
  { key: "rowing_indoor", display_name: "Indoor rowing" },
  { key: "rowing_water", display_name: "Water rowing" },
  { key: "swimming_pool", display_name: "Pool swimming" },
  { key: "swimming_open_water", display_name: "Open-water swimming" },
  { key: "other", display_name: "Other activity" },
];

export const emptyActivityRegistry: FitnessActivityRegistry = { sports: [], metrics: [] };

export function activitySportOptions(
  registry: FitnessActivityRegistry,
  observedKeys: string[] = [],
): FitnessActivitySportDefinition[] {
  const options = new Map((registry.sports.length ? registry.sports : fallbackSports).map((sport) => [sport.key, sport]));
  observedKeys.forEach((key) => {
    if (key && !options.has(key)) options.set(key, { key, display_name: key.replaceAll("_", " ").replace(/^./, (value) => value.toUpperCase()) });
  });
  return [...options.values()];
}
