import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { OnboardingGuide } from "../components/OnboardingGuide";
import type { OnboardingStatus, User } from "../types";

vi.mock("../api", () => ({ api: vi.fn() }));
vi.mock("../components/QRCode", () => ({ QRCode: ({ value }: { value: string }) => <div data-testid="qr">{value}</div> }));

const apiMock = vi.mocked(api);
const user: User = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family", must_change_password: false };
const status: OnboardingStatus = {
  family_name: "Example family", people_count: 1, adult_count: 1, child_count: 0,
  calendar_commitment_count: 0, reminders_configured: false, selected_modules: [],
  dismissed: false, completed: false, should_show: true, first_success: false,
};
const reminders = {
  event_reminders_enabled: true, event_minutes_before: 30, task_reminders_enabled: true,
  morning_summary_enabled: true, morning_summary_time: "07:00", evening_summary_enabled: true,
  evening_summary_time: "19:00", quiet_start: "21:00", quiet_end: "07:00", privacy_mode: true,
};

describe("OnboardingGuide", () => {
  beforeEach(() => apiMock.mockReset());

  it("completes the core path and celebrates the first real commitment", async () => {
    const onComplete = vi.fn();
    const onEnableFitness = vi.fn().mockResolvedValue(undefined);
    const afterEvent = { ...status, calendar_commitment_count: 1, first_success: true };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/calendar/" && init?.method === "POST") return {} as never;
      if (path === "/auth/onboarding" && !init?.method) return afterEvent as never;
      if (path === "/reminders/preferences" && !init?.method) return reminders as never;
      if (path === "/reminders/preferences" && init?.method === "PUT") return reminders as never;
      if (path === "/auth/onboarding" && init?.method === "PATCH") return { ...afterEvent, completed: true, should_show: false } as never;
      return undefined as never;
    });
    render(<OnboardingGuide user={user} initialStatus={status} onComplete={onComplete} onEnableFitness={onEnableFitness} />);

    expect(screen.getByText("Know what’s happening today.")).toBeInTheDocument();
    expect(screen.queryByText("Fitness")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Set up the useful core/ }));
    fireEvent.change(screen.getByLabelText("What’s happening?"), { target: { value: "School pickup" } });
    fireEvent.change(screen.getByLabelText("When?"), { target: { value: "2026-08-10T15:30" } });
    expect(screen.getByLabelText("How long?")).toHaveValue("30");
    fireEvent.click(screen.getByRole("button", { name: /Add first commitment/ }));

    expect(await screen.findByText("The first commitment is already waiting in Today.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Continue/ }));
    expect(await screen.findByText("Optional private workspace")).toBeInTheDocument();
    expect(screen.getByRole("checkbox", { name: /^Due tasks/ })).toBeChecked();
    expect(screen.getByText("Fitness")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox", { name: /^Fitness/ }));
    fireEvent.click(screen.getByRole("button", { name: "Finish setup" }));
    expect(await screen.findByRole("heading", { name: "You know what’s happening today" })).toBeInTheDocument();
    expect(onEnableFitness).toHaveBeenCalledOnce();
    fireEvent.click(screen.getByRole("button", { name: "Open Today" }));
    expect(onComplete).toHaveBeenCalledWith(expect.objectContaining({ completed: true, should_show: false }));
  });

  it("creates a scannable deep-link invitation for the other adult", async () => {
    apiMock.mockImplementation(async (path) => path === "/auth/invite" ? {
      invite_code: "ABCD1234", expires_at: "2026-08-10T12:00:00Z", join_url: "https://hausklar.example/#join=ABCD1234",
    } as never : undefined as never);
    render(<OnboardingGuide user={user} initialStatus={status} onComplete={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: /Set up the useful core/ }));
    fireEvent.click(screen.getByRole("button", { name: "Do this later" }));
    fireEvent.click(screen.getByRole("button", { name: "Create invitation" }));
    expect(await screen.findByTestId("qr")).toHaveTextContent("https://hausklar.example/#join=ABCD1234");
    expect(screen.getByText("ABCD1234")).toBeInTheDocument();
  });
});
