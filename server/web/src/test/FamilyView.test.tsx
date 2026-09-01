import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { FamilyView } from "../views/FamilyView";

vi.mock("../api", () => ({ api: vi.fn(), isOfflineQueuedResult: () => false }));

const apiMock = vi.mocked(api);
let nextDoseAt: string | null = null;

describe("FamilyView", () => {
  beforeEach(() => {
    nextDoseAt = null;
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/children/") return [{ id: "child-1", name: "Child One", date_of_birth: "2020-01-02" }];
      if (path.startsWith("/briefing/dashboard")) return {
        events: [{ id: "event-1", title: "Swimming", start_time: "2026-07-11T16:00:00Z", all_day: false, family_member_ids: ["child-1"] }],
        naps: [],
        illnesses: [],
        routines: [{ routine_item_id: "routine-1", person_id: "child-1", person_name: "Child One", name: "Book bag", color: "#276ef1", date: "2026-07-11" }],
        medicine: [],
        unavailable: [],
      };
      if (path.startsWith("/star-charts/?")) return [{
        id: "chart-1",
        child_id: "child-1",
        title: "Kind choices",
        grid_rows: 2,
        grid_columns: 2,
        stars_count: 1,
        total_cells: 4,
        reward_amount_pence: 500,
        completed_at: null,
        stars: [{ id: "star-1", row_index: 0, col_index: 0 }],
      }];
      if (path === "/star-charts/balance/child-1") return { child_id: "child-1", balance_pence: 500, balance_display: "£5.00" };
      if (path.startsWith("/dog/status?")) return {
        walked_today: false,
        fed_breakfast_today: true,
        fed_dinner_today: false,
        active_walk: null,
        dog_name: "Mabel",
        walk_state: "due",
        breakfast_state: "done",
        dinner_state: "upcoming",
      };
      if (path === "/dog/profile") return {
        name: "Mabel",
        breakfast_window_start: "07:00",
        breakfast_window_end: "09:00",
        walk_window_start: "10:00",
        walk_window_end: "14:00",
        dinner_window_start: "17:00",
        dinner_window_end: "19:00",
      };
      if (path.startsWith("/dog/activities?")) return [];
      if (path.startsWith("/dog/weights?")) return [];
      if (path.startsWith("/dog/vaccinations?")) return [];
      if (path === "/dog/vaccinations" && init?.method === "POST") return { id: "vaccination-1", ...JSON.parse(String(init.body)) };
      if (path === "/dog/documents") return [];
      if (path.startsWith("/children/presents/")) return { child_id: "child-1", occasions: [] };
      if (path.startsWith("/medicine/types")) return [{ id: "medicine-1", child_id: "child-1", name: "Calpol", default_dose_amount: "5 ml", min_hours_between_doses: 4, max_doses_24h: 4, notes: "With food" }];
      if (path.startsWith("/illness/?")) return [{ id: "illness-1", child_id: "child-1", started_at: "2026-07-11T08:00:00Z", ended_at: null }];
      if (path === "/illness/illness-1/detail") return {
        illness: { id: "illness-1", child_id: "child-1", started_at: "2026-07-11T08:00:00Z", ended_at: null },
        temperature_readings: [
          { id: "temperature-1", child_id: "child-1", illness_id: "illness-1", value_celsius: 37.2, recorded_at: "2026-07-11T08:10:00Z" },
          { id: "temperature-2", child_id: "child-1", illness_id: "illness-1", value_celsius: 38.4, recorded_at: "2026-07-11T09:10:00Z" },
        ],
        medicine_doses: [{
          id: "illness-dose-1",
          child_id: "child-1",
          medicine_type_id: "medicine-1",
          medicine_name_display: "Calpol",
          given_at: "2026-07-11T08:40:00Z",
        }],
        next_dose_times: [{
          medicine_type_id: "medicine-1",
          medicine_name: "Calpol",
          next_safe_at: nextDoseAt,
          is_safe_now: nextDoseAt === null,
          default_dose_amount: "5 ml",
          last_given_at: "2026-07-11T08:40:00Z",
        }],
      };
      if (path === "/medicine/doses" && init?.method === "POST") return {
        dose: { id: "dose-1", child_id: "child-1", medicine_type_id: "medicine-1", given_at: new Date().toISOString() },
        warnings: [{ type: "too_soon", message: "This is sooner than the configured interval." }],
      };
      if (path.startsWith("/child-photos/?")) return [];
      if (path === "/child-photos/" && init?.method === "POST") return {
        photos: [{ id: "photo-1", child_id: "child-1", child_name: "Child One", caption: null, taken_on: "2024-05-01", created_at: "2024-05-01T00:00:00Z", image_url: "/child-photos/photo-1/image" }],
      };
      return [];
    });
  });

  it("shows the complete household and exposes working child tools", async () => {
    render(
      <FamilyView
        members={[
          { id: "adult-1", name: "Alex", member_type: "user" },
          { id: "adult-2", name: "Morgan", member_type: "user" },
          { id: "child-1", name: "Child One", member_type: "child" },
        ]}
        revision={0}
        onDataChanged={vi.fn()}
      />,
    );

    expect(await screen.findByRole("region", { name: "Today by person" })).toHaveTextContent("Alex");
    expect(screen.getByRole("region", { name: "Today by person" })).toHaveTextContent("Morgan");
    expect(screen.getByRole("region", { name: "Today by person" })).toHaveTextContent("Child One");
    expect(screen.getByRole("region", { name: "Today by person" })).toHaveTextContent("Book bag");
    expect(screen.getByRole("region", { name: "Today by person" })).toHaveTextContent("Kind choices");

    fireEvent.click(screen.getByRole("button", { name: "Award a star" }));
    expect(await screen.findByText("Kind choices")).toBeInTheDocument();
    expect(screen.getAllByText(/£5\.00/)).toHaveLength(2);
    const unearnedStar = screen.getByRole("button", { name: "Child One, Kind choices, row 1, column 2, not earned" });
    expect(unearnedStar.parentElement).toHaveStyle({ gridTemplateColumns: "repeat(2, minmax(44px, 1fr))" });
    fireEvent.click(unearnedStar);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/star-charts/chart-1/stars", {
      method: "POST",
      body: JSON.stringify({ row_index: 0, col_index: 1 }),
    }));
  });

  it("lets the family choose a child before choosing a module", async () => {
    const childChanged = vi.fn();
    const openDocuments = vi.fn();
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        onChildChange={childChanged}
        onOpenDocuments={openDocuments}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Open Child One's family page" }));
    const chooser = screen.getByRole("dialog", { name: "Child One" });
    expect(within(chooser).getByRole("button", { name: "Medicine" })).toBeInTheDocument();
    expect(within(chooser).getByRole("heading", { name: "Memories" })).toBeInTheDocument();
    expect(within(chooser).getByRole("button", { name: "Yearbook" })).toBeInTheDocument();
    expect(within(chooser).getByRole("button", { name: "Health" })).toBeInTheDocument();
    fireEvent.click(within(chooser).getByRole("button", { name: "Documents" }));
    expect(openDocuments).toHaveBeenCalledWith("child-1");
    fireEvent.click(within(chooser).getByRole("button", { name: "Homework" }));
    expect(await screen.findByRole("heading", { name: "Homework", level: 1 })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Child One" })).toHaveClass("is-active");
    expect(childChanged).toHaveBeenCalledWith("child-1");
  });

  it("records the dog's vaccination and next due date", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="dog"
      />,
    );

    expect(await screen.findByRole("heading", { name: "Vaccinations" })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/dog/vaccinations?limit=50");
    const vaccinationSection = screen.getByRole("heading", { name: "Vaccinations" }).closest("section")!;
    fireEvent.click(within(vaccinationSection).getByRole("button", { name: "Add" }));
    const dialog = screen.getByRole("dialog", { name: "Add vaccination" });
    fireEvent.change(within(dialog).getByLabelText("Vaccination"), { target: { value: "Leptospirosis" } });
    fireEvent.change(within(dialog).getByLabelText("Date given"), { target: { value: "2026-06-01" } });
    fireEvent.change(within(dialog).getByLabelText("Next due (optional)"), { target: { value: "2027-06-01" } });
    fireEvent.change(within(dialog).getByLabelText("Notes (optional)"), { target: { value: "Annual booster" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add vaccination" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/dog/vaccinations" && init?.method === "POST");
      expect(call).toBeTruthy();
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({
        vaccine_name: "Leptospirosis",
        given_on: "2026-06-01",
        next_due_on: "2027-06-01",
        notes: "Annual booster",
      });
    });
  });

  it("keeps a failed dog vaccination form open with its error visible", async () => {
    const fallback = apiMock.getMockImplementation();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/dog/vaccinations" && init?.method === "POST") {
        throw new Error("Dog vaccination could not be saved");
      }
      return fallback!(path, init);
    });
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="dog"
      />,
    );

    await screen.findByRole("heading", { name: "Vaccinations" });
    const vaccinationSection = screen.getByRole("heading", { name: "Vaccinations" }).closest("section")!;
    fireEvent.click(within(vaccinationSection).getByRole("button", { name: "Add" }));
    const dialog = screen.getByRole("dialog", { name: "Add vaccination" });
    fireEvent.change(within(dialog).getByLabelText("Vaccination"), { target: { value: "Leptospirosis" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add vaccination" }));

    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Dog vaccination could not be saved");
    expect(dialog).toBeInTheDocument();
  });

  it("records a medicine dose and shows safety warnings", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="medicine"
      />,
    );

    fireEvent.click((await screen.findAllByRole("button", { name: "Record medicine" }))[0]);
    expect(apiMock).not.toHaveBeenCalledWith(expect.stringMatching(/^\/star-charts/));
    expect(apiMock).not.toHaveBeenCalledWith("/dog/status");
    expect(apiMock).not.toHaveBeenCalledWith(expect.stringMatching(/^\/children\/presents/));
    const medicineDialog = screen.getByRole("dialog", { name: "Record medicine" });
    expect(within(medicineDialog).getByLabelText("Medicine")).toHaveValue("medicine-1");
    expect(within(medicineDialog).getByLabelText("Dose")).toHaveValue("5 ml");
    fireEvent.click(within(medicineDialog).getByRole("button", { name: "Record dose" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/medicine/doses", expect.objectContaining({ method: "POST" })));
    expect(await screen.findByRole("alert")).toHaveTextContent("Dose recorded with a saved-limit warning");
    expect(screen.getByRole("alert")).toHaveTextContent("sooner than the configured interval");
  });

  it("creates and edits medicine safety settings from the web", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="medicine"
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Add medicine" }));
    const addDialog = screen.getByRole("dialog", { name: "Add medicine" });
    fireEvent.change(within(addDialog).getByLabelText("Medicine name"), { target: { value: "Nurofen" } });
    fireEvent.change(within(addDialog).getByLabelText("Saved dose amount (optional — copy from label)"), { target: { value: "5 ml" } });
    fireEvent.change(within(addDialog).getByLabelText("Minimum hours between doses"), { target: { value: "6" } });
    fireEvent.change(within(addDialog).getByLabelText("Maximum doses in 24 hours"), { target: { value: "3" } });
    fireEvent.change(within(addDialog).getByLabelText("Notes (optional)"), { target: { value: "After food" } });
    fireEvent.click(within(addDialog).getByRole("button", { name: "Add medicine" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/medicine/types" && init?.method === "POST");
      expect(call).toBeTruthy();
      expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({
        child_id: "child-1",
        name: "Nurofen",
        default_dose_amount: "5 ml",
        min_hours_between_doses: 6,
        max_doses_24h: 3,
        notes: "After food",
      });
      expect(JSON.parse(String(call?.[1]?.body)).id).toMatch(/^[0-9a-f-]{36}$/i);
    });

    fireEvent.click(await screen.findByRole("button", { name: "Edit Calpol" }));
    const editDialog = screen.getByRole("dialog", { name: "Edit medicine" });
    expect(within(editDialog).getByLabelText("Minimum hours between doses")).toHaveValue(4);
    fireEvent.change(within(editDialog).getByLabelText("Maximum doses in 24 hours"), { target: { value: "5" } });
    fireEvent.click(within(editDialog).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/medicine/types/medicine-1", expect.objectContaining({
      method: "PUT",
      body: expect.stringContaining('"max_doses_24h":5'),
    })));
  });

  it("opens the full medicine form directly from active illness mode", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Record medicine" }));
    const medicineDialog = screen.getByRole("dialog", { name: "Record medicine" });
    expect(within(medicineDialog).getByLabelText("Child")).toHaveValue("child-1");
    expect(within(medicineDialog).getByLabelText("Medicine")).toHaveValue("medicine-1");
    fireEvent.change(within(medicineDialog).getByLabelText("Given at"), { target: { value: "2026-07-11T09:35" } });
    fireEvent.click(within(medicineDialog).getByRole("button", { name: "Record dose" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/medicine/doses" && init?.method === "POST");
      expect(call).toBeTruthy();
      const body = JSON.parse(String(call?.[1]?.body));
      expect(body).toMatchObject({
        child_id: "child-1",
        medicine_type_id: "medicine-1",
        dose_amount: "5 ml",
      });
      expect(body.given_at).toBe(new Date("2026-07-11T09:35").toISOString());
    });
    expect(await screen.findByRole("alert")).toHaveTextContent("Dose recorded with a saved-limit warning");
  });

  it("starts a backdated illness with notes", async () => {
    const fallback = apiMock.getMockImplementation();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/illness/?")) return [];
      return fallback!(path, init);
    });
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Start illness mode" }));
    const dialog = screen.getByRole("dialog", { name: "Start illness mode" });
    fireEvent.change(within(dialog).getByLabelText("Started at"), { target: { value: "2026-07-10T21:15" } });
    fireEvent.change(within(dialog).getByLabelText("Symptoms or notes (optional)"), { target: { value: "Sore throat and tired" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Start illness mode" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/illness/" && init?.method === "POST");
      expect(call).toBeTruthy();
      const body = JSON.parse(String(call?.[1]?.body));
      expect(body).toMatchObject({ child_id: "child-1", notes: "Sore throat and tired" });
      expect(body.started_at).toBe(new Date("2026-07-10T21:15").toISOString());
    });
  });

  it("edits notes on an active illness", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Edit notes" }));
    const dialog = screen.getByRole("dialog", { name: "Edit illness notes" });
    fireEvent.change(within(dialog).getByLabelText("Symptoms or notes"), { target: { value: "Cough improving" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save notes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/illness/illness-1", {
      method: "PUT",
      body: JSON.stringify({ notes: "Cough improving" }),
    }));
  });

  it("logs a backdated temperature with observations", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    fireEvent.change(await screen.findByLabelText("Temperature (°C)"), { target: { value: "38.1" } });
    fireEvent.change(screen.getByLabelText("Recorded at"), { target: { value: "2026-07-11T07:45" } });
    fireEvent.change(screen.getByLabelText("Notes (optional)"), { target: { value: "After waking" } });
    fireEvent.click(screen.getByRole("button", { name: "Log temperature" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/illness/temperature" && init?.method === "POST");
      expect(call).toBeTruthy();
      const body = JSON.parse(String(call?.[1]?.body));
      expect(body).toMatchObject({
        child_id: "child-1",
        illness_id: "illness-1",
        value_celsius: 38.1,
        notes: "After waking",
      });
      expect(body.recorded_at).toBe(new Date("2026-07-11T07:45").toISOString());
    });
  });

  it("opens a prefilled dose review from illness mode and waits for submit", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Review Calpol dose entry" }));

    expect(apiMock.mock.calls.filter(([path, init]) => path === "/medicine/doses" && init?.method === "POST")).toHaveLength(0);
    const dialog = screen.getByRole("dialog", { name: "Record medicine" });
    expect(within(dialog).getByLabelText("Child")).toHaveValue("child-1");
    expect(within(dialog).getByLabelText("Medicine")).toHaveValue("medicine-1");
    expect(within(dialog).getByLabelText("Dose")).toHaveValue("5 ml");
    fireEvent.click(within(dialog).getByRole("button", { name: "Record dose" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/medicine/doses" && init?.method === "POST");
      expect(call).toBeTruthy();
      const body = JSON.parse(String(call?.[1]?.body));
      expect(body).toMatchObject({
        child_id: "child-1",
        medicine_type_id: "medicine-1",
        medicine_name: null,
        dose_amount: "5 ml",
        notes: null,
      });
      expect(body.id).toMatch(/^[0-9a-f-]{36}$/i);
    });
    expect(await screen.findByRole("alert")).toHaveTextContent("sooner than the configured interval");
  });

  it("allows review while a saved interval is active without recording", async () => {
    nextDoseAt = new Date(Date.now() + 65_000).toISOString();
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    const review = await screen.findByRole("button", { name: "Review Calpol dose entry" });
    expect(review).toBeEnabled();
    fireEvent.click(review);
    expect(screen.getByRole("dialog", { name: "Record medicine" })).toBeInTheDocument();
    expect(apiMock.mock.calls.filter(([path, init]) => path === "/medicine/doses" && init?.method === "POST")).toHaveLength(0);
  });

  it("shows the temperature timeline, medicine overlay, and a live next-dose countdown", async () => {
    nextDoseAt = new Date(Date.now() + 65_000).toISOString();
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    const chart = await screen.findByRole("img", { name: /Temperature and medicine timeline with 2 temperature readings and 1 medicine dose/ });
    expect(chart).toHaveTextContent("38.4°");
    expect(chart).toHaveTextContent("Calpol");
    expect(screen.getByRole("button", { name: "Review Calpol dose entry" })).toBeEnabled();

    const countdown = screen.getByText(/^Interval ends in/);
    const initialCountdown = countdown.textContent;
    await act(async () => {
      await new Promise((resolve) => window.setTimeout(resolve, 1_100));
    });
    await waitFor(() => expect(countdown.textContent).not.toBe(initialCountdown));
  });

  it("offers a retry when illness medicine timing fails to load", async () => {
    const fallback = apiMock.getMockImplementation();
    let detailAttempts = 0;
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/illness/illness-1/detail") {
        detailAttempts += 1;
        if (detailAttempts === 1) throw new Error("Connection dropped");
      }
      return fallback!(path, init);
    });
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="illness"
      />,
    );

    expect(await screen.findByRole("alert")).toHaveTextContent("Medicine timing could not be loaded");
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));

    await waitFor(() => expect(detailAttempts).toBe(2));
    expect(await screen.findByRole("button", { name: "Review Calpol dose entry" })).toBeEnabled();
  });

  it("routes Photos through the person-and-moment capture flow", async () => {
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="photos"
      />,
    );

    expect(await screen.findByRole("heading", { name: "Family photos" })).toBeInTheDocument();
    fireEvent.click(screen.getAllByRole("button", { name: "Add a moment" })[0]);
    const capture = screen.getByRole("dialog", { name: "Add a moment" });

    const file = new File([new Uint8Array([1, 2, 3])], "beach.jpg", { type: "image/jpeg", lastModified: Date.UTC(2024, 5, 15) });
    fireEvent.change(within(capture).getByLabelText("Choose photos for this moment"), { target: { files: [file] } });
    fireEvent.change(within(capture).getByLabelText("What was the moment?"), { target: { value: "A day at the beach" } });
    fireEvent.click(await within(capture).findByRole("button", { name: "Save 1 photo" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/child-photos/" && init?.method === "POST");
      expect(call).toBeTruthy();
      const body = call?.[1]?.body as FormData;
      expect(body).toBeInstanceOf(FormData);
      expect(body.get("child_id")).toBe("child-1");
      expect(body.getAll("files")).toHaveLength(1);
      const dates = body.getAll("taken_on");
      expect(dates).toHaveLength(1);
      expect(String(dates[0])).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    });

    expect(await screen.findByRole("button", { name: /Open Photo of Child One from/ })).toBeInTheDocument();
  });

  it("keeps the unsaved photo and its stable ID when a later batch fails", async () => {
    const fallback = apiMock.getMockImplementation();
    let uploadAttempt = 0;
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/child-photos/" && init?.method === "POST") {
        uploadAttempt += 1;
        const body = init.body as FormData;
        const operationIDs = body.getAll("client_id").map(String);
        if (uploadAttempt === 2) throw new Error("Connection dropped on the second batch");
        return {
          photos: operationIDs.map((id, index) => ({
            id: `photo-${id}`,
            child_id: "child-1",
            child_name: "Child One",
            caption: `Uploaded photo ${index + 1}`,
            taken_on: "2024-05-01",
            created_at: "2024-05-01T00:00:00Z",
            favourite: false,
            include_in_yearbook: true,
            original_available: true,
            updated_at: "2024-05-01T00:00:00Z",
            image_url: `/child-photos/photo-${id}/image`,
            original_image_url: `/child-photos/photo-${id}/image?size=original`,
          })),
        };
      }
      return fallback!(path, init);
    });
    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="photos"
      />,
    );
    expect(await screen.findByRole("heading", { name: "Family photos" })).toBeInTheDocument();
    fireEvent.click(screen.getAllByRole("button", { name: "Add a moment" })[0]);
    const capture = screen.getByRole("dialog", { name: "Add a moment" });
    const files = Array.from({ length: 6 }, (_, index) => new File(
      [new Uint8Array([index + 1])],
      `photo-${index + 1}.jpg`,
      { type: "image/jpeg", lastModified: Date.UTC(2024, 4, index + 1) },
    ));
    const picker = within(capture).getByLabelText("Choose photos for this moment");

    fireEvent.change(picker, { target: { files } });
    fireEvent.click(await within(capture).findByRole("button", { name: "Save 6 photos" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("5 saved");
    expect(screen.getByRole("alert")).toHaveTextContent("still here to retry");
    expect(screen.getAllByRole("img", { name: /Uploaded photo/ })).toHaveLength(5);

    fireEvent.click(within(capture).getByRole("button", { name: "Save 1 photo" }));
    await waitFor(() => expect(uploadAttempt).toBe(3));

    const uploadForms = apiMock.mock.calls
      .filter(([path, init]) => path === "/child-photos/" && init?.method === "POST")
      .map(([, init]) => init?.body as FormData);
    expect(uploadForms[2].getAll("client_id")).toEqual(uploadForms[1].getAll("client_id"));
    expect(screen.getAllByRole("img", { name: /Uploaded photo/ })).toHaveLength(6);
  });

  it("edits a photo's caption and removes it after confirming", async () => {
    const fallback = apiMock.getMockImplementation();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/child-photos/?")) return [{ id: "photo-1", child_id: "child-1", child_name: "Child One", caption: "Beach day", taken_on: "2024-05-01", location: null, story: null, favourite: false, include_in_yearbook: true, original_available: true, created_at: "2024-05-01T00:00:00Z", updated_at: "2024-05-01T00:00:00Z", image_url: "/child-photos/photo-1/image", original_image_url: "/child-photos/photo-1/image?size=original" }];
      if (path === "/child-photos/photo-1" && init?.method === "PATCH") return { id: "photo-1", child_id: "child-1", child_name: "Child One", caption: "Sandcastle", taken_on: "2024-05-01", location: null, story: null, favourite: false, include_in_yearbook: true, original_available: true, created_at: "2024-05-01T00:00:00Z", updated_at: "2024-05-01T00:01:00Z", image_url: "/child-photos/photo-1/image", original_image_url: "/child-photos/photo-1/image?size=original" };
      return fallback!(path, init);
    });

    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="photos"
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: /Open Beach day/ }));
    const dialog = await screen.findByRole("dialog", { name: "Beach day" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Edit" }));
    const edit = screen.getByRole("dialog", { name: "Edit this moment" });
    fireEvent.change(within(edit).getByLabelText("Moment"), { target: { value: "Sandcastle" } });
    fireEvent.click(within(edit).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/child-photos/photo-1", {
      method: "PATCH",
      body: JSON.stringify({ child_id: "child-1", caption: "Sandcastle", taken_on: "2024-05-01", location: null, story: null, include_in_yearbook: true }),
    }));

    const reopened = await screen.findByRole("dialog", { name: "Sandcastle" });
    fireEvent.click(within(reopened).getByRole("button", { name: "Remove" }));
    const confirmation = screen.getByRole("dialog", { name: "Remove this photo?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Remove photo" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/child-photos/photo-1", { method: "DELETE" }));
  });

  it("routes Artwork through the full paged gallery rather than the legacy single-photo form", async () => {
    const fallback = apiMock.getMockImplementation();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/artworks/?")) return [{
        id: "art-1",
        child_id: "child-1",
        child_name: "Child One",
        title: "Flying dragon",
        approx_date: "2026-07",
        date_precision: "month",
        age_label: "Age 6",
        notes: null,
        medium: "Crayon",
        story: null,
        child_quote: null,
        school_year: "Year 1",
        favourite: true,
        include_in_yearbook: true,
        original_available: true,
        rotation_degrees: 0,
        enhanced: false,
        created_at: "2026-07-01T10:00:00Z",
        updated_at: "2026-07-01T10:00:00Z",
        image_url: "/artworks/art-1/image?v=20260701100000",
        original_image_url: "/artworks/art-1/image?size=original",
      }];
      return fallback!(path, init);
    });

    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="artwork"
      />,
    );

    expect(await screen.findByText("Flying dragon")).toBeInTheDocument();
    expect(screen.getByAltText("Flying dragon")).toHaveAttribute("src", "/api/artworks/art-1/image?v=20260701100000&size=thumb");
    fireEvent.click(screen.getByRole("button", { name: "Add artwork" }));
    const dialog = screen.getByRole("dialog", { name: "Add artwork" });
    expect(within(dialog).getByLabelText(/Photograph or choose a pile/)).toHaveAttribute("multiple");
    expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("/artworks/?offset=0&limit=40"));
  });

  it("keeps Birthdays household-wide and forwards exact linked task and Planner event IDs", async () => {
    const openTask = vi.fn();
    const openEvent = vi.fn();
    const openPresents = vi.fn();
    const birthday = {
      id: "birthday-1",
      person_name: "Nana",
      date_of_birth: null,
      birth_month: 9,
      birth_day: 3,
      year_known: false,
      relationship: "family",
      reminder_days_before: 14,
      age: null,
      turning_age: null,
      next_birthday: "2026-09-03",
      days_until: 12,
      preparation_due: true,
    };
    const fallback = apiMock.getMockImplementation();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/birthdays/") return [birthday];
      if (path === "/birthdays/birthday-1/preparation" && !init?.method) return {
        birthday,
        occurrence_year: 2026,
        card_status: "not_started",
        card_message: null,
        celebration_status: "planning",
        notes: null,
        tasks: [{ id: "task-card", title: "Post Nana's card", completed: false }],
        calendar_event: { id: "event-party", title: "Nana's birthday", completed: false },
        gifts_total: 0,
        gifts_remaining: 0,
      };
      return fallback!(path, init);
    });

    render(
      <FamilyView
        members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
        revision={0}
        onDataChanged={vi.fn()}
        initialArea="birthdays"
        onOpenBirthdayTask={openTask}
        onOpenBirthdayEvent={openEvent}
        onOpenBirthdayPresents={openPresents}
      />,
    );

    expect(screen.queryByRole("group", { name: "Choose child" })).not.toBeInTheDocument();
    fireEvent.click(await screen.findByRole("button", { name: /Nana.*3 September/ }));
    fireEvent.click(await screen.findByRole("button", { name: /Post Nana's card/ }));
    expect(openTask).toHaveBeenCalledWith("task-card");
    fireEvent.click(screen.getByRole("button", { name: /Nana's birthday.*In Planner/ }));
    expect(openEvent).toHaveBeenCalledWith("event-party", "2026-09-03");
    fireEvent.click(screen.getByRole("button", { name: /Choose a present.*Open Presents/ }));
    expect(openPresents).toHaveBeenCalledWith("birthday-1");
  });
});
