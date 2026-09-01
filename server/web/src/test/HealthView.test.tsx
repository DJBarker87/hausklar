import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { HealthView } from "../views/HealthView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const child = { id: "child-1", name: "Child Two", date_of_birth: "2025-06-01" };

const vaccinations = {
  disclaimer: "Follow the NHS schedule and speak to your GP with any questions.",
  vaccinations: [
    { key: "mmr_2", name: "MMR (2nd dose)", due_age_label: "3 years 4 months", due_date: "2026-06-01", status: "due", given_on: null },
  ],
};

const growth = {
  sex: "female",
  disclaimer: "Centiles are a guide, not a diagnosis.",
  note: null,
  measurements: [{ date: "2026-06-01", age_months: 12, height_cm: 74, weight_kg: 9.2, height_centile: 50, weight_centile: 50 }],
  weight_reference: [
    { age_months: 0, p2: 2.5, p9: 2.9, p25: 3.2, p50: 3.5, p75: 3.9, p91: 4.3, p98: 4.8 },
    { age_months: 12, p2: 8.0, p9: 8.6, p25: 9.2, p50: 9.9, p75: 10.6, p91: 11.3, p98: 12.0 },
  ],
  height_reference: [
    { age_months: 0, p2: 47, p9: 48, p25: 49, p50: 50, p75: 51, p91: 52, p98: 53 },
    { age_months: 12, p2: 71, p9: 72, p25: 73, p50: 74, p75: 76, p91: 77, p98: 78 },
  ],
};

