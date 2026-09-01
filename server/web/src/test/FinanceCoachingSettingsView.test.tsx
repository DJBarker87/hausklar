import { render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";

import { api } from "../api";
import type { FinanceReportPreference, FinanceSpace, ReminderPreferences } from "../types";
import { FinanceCoachingSettingsView } from "../views/FinanceCoachingSettingsView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

it("groups reminder choices and associates each explanation with its radio", async () => {
  const space: FinanceSpace = { id: "personal-1", kind: "personal", name: "Alex", is_default: true };
  const preference: FinanceReportPreference = {
    id: "preference-1",
    space_id: space.id,
    member_user_id: "dom",
    locale: "en",
    daily_time: "07:00:00",
    enabled: true,
    notification_channel: "IN_APP",
    notification_mode: "ACTION_ONLY",
    show_more_by_default: false,
    quiet_hours_start: null,
    quiet_hours_end: null,
    underfunded_commitment_threshold_minor: 0,
    goal_movement_threshold_minor: 0,
    missed_payday_alerts: true,
    selected_return_deadline_alerts: true,
    tone: "BALANCED",
    default_spend_account_id: null,
    extra_cash_buffer_minor: 0,
    writing_mode: "LOCAL",
    allow_dated_estimates: true,
    ordinary_purchase_alerts: false,
    group_related_alerts: true,
    updated_at: "2026-08-02T10:00:00Z",
  };
  const reminders: ReminderPreferences = {
    event_reminders_enabled: true,
    event_minutes_before: 30,
    task_reminders_enabled: true,
    morning_summary_enabled: true,
    morning_summary_time: "07:00",
    evening_summary_enabled: false,
    evening_summary_time: "19:00",
    quiet_start: "21:00",
    quiet_end: "07:00",
    privacy_mode: true,
  };
  apiMock.mockImplementation(async (path) => {
    if (path === "/finance/report-preferences?space_id=personal-1") return preference as never;
    if (path === "/reminders/push") return { configured: true, subscribed: false } as never;
    if (path === "/reminders/preferences") return reminders as never;
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(<FinanceCoachingSettingsView spaces={[space]} accounts={[]} consents={[]} locale="en" />);

  const group = await screen.findByRole("group", { name: "Money reminders" });
  const actionOnly = screen.getByRole("radio", { name: /Only when I need to act/ });
  expect(group).toContainElement(actionOnly);
  expect(actionOnly).toBeChecked();
  expect(actionOnly).toHaveAccessibleDescription(/One private reminder at most/);
  expect(screen.getByRole("radio", { name: /Daily money check/ })).toHaveAccessibleDescription(/private reminder every day/);
  expect(screen.getByRole("radio", { name: /^Never/ })).toHaveAccessibleDescription(/No Finance reminders/);
});
