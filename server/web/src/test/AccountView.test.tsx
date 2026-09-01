import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { User } from "../types";
import { AccountView } from "../views/AccountView";

vi.mock("../api", () => ({ api: vi.fn(), getAuthSessionEpoch: () => 1 }));

const apiMock = vi.mocked(api);
const user: User = {
  id: "user-1",
  name: "Alex",
  email: "dom@example.invalid",
  role: "admin",
  priority: 5,
  family_id: "family-1",
  must_change_password: true,
};
const reminderPreferences = {
  event_reminders_enabled: true, event_minutes_before: 30, task_reminders_enabled: true,
  morning_summary_enabled: true, morning_summary_time: "07:00", quiet_start: "21:00",
  evening_summary_enabled: true, evening_summary_time: "19:00",
  quiet_end: "07:00", privacy_mode: true,
};
const consented = {
  consented: true,
  version: "2026-07-13",
  consented_at: "2026-07-13T10:00:00Z",
  provider: "OpenAI",
  disclosure: "Family data is sent to OpenAI only when you choose an AI feature.",
  background_processing: false,
};
const usageSummary = {
  enabled: true, period_days: 28, meaningful_actions: 9, failed_actions: 1,
  active_days: 4, use_signal: "returning" as const,
  repeat_modules: [{ module: "tasks", actions: 4, active_days: 3 }],
  both_adults_contributed: true, shared_family_actions: 12,
  last_action_at: "2026-08-09T10:00:00Z",
};
const disabledUsageSummary = {
  ...usageSummary, enabled: false, meaningful_actions: 0, failed_actions: 0,
  active_days: 0, use_signal: "not_started" as const, repeat_modules: [],
  both_adults_contributed: false, shared_family_actions: 0, last_action_at: null,
};
const emptyRugbySettings = {
  configured: false, affected_user_ids: [], affected_names: [], fixture_count: 0,
};
const rugbyTeams = {
  season: "2026/27", teams: [{ id: "2064255", name: "Colts C" }],
};
describe("AccountView", () => {
  const originalServiceWorker = Object.getOwnPropertyDescriptor(navigator, "serviceWorker");

  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/calendar/rugby") return emptyRugbySettings as never;
      if (path === "/calendar/rugby/teams") return rugbyTeams as never;
      if (path === "/family/settings/ha") return { configured: false, dashboard_url: null, ha_url: null, token_configured: false } as never;
      if (path === "/reminders/preferences") return reminderPreferences as never;
      if (path === "/reminders/push") return { configured: false, subscribed: false } as never;
      if (path === "/reminders/preview") return [] as never;
      if (path === "/auth/ai-consent") return consented as never;
      if (path === "/usage-history/summary") return disabledUsageSummary as never;
      if (path === "/fitness/quick-entry-preferences") return (init?.method === "PATCH"
        ? JSON.parse(String(init.body))
        : { meal_times: { breakfast: "08:00", lunch: "12:30", dinner: "18:30" } }) as never;
      return undefined as never;
    });
  });

  afterEach(() => {
    if (originalServiceWorker) Object.defineProperty(navigator, "serviceWorker", originalServiceWorker);
    else Reflect.deleteProperty(navigator, "serviceWorker");
  });

  it("does not load integrations until their Settings category opens", async () => {
    render(<AccountView user={{ ...user, must_change_password: false }} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);

    expect(apiMock).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /Account/ }));
    expect(apiMock).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /All settings/ }));
    fireEvent.click(screen.getByRole("button", { name: /Connections/ }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/sources"));
    expect(apiMock).toHaveBeenCalledWith("/family/settings/ha");
    expect(apiMock).not.toHaveBeenCalledWith("/reminders/preferences");
    expect(apiMock).not.toHaveBeenCalledWith("/auth/ai-consent");
  });

  it("edits the visible profile name", async () => {
    const readyUser = { ...user, must_change_password: false };
    const updated = { ...readyUser, name: "Dominic" };
    const onUserUpdated = vi.fn();
    apiMock.mockImplementation(async (path) => path === "/auth/me" ? updated as never : undefined as never);
    render(<AccountView user={readyUser} onUserUpdated={onUserUpdated} onSignOut={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Account/ }));
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Dominic" } });
    fireEvent.click(screen.getByRole("button", { name: "Save profile" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/auth/me", {
      method: "PATCH", body: JSON.stringify({ name: "Dominic" }),
    }));
    expect(onUserUpdated).toHaveBeenCalledWith(updated);
  });

  it("rejects weak passwords before calling the server", () => {
    render(<AccountView user={user} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    fireEvent.change(screen.getByLabelText("Current password"), { target: { value: "temporary" } });
    fireEvent.change(screen.getByLabelText("New password"), { target: { value: "short" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "short" } });
    fireEvent.click(screen.getByRole("button", { name: "Change password" }));

    expect(screen.getByRole("alert")).toHaveTextContent("at least 12 characters");
    expect(apiMock).not.toHaveBeenCalledWith("/auth/web/change-password", expect.anything());
  });

  it("changes the password and updates the active user", async () => {
    const updated = { ...user, must_change_password: false };
    const onUserUpdated = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path === "/auth/web/change-password") return updated;
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/reminders/preferences") return reminderPreferences as never;
      if (path === "/reminders/push") return { configured: false, subscribed: false } as never;
      if (path === "/reminders/preview") return [] as never;
      return undefined as never;
    });
    render(<AccountView user={user} onUserUpdated={onUserUpdated} onSignOut={vi.fn()} />);
    fireEvent.change(screen.getByLabelText("Current password"), { target: { value: "temporary-password" } });
    fireEvent.change(screen.getByLabelText("New password"), { target: { value: "a-new-private-password" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "a-new-private-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Change password" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/auth/web/change-password", {
      method: "POST",
      body: JSON.stringify({
        current_password: "temporary-password",
        new_password: "a-new-private-password",
      }),
    }));
    expect(onUserUpdated).toHaveBeenCalledWith(updated);
    expect(screen.getByText("Password changed.")).toBeInTheDocument();
  });

  it("adds a private calendar without displaying its URL", async () => {
    const source = {
      id: "source-1", name: "School", hostname: "calendar.example", color: "#2563EB",
      enabled: true, created_at: "2026-07-12T00:00:00Z", updated_at: "2026-07-12T00:00:00Z",
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/calendar/sources" && init?.method === "POST") return source as never;
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/reminders/preferences") return reminderPreferences as never;
      if (path === "/reminders/push") return { configured: false, subscribed: false } as never;
      if (path === "/reminders/preview") return [] as never;
      if (path === "/auth/ai-consent") return consented as never;
      return undefined as never;
    });
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/calendar/sources/validate") return { valid: true, hostname: "calendar.example", event_count: 3 } as never;
      if (path === "/calendar/sources" && init?.method === "POST") return source as never;
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/family/settings/ha") return { configured: false, dashboard_url: null, ha_url: null, token_configured: false } as never;
      return undefined as never;
    });
    render(<AccountView user={{ ...user, must_change_password: false }} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Connections/ }));
    await screen.findByLabelText("Calendar name");
    fireEvent.change(screen.getByLabelText("Calendar name"), { target: { value: "School" } });
    fireEvent.change(screen.getByLabelText("Private ICS link"), { target: { value: "https://calendar.example/private.ics" } });
    fireEvent.click(screen.getAllByRole("button", { name: "Check connection" })[0]);
    await screen.findByText((_content, element) => element?.tagName === "SMALL" && element.textContent?.includes("3 upcoming events found") === true);
    fireEvent.click(screen.getByRole("button", { name: "Add calendar" }));
    await screen.findByText("calendar.example · Not synced yet");
    expect(screen.queryByDisplayValue("https://calendar.example/private.ics")).not.toBeInTheDocument();
  });

  it("lets an administrator choose the managed Example School rugby team", async () => {
    const configured = {
      configured: true,
      source_id: "rugby-source",
      team_id: "2064255",
      team_name: "Colts C",
      season: "2026/27",
      owner_user_id: "user-1",
      owner_name: "Alex",
      affected_user_ids: ["user-2"],
      affected_names: ["Morgan"],
      fixture_count: 8,
      last_success_at: "2026-08-12T10:00:00Z",
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/calendar/rugby" && init?.method === "PUT") return configured as never;
      if (path === "/calendar/rugby") return emptyRugbySettings as never;
      if (path === "/calendar/rugby/teams") return rugbyTeams as never;
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/family/settings/ha") return { configured: false, dashboard_url: null, ha_url: null, token_configured: false } as never;
      return undefined as never;
    });

    render(<AccountView user={{ ...user, must_change_password: false }} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Connections/ }));
    const teamSelect = await screen.findByLabelText("Rugby team");
    fireEvent.change(teamSelect, { target: { value: "2064255" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect team" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/rugby", {
      method: "PUT",
      body: JSON.stringify({ team_id: "2064255" }),
      timeoutMs: 30_000,
    }));
    expect(await screen.findByText("8 Colts C fixtures added to the planner.")).toBeInTheDocument();
    expect(screen.getByText(/1:00–7:00 pm is reserved/)).toBeInTheDocument();
    expect(screen.getByText(/affects Morgan/)).toBeInTheDocument();
    expect(screen.queryByText(/pressure|pinchpoint/i)).not.toBeInTheDocument();
  });

  it("lets a user withdraw external AI permission", async () => {
    const readyUser = { ...user, must_change_password: false };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/auth/ai-consent" && init?.method === "DELETE") return { ...consented, consented: false, consented_at: null } as never;
      if (path === "/auth/ai-consent") return consented as never;
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/reminders/preferences") return reminderPreferences as never;
      if (path === "/reminders/push") return { configured: false, subscribed: false } as never;
      if (path === "/reminders/preview") return [] as never;
      return undefined as never;
    });

    render(<AccountView user={readyUser} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Privacy & AI/ }));
    expect(await screen.findByText("Permission granted")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Withdraw AI permission" }));

    expect(await screen.findByText("Permission not granted")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/auth/ai-consent", { method: "DELETE" });
  });

  it("lets each adult enable and pin their private Fitness workspace", async () => {
    const readyUser = { ...user, must_change_password: false };
    const onWorkspaceChange = vi.fn().mockResolvedValue(undefined);
    const onOpenFinance = vi.fn();
    const view = render(
      <AccountView
        user={readyUser}
        onUserUpdated={vi.fn()}
        onSignOut={vi.fn()}
        financeAvailable
        fitnessWorkspace={{ enabled: false, pinned: false, show_nutrition_today: false }}
        onFitnessWorkspaceChange={onWorkspaceChange}
        onOpenFinance={onOpenFinance}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /Personal workspaces/ }));

    expect(await screen.findByText("Money and Fitness")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Money/ }));
    expect(onOpenFinance).toHaveBeenCalledOnce();
    expect(screen.getByRole("checkbox", { name: /Pin Fitness in navigation/ })).toBeDisabled();
    expect(screen.getByRole("checkbox", { name: /Show nutrition progress on Today/ })).toBeDisabled();
    fireEvent.click(screen.getByRole("checkbox", { name: /Use Fitness/ }));
    await waitFor(() => expect(onWorkspaceChange).toHaveBeenCalledWith({ enabled: true }));

    view.rerender(
      <AccountView
        user={readyUser}
        onUserUpdated={vi.fn()}
        onSignOut={vi.fn()}
        financeAvailable
        fitnessWorkspace={{ enabled: true, pinned: false, show_nutrition_today: false }}
        onFitnessWorkspaceChange={onWorkspaceChange}
        onOpenFinance={onOpenFinance}
      />,
    );
    fireEvent.click(screen.getByRole("checkbox", { name: /Pin Fitness in navigation/ }));
    await waitFor(() => expect(onWorkspaceChange).toHaveBeenCalledWith({ pinned: true }));
    fireEvent.click(screen.getByRole("checkbox", { name: /Show nutrition progress on Today/ }));
    await waitFor(() => expect(onWorkspaceChange).toHaveBeenCalledWith({ show_nutrition_today: true }));
  });

  it("saves owner-private meal shortcut times for Today", async () => {
    const readyUser = { ...user, must_change_password: false };
    render(
      <AccountView
        user={readyUser}
        onUserUpdated={vi.fn()}
        onSignOut={vi.fn()}
        fitnessWorkspace={{ enabled: true, pinned: true, show_nutrition_today: false }}
        onFitnessWorkspaceChange={vi.fn().mockResolvedValue(undefined)}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /Personal workspaces/ }));
    expect(await screen.findByLabelText("Breakfast")).toHaveValue("08:00");
    fireEvent.change(screen.getByLabelText("Dinner"), { target: { value: "19:15" } });
    fireEvent.click(screen.getByRole("button", { name: "Save meal times" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/fitness/quick-entry-preferences",
      {
        method: "PATCH",
        body: JSON.stringify({ meal_times: { breakfast: "08:00", lunch: "12:30", dinner: "19:15" } }),
      },
      true,
      false,
    ));
    expect(await screen.findByText("Meal shortcut times saved.")).toBeInTheDocument();
  });

  it("requires destructive confirmation before deleting the account", async () => {
    const readyUser = { ...user, must_change_password: false };
    const onSignOut = vi.fn();
    render(<AccountView user={readyUser} onUserUpdated={vi.fn()} onSignOut={onSignOut} />);
    fireEvent.click(screen.getByRole("button", { name: /Advanced/ }));
    fireEvent.click(screen.getByRole("button", { name: "Delete account" }));
    expect(screen.getByText(/This cannot be undone/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Delete permanently" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/auth/me", { method: "DELETE" }));
    expect(onSignOut).toHaveBeenCalledOnce();
  });

  it("records no usage until the adult explicitly confirms the opt-in", async () => {
    const readyUser = { ...user, must_change_password: false };
    let enabled = false;
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/usage-history/summary") return (enabled ? usageSummary : disabledUsageSummary) as never;
      if (path === "/usage-history/preferences") {
        enabled = JSON.parse(String(init?.body)).enabled as boolean;
        return { enabled, retention_days: 28 } as never;
      }
      return undefined as never;
    });

    render(<AccountView user={readyUser} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Advanced/ }));
    const toggle = await screen.findByRole("checkbox", { name: /Keep a private 28-day usage summary/ });
    expect(toggle).not.toBeChecked();
    expect(screen.getByText(/nothing is recorded until you explicitly allow it/i)).toBeInTheDocument();

    fireEvent.click(toggle);
    expect(screen.getByText(/linked to your account for your private summary/i)).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/usage-history/preferences", expect.anything());

    fireEvent.click(screen.getByRole("button", { name: "Allow 28-day summary" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/usage-history/preferences", {
      method: "PATCH", body: JSON.stringify({ enabled: true }),
    }));
    expect(await screen.findByText("You completed 9 useful actions across 4 days.")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("checkbox", { name: /Keep a private 28-day usage summary/ }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/usage-history/preferences", {
      method: "PATCH", body: JSON.stringify({ enabled: false }),
    }));
    expect(await screen.findByText(/nothing is recorded until you explicitly allow it/i)).toBeInTheDocument();
  });

  it("disables reminders only for the current browser", async () => {
    const unsubscribe = vi.fn().mockResolvedValue(true);
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: {
        ready: Promise.resolve({
          pushManager: {
            getSubscription: vi.fn().mockResolvedValue({
              endpoint: "https://push.example/dom-mac",
              unsubscribe,
            }),
          },
        }),
      },
    });
    apiMock.mockImplementation(async (path) => {
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/reminders/preferences") return reminderPreferences as never;
      if (path === "/reminders/push") return { configured: true, subscribed: true, public_key: "key" } as never;
      if (path === "/reminders/preview") return [] as never;
      return undefined as never;
    });

    render(<AccountView user={{ ...user, must_change_password: false }} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Disable on this browser" }));

    await waitFor(() => expect(unsubscribe).toHaveBeenCalledOnce());
    const deleteCalls = apiMock.mock.calls.filter(([, init]) => init?.method === "DELETE");
    expect(deleteCalls).toHaveLength(1);
    expect(deleteCalls[0]?.[0]).toMatch(/^\/reminders\/push\/subscriptions\/[a-f0-9]{64}$/);
    expect(deleteCalls[0]?.[0]).not.toBe("/reminders/push/subscriptions");
    expect(await screen.findByRole("button", { name: "Enable on this browser" })).toBeInTheDocument();
  });
});