describe("HealthView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path: string) => {
      if (path.endsWith("/vaccinations")) return vaccinations as never;
      if (path.endsWith("/growth-centiles")) return growth as never;
      return {} as never;
    });
  });

  it("opens on growth, keeps vaccinations last, and records one as given", async () => {
    render(<HealthView children={[child]} />);
    expect(await screen.findByText("Weight for age")).toBeInTheDocument();
    const tabs = screen.getByRole("group", { name: "Health record section" });
    expect(within(tabs).getAllByRole("button").map((button) => button.textContent)).toEqual([
      "Growth", "Illnesses", "GP summary", "Vaccinations",
    ]);
    fireEvent.click(screen.getByRole("button", { name: "Vaccinations" }));
    expect(await screen.findByText("Follow the NHS schedule and speak to your GP with any questions.")).toBeInTheDocument();
    expect(screen.getByText("MMR (2nd dose)")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Milestones" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Mark MMR (2nd dose) as given" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/health-record/child-1/vaccinations",
      expect.objectContaining({ method: "POST", body: expect.stringContaining("mmr_2") }),
    ));
  });

  it("draws centile charts with the latest centile labelled", async () => {
    render(<HealthView children={[child]} />);
    expect(await screen.findByText("Weight for age")).toBeInTheDocument();
    expect(screen.getByText("Height for age")).toBeInTheDocument();
    expect(screen.getAllByText(/50th centile/).length).toBeGreaterThan(0);
  });

  it("adds a growth measurement directly from the Growth tab", async () => {
    render(<HealthView children={[child]} />);
    await screen.findByText("Weight for age");

    fireEvent.click(screen.getByRole("button", { name: "Add measurement" }));
    const dialog = screen.getByRole("dialog", { name: "Add measurement" });
    fireEvent.change(within(dialog).getByLabelText("Measured on"), { target: { value: "2026-08-10" } });
    fireEvent.change(within(dialog).getByLabelText("Height (cm)"), { target: { value: "82.5" } });
    fireEvent.change(within(dialog).getByLabelText("Weight (kg)"), { target: { value: "11.4" } });
    fireEvent.change(within(dialog).getByLabelText("Head circumference (cm, optional)"), { target: { value: "47.2" } });
    fireEvent.change(within(dialog).getByLabelText("Notes (optional)"), { target: { value: "Measured at home" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save measurement" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/growth/", expect.objectContaining({ method: "POST" })));
    const call = apiMock.mock.calls.find(([path, init]) => path === "/growth/" && init?.method === "POST");
    expect(JSON.parse(String(call?.[1]?.body))).toEqual({
      child_id: "child-1",
      date: "2026-08-10",
      height_cm: 82.5,
      weight_kg: 11.4,
      head_circumference_cm: 47.2,
      notes: "Measured at home",
    });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Add measurement" })).not.toBeInTheDocument());
  });

  it("records a historical illness from the health tab", async () => {
    apiMock.mockImplementation(async (path: string, init) => {
      if (path.endsWith("/growth-centiles")) return growth as never;
      if (path.startsWith("/illness/?")) return [] as never;
      if (path === "/illness/" && init?.method === "POST") return {} as never;
      return {} as never;
    });
    render(<HealthView children={[child]} />);
    await screen.findByText("Weight for age");
    fireEvent.click(screen.getByRole("button", { name: "Illnesses" }));
    expect(await screen.findByText("No illnesses recorded")).toBeInTheDocument();
    expect(screen.getByText(/family record, not medical advice/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Add illness" }));
    const dialog = screen.getByRole("dialog", { name: "Add illness" });
    fireEvent.change(within(dialog).getByLabelText("First sick day"), { target: { value: "2026-07-10" } });
    fireEvent.change(within(dialog).getByLabelText("Last sick day"), { target: { value: "2026-07-12" } });
    fireEvent.change(within(dialog).getByLabelText("Symptoms or notes (optional)"), { target: { value: "Stomach bug" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save illness" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/illness/", expect.objectContaining({ method: "POST" })));
    const call = apiMock.mock.calls.find(([path, init]) => path === "/illness/" && init?.method === "POST");
    expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({
      child_id: "child-1",
      started_at: "2026-07-10",
      ended_at: "2026-07-12",
      notes: "Stomach bug",
    });
  });

  it("soft-deletes an incorrect illness record after confirmation", async () => {
    apiMock.mockImplementation(async (path: string) => {
      if (path.endsWith("/growth-centiles")) return growth as never;
      if (path.startsWith("/illness/?")) return [{ id: "illness-1", child_id: "child-1", started_at: "2026-07-10", ended_at: "2026-07-12", notes: "Stomach bug" }] as never;
      return {} as never;
    });
    render(<HealthView children={[child]} />);
    await screen.findByText("Weight for age");
    fireEvent.click(screen.getByRole("button", { name: "Illnesses" }));
    fireEvent.click(await screen.findByRole("button", { name: /Delete illness from 10 Jul 2026/ }));
    const confirmation = screen.getByRole("dialog", { name: "Delete illness record?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Delete record" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/illness/illness-1", { method: "DELETE" }));
    expect(screen.queryByText("Stomach bug")).not.toBeInTheDocument();
  });

  it("adds a vaccination outside the standard schedule", async () => {
    render(<HealthView children={[child]} />);
    await screen.findByText("Weight for age");
    fireEvent.click(screen.getByRole("button", { name: "Vaccinations" }));
    await screen.findByText("MMR (2nd dose)");
    fireEvent.click(screen.getByRole("button", { name: "Add vaccination" }));
    const dialog = screen.getByRole("dialog", { name: "Add vaccination" });
    fireEvent.change(within(dialog).getByLabelText("Vaccination"), { target: { value: "Chickenpox" } });
    fireEvent.change(within(dialog).getByLabelText("Date given"), { target: { value: "2026-07-01" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add vaccination" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/health-record/child-1/vaccinations",
      expect.objectContaining({ method: "POST", body: expect.stringContaining("Chickenpox") }),
    ));
  });

  it("keeps a failed vaccination form open with its error visible", async () => {
    apiMock.mockImplementation(async (path: string, init) => {
      if (path.endsWith("/growth-centiles")) return growth as never;
      if (path.endsWith("/vaccinations") && init?.method === "POST") {
        throw new Error("Vaccination could not be saved");
      }
      if (path.endsWith("/vaccinations")) return vaccinations as never;
      return {} as never;
    });
    render(<HealthView children={[child]} />);
    await screen.findByText("Weight for age");
    fireEvent.click(screen.getByRole("button", { name: "Vaccinations" }));
    await screen.findByText("MMR (2nd dose)");
    fireEvent.click(screen.getByRole("button", { name: "Add vaccination" }));
    const dialog = screen.getByRole("dialog", { name: "Add vaccination" });
    fireEvent.change(within(dialog).getByLabelText("Vaccination"), { target: { value: "Chickenpox" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add vaccination" }));

    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Vaccination could not be saved");
    expect(dialog).toBeInTheDocument();
  });
});
