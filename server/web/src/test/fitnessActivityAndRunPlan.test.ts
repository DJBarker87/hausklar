import { describe, expect, it } from "vitest";

import { availableFitnessActivityPanels } from "../fitness/activityPanels";
import type { FitnessActivityDetail, FitnessRunWorkoutStep } from "../fitness/contract";
import { fitnessRunPlanTotals, validateFitnessRunPlan } from "../fitness/runPlanSemantics";
import { nearestStreamIndex, streamOffsetX } from "../views/fitness/ActivityVisualiser";

function detail(overrides: Partial<FitnessActivityDetail> = {}): FitnessActivityDetail {
  return {
    activity: {
      id: "activity-1",
      title: "Morning run",
      sport_key: "running",
      started_at_utc: "2026-08-02T07:00:00Z",
    },
    sources: [],
    summary_metrics: [],
    available_stream_metrics: ["pace_s_per_km", "latitude_deg", "longitude_deg"],
    intervals: [{ id: "split-1", sequence: 0, interval_kind: "kilometre_split", start_offset_ms: 0, end_offset_ms: 300_000 }],
    ...overrides,
  };
}

describe("Fitness activity panel registry", () => {
  it("uses real stream offsets for crosshair selection after irregular downsampling", () => {
    const offsets = [0, 1_000, 9_000];
    expect(nearestStreamIndex(offsets, 0.5)).toBe(1);
    expect(nearestStreamIndex(offsets, 0.8)).toBe(2);
    expect(streamOffsetX(offsets, 1, 900)).toBe(100);
  });

  it("hides metric-absent panels while retaining the generic activity shell", () => {
    const keys = availableFitnessActivityPanels(detail()).map((panel) => panel.key);
    expect(keys).toContain("route_map");
    expect(keys).toContain("synchronised_line_chart");
    expect(keys).toContain("split_table");
    expect(keys).toContain("run_pacing_analysis");
    expect(keys).not.toContain("run_heart_rate_analysis");
  });

  it("offers the route panel for a stored Strava polyline without coordinate streams", () => {
    const keys = availableFitnessActivityPanels(detail({
      activity: { ...detail().activity, route_preview: [[51.5, -0.1], [51.51, -0.09]] },
      available_stream_metrics: [],
      intervals: [],
    })).map((panel) => panel.key);

    expect(keys).toContain("route_map");
  });

  it("supports strength and another sport without inventing running panels", () => {
    const strengthKeys = availableFitnessActivityPanels(detail({
      activity: { ...detail().activity, sport_key: "strength" },
      available_stream_metrics: [],
      intervals: [],
    })).map((panel) => panel.key);
    expect(strengthKeys).toEqual(["strength_exercise_summary"]);

    const cyclingKeys = availableFitnessActivityPanels(detail({
      activity: { ...detail().activity, sport_key: "cycling" },
      available_stream_metrics: ["power_w"],
      intervals: [],
    })).map((panel) => panel.key);
    expect(cyclingKeys).toEqual(["synchronised_line_chart"]);
  });
});

describe("structured run-plan semantics", () => {
  const work: FitnessRunWorkoutStep = {
    id: "work",
    parent_step_id: "repeat",
    sequence: 0,
    step_kind: "step",
    duration_type: "time_s",
    duration_value: 180,
    target_type: "pace_s_per_km",
    target_low: 270,
    target_high: 285,
    target_unit: "s/km",
    display_name: "Work",
  };
  const recovery: FitnessRunWorkoutStep = {
    ...work,
    id: "recovery",
    sequence: 1,
    duration_value: 120,
    target_type: "none",
    target_low: null,
    target_high: null,
    target_unit: null,
    display_name: "Recovery",
  };

  it("calculates finite nested repeat totals", () => {
    const totals = fitnessRunPlanTotals([{
      id: "repeat",
      sequence: 0,
      step_kind: "repeat_block",
      repeat_count: 4,
      duration_type: "open",
      target_type: "none",
      display_name: "4 repeats",
      children: [work, recovery],
    }]);
    expect(totals).toEqual({ distanceM: 0, durationS: 1200, hasOpenDuration: false });
  });

  it("requires canonical pace units and canonical kilometre ordering", () => {
    const steps: FitnessRunWorkoutStep[] = [1, 3].map((kilometreIndex, index) => ({
      ...work,
      id: `km-${kilometreIndex}`,
      parent_step_id: null,
      sequence: index,
      duration_type: "distance_m",
      duration_value: 1000,
      target_unit: index === 0 ? "s_per_km" : "s/km",
      kilometre_index: kilometreIndex,
      display_name: `Editable label ${kilometreIndex}`,
    }));
    const result = validateFitnessRunPlan(steps, { planningContextReviewed: true });
    expect(result.errors).toContain("Editable label 1 must store pace targets in s/km.");
    expect(result.errors).toContain("Kilometre steps must run from 1 without gaps or duplicates.");
  });
});
