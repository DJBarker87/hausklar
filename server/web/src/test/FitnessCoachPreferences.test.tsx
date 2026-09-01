import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { FitnessCoachPreferencesCard } from "../views/fitness/FitnessCoachView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error { status: number; constructor(message: string, status: number) { super(message); this.status = status; } },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
}));

describe("Fitness Coach preferences", () => {
  beforeEach(() => {
    vi.mocked(api).mockReset();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("saves owner-private style independently without an AI request", async () => {
    const apiMock = vi.mocked(api);
    apiMock.mockImplementation(async (path, init) => {
      if (path !== "/fitness/coach/preferences") throw new Error(`Unexpected request: ${path}`);
      if (init?.method === "PATCH") return JSON.parse(String(init.body)) as never;
      return { personality_preset: "balanced_supportive", directness: 3, challenge_bias: "balanced", detail_level: "standard", custom_instruction: "" } as never;
    });

    render(<FitnessCoachPreferencesCard online revision={0} />);
    expect(await screen.findByText("Balanced & supportive")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Personalise" }));
    const balancedPreset = screen.getByRole("button", { name: /Balanced & supportive/ });
    expect(balancedPreset).toHaveAttribute("aria-pressed", "true");
    expect(within(balancedPreset).getByText("Selected")).toBeInTheDocument();
    const scientificPreset = screen.getByRole("button", { name: /Scientific & hard-driving/ });
    fireEvent.click(scientificPreset);
    expect(scientificPreset).toHaveAttribute("aria-pressed", "true");
    expect(within(scientificPreset).getByText("Selected")).toBeInTheDocument();
    expect(screen.getByLabelText("Coach directness")).toHaveValue("5");
    expect(screen.getByLabelText("Challenge bias")).toHaveValue("ambitious");
    expect(screen.getByLabelText("Level of detail")).toHaveValue("detailed");
    fireEvent.change(screen.getByLabelText(/Custom instruction/), { target: { value: "Challenge vague excuses, but stay concise on race week." } });
    expect(screen.getByLabelText(/Custom instruction/)).toHaveValue("Challenge vague excuses, but stay concise on race week.");
    fireEvent.click(screen.getByRole("button", { name: "Save coach style" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/preferences", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({
        personality_preset: "custom",
        directness: 5,
        challenge_bias: "ambitious",
        detail_level: "detailed",
        custom_instruction: "Challenge vague excuses, but stay concise on race week.",
      }),
    }), true, false));
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/coach/message", expect.anything(), expect.anything(), expect.anything());
  });

  it("normalises a nullable custom instruction and restores it safely on cancel", async () => {
    vi.mocked(api).mockResolvedValue({ personality_preset: "balanced_supportive", directness: 3, challenge_bias: "balanced", detail_level: "standard", custom_instruction: null } as never);
    render(<FitnessCoachPreferencesCard online revision={0} />);
    fireEvent.click(await screen.findByRole("button", { name: "Personalise" }));
    const instruction = screen.getByLabelText(/Custom instruction/);
    expect(instruction).toHaveValue("");
    fireEvent.change(instruction, { target: { value: "Temporary wording" } });
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    fireEvent.click(screen.getByRole("button", { name: "Personalise" }));
    expect(screen.getByLabelText(/Custom instruction/)).toHaveValue("");
  });

  it("does not present a balanced fallback as the saved style on an initial offline mount", async () => {
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: false });
    render(<FitnessCoachPreferencesCard online={false} revision={0} />);
    expect(await screen.findByText(/Reconnect to load the coach style you saved/)).toBeInTheDocument();
    expect(screen.queryByText("Balanced & supportive")).not.toBeInTheDocument();
    expect(api).not.toHaveBeenCalled();
  });
});
