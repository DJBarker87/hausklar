import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { HomeView } from "../views/HomeView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const layout = {
  width: 900,
  height: 820,
  floors: [
    { id: 0, name: "Ground floor", rooms: [{ id: "kitchen", label: "Kitchen", bounds: { x: 463, y: 463, width: 368, height: 289 }, polygon: [[463, 519], [758, 519], [758, 463], [831, 463], [831, 752], [463, 752]], light_entity_ids: ["light.example_3f2a461f"], label_at: [650, 650] }], walls: [[463, 519, 758, 519]], stairs: [] },
    { id: 1, name: "First floor", rooms: [{ id: "bathroom", label: "Bathroom", bounds: { x: 490, y: 519, width: 341, height: 233 }, light_entity_ids: ["light.example_f62d9439"], label_at: [660, 650] }], walls: [[490, 519, 831, 519]], stairs: [] },
  ],
  temperatures: [{ floor: 0, entity_ids: ["climate.example_9feafd80"], at: [504, 546] }],
  doors: [{ floor: 0, entity_ids: ["binary_sensor.example_e1938001"], at: [567, 155], label: "Front door" }],
};

const snapshot = {
  configured: true,
  available: true,
  entities: [
    { entity_id: "light.example_3f2a461f", name: "Kitchen lights", domain: "light", state: "on" },
    { entity_id: "light.example_d7ab5b9b", name: "Hall lights", domain: "light", state: "off" },
    { entity_id: "light.porch", name: "Porch lights", domain: "light", state: "unavailable" },
    { entity_id: "climate.example_9feafd80", name: "Kitchen heating", domain: "climate", state: "heat", current_temperature: 20.5, temperature: 21, hvac_action: "heating", min_temp: 5, max_temp: 30 },
    { entity_id: "sensor.bathroom_humidity", name: "Bathroom humidity", domain: "sensor", state: "68", device_class: "humidity", unit_of_measurement: "%" },
    { entity_id: "sensor.bathroom_temperature", name: "Bathroom temperature", domain: "sensor", state: "19.1", device_class: "temperature", unit_of_measurement: "°C" },
    { entity_id: "sensor.example_71c4f84f", name: "Bathroom dew point", domain: "sensor", state: "14.2", device_class: "temperature", unit_of_measurement: "°C" },
    { entity_id: "binary_sensor.example_e1938001", name: "Front door", domain: "binary_sensor", state: "off", device_class: "door" },
    { entity_id: "binary_sensor.example_e5ed4cd5", name: "Hot water boost", domain: "binary_sensor", state: "off" },
    { entity_id: "water_heater.thermostat_3", name: "Hot water", domain: "water_heater", state: "eco", operation_mode: "eco", operation_list: ["eco", "on", "off"] },
    { entity_id: "input_select.house_mode", name: "House mode", domain: "input_select", state: "Home" },
    { entity_id: "camera.front_door", name: "Front door camera", domain: "camera", state: "recording" },
  ],
  sitrep: {
    tone: "calm",
    headline: "All quiet",
    summary: "Doors and safety sensors are clear · 0 rooms heating · 1 light on",
    exceptions: [],
    updated_at: "2026-08-09T12:00:00Z",
  },
  manifest: {
    rooms: [
      { id: "kitchen", name: "Kitchen", floor: 0, entity_ids: ["light.example_3f2a461f", "climate.example_9feafd80"], light_entity_ids: ["light.example_3f2a461f"] },
      { id: "hallway", name: "Hall", floor: 0, entity_ids: ["light.example_d7ab5b9b", "light.porch", "binary_sensor.example_e1938001"], light_entity_ids: ["light.example_d7ab5b9b", "light.porch"] },
      { id: "bathroom", name: "Bathroom", floor: 1, entity_ids: ["sensor.bathroom_humidity", "sensor.bathroom_temperature", "sensor.example_71c4f84f"], light_entity_ids: [] },
    ],
    entities: [
      { entity_id: "light.example_3f2a461f", name: "Kitchen lights", domain: "light", room_id: "kitchen", room_name: "Kitchen", control_kind: "light", capabilities: ["toggle", "turn_off", "turn_on"], favourite: true, advanced: false },
      { entity_id: "light.example_d7ab5b9b", name: "Hall lights", domain: "light", room_id: "hallway", room_name: "Hall", control_kind: "light", capabilities: ["toggle", "turn_off", "turn_on"], favourite: false, advanced: false },
      { entity_id: "light.porch", name: "Porch lights", domain: "light", room_id: "hallway", room_name: "Hall", control_kind: "light", capabilities: ["view"], favourite: false, advanced: false },
      { entity_id: "climate.example_9feafd80", name: "Kitchen heating", domain: "climate", room_id: "kitchen", room_name: "Kitchen", control_kind: "climate", capabilities: ["set_temperature"], favourite: false, advanced: false },
      { entity_id: "sensor.bathroom_humidity", name: "Bathroom humidity", domain: "sensor", room_id: "bathroom", room_name: "Bathroom", control_kind: "sensor", capabilities: ["view"], favourite: false, advanced: false },
      { entity_id: "sensor.bathroom_temperature", name: "Bathroom temperature", domain: "sensor", room_id: "bathroom", room_name: "Bathroom", control_kind: "sensor", capabilities: ["view"], favourite: false, advanced: false },
      { entity_id: "sensor.example_71c4f84f", name: "Bathroom dew point", domain: "sensor", room_id: "bathroom", room_name: "Bathroom", control_kind: "sensor", capabilities: ["view"], favourite: false, advanced: false },
      { entity_id: "binary_sensor.example_e1938001", name: "Front door", domain: "binary_sensor", room_id: "hallway", room_name: "Hall", control_kind: "sensor", capabilities: ["view"], favourite: false, advanced: false },
      { entity_id: "input_select.house_mode", name: "House mode", domain: "input_select", room_id: null, room_name: null, control_kind: "mode", capabilities: ["select_option"], favourite: false, advanced: false },
      { entity_id: "camera.front_door", name: "Front door camera", domain: "camera", room_id: null, room_name: null, control_kind: "camera", capabilities: ["view"], favourite: false, advanced: true },
    ],
    favourite_entity_ids: ["light.example_3f2a461f"],
    mode_selector: { entity_id: "input_select.house_mode", name: "House mode", current: "Home", options: ["Home", "Away", "Night"] },
    broad_action_scopes: ["favourites", "room", "all"],
    advanced_features: ["diagnostics", "floor_plan_2d", "floor_plan_3d", "cameras"],
  },
};

