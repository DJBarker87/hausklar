import type { FitnessActivityDetail } from "./contract";

export type FitnessActivityCapability =
  | "route"
  | "streams"
  | "intervals"
  | "plan"
  | "running_analysis"
  | "strength_summary";

export type FitnessActivityPanelDefinition = {
  key: string;
  label: string;
  supportedSportKeys: string[] | "any";
  requiredCapabilities: FitnessActivityCapability[];
  requiredMetrics: string[];
  optionalMetrics: string[];
  priority: number;
};

export const fitnessActivityPanelRegistry: FitnessActivityPanelDefinition[] = [
  {
    key: "route_map",
    label: "Route",
    supportedSportKeys: "any",
    requiredCapabilities: ["route"],
    requiredMetrics: [],
    optionalMetrics: ["pace_s_per_km", "heart_rate_bpm"],
    priority: 10,
  },
  {
    key: "synchronised_line_chart",
    label: "Streams",
    supportedSportKeys: "any",
    requiredCapabilities: ["streams"],
    requiredMetrics: [],
    optionalMetrics: ["pace_s_per_km", "heart_rate_bpm", "altitude_m", "cadence_spm", "power_w"],
    priority: 20,
  },
  {
    key: "split_table",
    label: "Laps and splits",
    supportedSportKeys: "any",
    requiredCapabilities: ["intervals"],
    requiredMetrics: [],
    optionalMetrics: ["pace_s_per_km", "heart_rate_bpm"],
    priority: 30,
  },
  {
    key: "run_pacing_analysis",
    label: "Pacing",
    supportedSportKeys: ["running", "trail_running", "treadmill_running"],
    requiredCapabilities: ["running_analysis"],
    requiredMetrics: [],
    optionalMetrics: ["pace_s_per_km", "speed_mps", "altitude_m"],
    priority: 40,
  },
  {
    key: "run_heart_rate_analysis",
    label: "Heart rate",
    supportedSportKeys: ["running", "trail_running", "treadmill_running"],
    requiredCapabilities: ["running_analysis"],
    requiredMetrics: ["heart_rate_bpm"],
    optionalMetrics: ["pace_s_per_km", "speed_mps"],
    priority: 50,
  },
  {
    key: "strength_exercise_summary",
    label: "Exercises",
    supportedSportKeys: ["strength", "strength_training"],
    requiredCapabilities: ["strength_summary"],
    requiredMetrics: [],
    optionalMetrics: ["strength.session_volume_kg", "strength.session_hard_sets"],
    priority: 40,
  },
  {
    key: "plan_adherence",
    label: "Plan execution",
    supportedSportKeys: "any",
    requiredCapabilities: ["plan"],
    requiredMetrics: [],
    optionalMetrics: [],
    priority: 60,
  },
];

function activityCapabilities(detail: FitnessActivityDetail): Set<FitnessActivityCapability> {
  const metrics = new Set(detail.available_stream_metrics);
  const sport = detail.activity.sport_key;
  const capabilities = new Set<FitnessActivityCapability>();
  if (
    (metrics.has("latitude_deg") && metrics.has("longitude_deg"))
    || (detail.activity.route_preview?.length ?? 0) > 1
  ) capabilities.add("route");
  if (detail.available_stream_metrics.length > 0) capabilities.add("streams");
  if (detail.intervals.length > 0) capabilities.add("intervals");
  if (detail.planned_session || detail.adherence) capabilities.add("plan");
  if (["running", "trail_running", "treadmill_running"].includes(sport)) capabilities.add("running_analysis");
  if (["strength", "strength_training"].includes(sport)) capabilities.add("strength_summary");
  return capabilities;
}

export function availableFitnessActivityPanels(
  detail: FitnessActivityDetail,
): FitnessActivityPanelDefinition[] {
  const capabilities = activityCapabilities(detail);
  const metrics = new Set(detail.available_stream_metrics);
  const recommended = new Set(detail.recommended_panels ?? []);
  return fitnessActivityPanelRegistry
    .filter((panel) => (
      panel.supportedSportKeys === "any" || panel.supportedSportKeys.includes(detail.activity.sport_key)
    ))
    .filter((panel) => panel.requiredCapabilities.every((capability) => capabilities.has(capability)))
    .filter((panel) => panel.requiredMetrics.every((metric) => metrics.has(metric)))
    .sort((left, right) => {
      if (recommended.size) {
        const recommendationDelta = Number(recommended.has(right.key)) - Number(recommended.has(left.key));
        if (recommendationDelta) return recommendationDelta;
      }
      return left.priority - right.priority;
    });
}
