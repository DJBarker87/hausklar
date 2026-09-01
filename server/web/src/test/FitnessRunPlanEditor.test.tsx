import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { FitnessRunPlanEditor } from "../views/fitness/FitnessRunPlanEditor";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  saveFitnessRecords: vi.fn().mockResolvedValue([]),
}));

describe("Fitness run-plan editor", () => {
  beforeEach(() => {
    vi.mocked(api).mockReset();
    vi.mocked(api).mockResolvedValue([]);
  });

  it("keeps an incremental pace draft editable and commits a valid m:ss value on blur", () => {
    render(<FitnessRunPlanEditor goals={[]} programmes={[]} onClose={vi.fn()} onAccepted={vi.fn()} />);
    const targetFrom = screen.getAllByLabelText("Target from")[0] as HTMLInputElement;

    fireEvent.change(targetFrom, { target: { value: "5" } });
    expect(targetFrom.value).toBe("5");

    fireEvent.change(targetFrom, { target: { value: "5:20" } });
    fireEvent.blur(targetFrom);
    expect(targetFrom.value).toBe("5:20");
  });
});