describe("HomeView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/home/layout") return layout as never;
      if (path === "/home/status") return snapshot as never;
      if (path === "/home/temperature-history/climate.example_9feafd80") return {
        entity_id: "climate.example_9feafd80",
        unit: "°C",
        hours: 24,
        points: [
          { recorded_at: "2026-08-14T12:00:00Z", temperature: 19.2, target_temperature: 21, heating: false },
          { recorded_at: "2026-08-15T12:00:00Z", temperature: 20.5, target_temperature: 21, heating: true },
        ],
      } as never;
      if (path === "/home/actions") {
        expect(options).toMatchObject({ method: "POST" });
        return { success: true } as never;
      }
      if (path === "/home/broad-actions") return { success: true, entity_ids: ["light.example_3f2a461f", "light.example_d7ab5b9b"] } as never;
      if (path === "/home/services") return { success: true } as never;
      if (path === "/home/favourites") return { entity_ids: ["light.example_3f2a461f", "climate.example_9feafd80"] } as never;
      return [] as never;
    });
  });

  it("leads with room temperatures and hot-water boost while keeping full controls quiet", async () => {
    render(<HomeView revision={0} notify={vi.fn()} />);

    const sitrep = await screen.findByRole("heading", { name: "All quiet" });
    const temperatures = screen.getByRole("heading", { name: "Room temperatures" });
    const glance = temperatures.closest("section");
    expect(glance).not.toBeNull();
    expect(sitrep.compareDocumentPosition(temperatures) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByText("No exceptions to deal with.")).toBeInTheDocument();
    expect(within(glance!).getByText("Kitchen")).toBeInTheDocument();
    expect(within(glance!).getByText("20.5°")).toBeInTheDocument();
    expect(within(glance!).queryByText("21.0°")).not.toBeInTheDocument();
    expect(within(glance!).getByText("19.1°")).toBeInTheDocument();
    expect(within(glance!).getByText("Dew 14.2°")).toBeInTheDocument();
    expect(within(glance!).getAllByText("—")).toHaveLength(1);
    expect(within(glance!).getByRole("button", { name: "Boost hot water" })).toBeEnabled();
    const fullControls = screen.getByText("Full controls").closest("details");
    expect(fullControls).not.toBeNull();
    expect(fullControls).not.toHaveAttribute("open");
    expect(apiMock).not.toHaveBeenCalledWith("/home/layout");
    expect(screen.queryByRole("heading", { name: "House map" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByText("Full controls"));
    expect(screen.getByRole("heading", { name: "Favourites" })).toBeInTheDocument();
    expect(screen.getAllByText("Bathroom humidity").length).toBeGreaterThan(0);
    expect(screen.getAllByText("68 %").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Kitchen lights").length).toBeGreaterThan(0);

    fireEvent.click(screen.getByText("Advanced"));

    expect(await screen.findByRole("heading", { name: "House map" })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/home/layout");
    expect(screen.getByRole("img", { name: /Ground floor house map/ })).toBeInTheDocument();
    expect(screen.getByText("Front door camera")).toBeInTheDocument();
  });

  it("starts the exact hot-water boost in one tap", async () => {
    const notify = vi.fn();
    render(<HomeView revision={0} notify={notify} />);

    fireEvent.click(await screen.findByRole("button", { name: "Boost hot water" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/home/services", {
      method: "POST",
      body: JSON.stringify({
        domain: "water_heater",
        service: "set_operation_mode",
        data: { entity_id: "water_heater.thermostat_3", operation_mode: "on" },
      }),
    }));
    expect(notify).toHaveBeenCalledWith("Hot water boost started.");
  });

  it("opens a heating room into its temperature graph and target control", async () => {
    render(<HomeView revision={0} notify={vi.fn()} />);

    const temperatures = await screen.findByRole("heading", { name: "Room temperatures" });
    const glance = temperatures.closest("section")!;
    const kitchen = within(glance).getByRole("button", { name: /Kitchen, 20.5 degrees, heating/i });
    expect(kitchen).toHaveClass("is-heating");

    fireEvent.click(kitchen);

    const dialog = screen.getByRole("dialog", { name: "Kitchen" });
    expect(within(dialog).getByText("Heating now")).toBeInTheDocument();
    expect(await within(dialog).findByRole("img", { name: /ranged from 19.2 to 20.5 degrees/i })).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Raise Kitchen target temperature" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/home/actions", {
      method: "POST",
      body: JSON.stringify({ entity_id: "climate.example_9feafd80", action: "set_temperature", value: 21.5 }),
    }));
  });

  it("requires scope selection and confirmation before a broad light action", async () => {
    render(<HomeView revision={0} notify={vi.fn()} />);
    await screen.findByRole("heading", { name: "All quiet" });
    fireEvent.click(screen.getByText("Full controls"));

    fireEvent.click(screen.getByRole("button", { name: "Control several lights" }));
    const dialog = screen.getByRole("dialog", { name: "Control several lights" });
    fireEvent.click(within(dialog).getByRole("radio", { name: /All controllable lights/i }));
    expect(within(dialog).getByText("2 lights match this scope.")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Review action" }));

    expect(await screen.findByRole("heading", { name: "Turn these lights off?" })).toBeInTheDocument();
    expect(screen.getByText(/every controllable light \(2 lights\)/i)).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/home/broad-actions", expect.anything());
    fireEvent.click(screen.getByRole("button", { name: "Turn lights off" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/home/broad-actions", {
      method: "POST",
      body: JSON.stringify({ action: "lights_off", scope: "all", room_id: null, confirmed: true }),
    }));
  });

  it("selects an exact house mode and confirms it instead of cycling", async () => {
    render(<HomeView revision={0} notify={vi.fn()} />);
    await screen.findByRole("heading", { name: "All quiet" });
    fireEvent.click(screen.getByText("Full controls"));

    fireEvent.click(screen.getByRole("button", { name: "Change House mode from Home" }));
    const picker = screen.getByRole("dialog", { name: "Choose house mode" });
    fireEvent.click(within(picker).getByRole("radio", { name: "Night" }));
    fireEvent.click(within(picker).getByRole("button", { name: "Review change" }));

    expect(await screen.findByRole("heading", { name: "Change house mode to Night?" })).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/home/services", expect.anything());
    fireEvent.click(screen.getByRole("button", { name: "Use Night" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/home/services", {
      method: "POST",
      body: JSON.stringify({
        domain: "input_select",
        service: "select_option",
        data: { entity_id: "input_select.house_mode", option: "Night" },
      }),
    }));
  });

  it("saves family favourites from the manifest rather than a local hard-coded list", async () => {
    render(<HomeView revision={0} notify={vi.fn()} />);
    await screen.findByRole("heading", { name: "All quiet" });
    fireEvent.click(screen.getByText("Full controls"));

    fireEvent.click(screen.getByRole("button", { name: "Manage" }));
    const dialog = screen.getByRole("dialog", { name: "Choose House favourites" });
    fireEvent.click(within(dialog).getByRole("checkbox", { name: /Kitchen heating/i }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Save 2 favourites" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/home/favourites", {
      method: "PUT",
      body: JSON.stringify({ entity_ids: ["light.example_3f2a461f", "climate.example_9feafd80"] }),
    }));
  });

  it("states that live data is unavailable without substituting mock controls", async () => {
    apiMock.mockImplementation(async (path) => path === "/home/status"
      ? { configured: true, available: false, entities: [] } as never
      : [] as never);

    render(<HomeView revision={0} notify={vi.fn()} />);

    expect(await screen.findByText(/No sample state has been substituted/i)).toBeInTheDocument();
    expect(screen.queryByText("Kitchen lights")).not.toBeInTheDocument();
  });
});
