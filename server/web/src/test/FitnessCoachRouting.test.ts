import { describe, expect, it } from "vitest";

import { fitnessCoachDestinationLocation } from "../App";
import type { FitnessCoachProposalDestination } from "../fitness/contract";

describe("Fitness Coach destination routing", () => {
  it.each([
    ["planned_session", { view: "fitness", section: "training", focus: { session: "target-1" } }],
    ["nutrition_target", { view: "fitness", section: "nutrition", focus: { "fitness-nutrition-target": "target-1" } }],
    ["meal_template", { view: "fitness", section: "nutrition", focus: { "fitness-meal-template": "target-1" } }],
    ["goal", { view: "fitness", section: "training", focus: { "fitness-plan-manage": "goals", "fitness-goal": "target-1" } }],
    ["analysis_chart", { view: "fitness", section: "explore", focus: { "fitness-analysis-chart": "target-1" } }],
    ["calendar_event", { view: "calendar", focus: { event: "target-1" } }],
    ["food_log", { view: "fitness", section: "nutrition", focus: { "fitness-food-log": "target-1" } }],
    ["shopping", { view: "lists", section: "meals", focus: { shopping: "target-1" }, mealsTab: "tesco" }],
    ["task", { view: "lists", section: "tasks", focus: { task: "target-1", task_status: "active" } }],
    ["fitness_reminder", { view: "fitness", section: "coach", focus: { "fitness-personalise": "reminders", "fitness-reminder": "target-1" } }],
  ] satisfies Array<[FitnessCoachProposalDestination["kind"], Record<string, unknown>]>)
  ("maps %s exhaustively", (kind, expected) => {
    expect(fitnessCoachDestinationLocation({ kind, target: "target-1", label: "Open" })).toEqual(expected);
  });

  it("fails closed for blank targets and unknown future kinds", () => {
    expect(fitnessCoachDestinationLocation({ kind: "task", target: "  ", label: "Open" })).toBeNull();
    expect(fitnessCoachDestinationLocation({ kind: "future_destination" as never, target: "target-1", label: "Open" })).toBeNull();
  });
});
