import { describe, expect, it } from "vitest";

import { comparisonSelectionExplanation, orderedComparableRuns } from "../fitness/runningAnalysis";
import type { FitnessComparableRun } from "../fitness/contract";

function comparable(id: string, score: number, selected?: boolean): FitnessComparableRun {
  return {
    activity: {
      id,
      title: `5K ${id}`,
      sport_key: "running",
      started_at_utc: `2026-08-0${id}T07:00:00Z`,
      status: "completed",
      distance_m: 5_000,
      duration_s: 1_500,
    },
    score,
    selected,
    reasons: ["similar distance"],
  };
}

describe("running comparison selection", () => {
  it("orders strongest 5K peers and describes an active comparison plainly", () => {
    const runs = [comparable("1", 0.72, true), comparable("2", 0.94, true)];
    expect(orderedComparableRuns(runs).map((item) => item.activity.id)).toEqual(["2", "1"]);
    expect(comparisonSelectionExplanation(runs)).toBe("Comparing with 2 similar runs · similar distance.");
  });

  it("invites selection without falsely claiming that no run qualified", () => {
    expect(comparisonSelectionExplanation([comparable("1", 0.9, false)]))
      .toBe("Choose up to five previous runs to compare.");
  });
});
