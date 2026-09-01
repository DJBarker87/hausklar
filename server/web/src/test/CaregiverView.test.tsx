import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { StrictMode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { CaregiverSessionView, CaregiverSetupView } from "../views/CaregiverView";

const handover = {
  id: "handover-1",
  house: {
    address: "1 Family Road\nExample Town",
    wifi_name: "HausKlar",
    wifi_password: "tea-and-toast",
    emergency_instructions: "Call us first; 999 for an emergency.",
    house_instructions: "The spare key is by the back door.",
    dog_instructions: "Bismarck has already eaten.",
  },
  children: [{
    id: "profile-max",
    child_id: "max",
    child_name: "Child One",
    care_notes: "Keep his inhaler nearby.",
    allergies: "No known allergies",
    food: "Toast after school.",
    comfort: "Blue rabbit and a story.",
    toileting: "Independent; remind before bed.",
    bedtime: "Pyjamas at 19:00, lights out 19:30.",
  }],
  contacts: [{ id: "contact-dom", name: "Alex", phone: "+00000000004", relationship: "Dad", priority: 0 }],
  readiness: {
    ready: true,
    complete_count: 12,
    total_count: 12,
    items: [{ key: "address", label: "Home address", ready: true }],
  },
  updated_at: "2026-08-09T12:00:00Z",
};

const createdBooking = {
  id: "booking-1",
  label: "Saturday evening",
  starts_at: "2030-08-10T17:00:00Z",
  expires_at: "2030-08-10T22:00:00Z",
  child_ids: ["max"],
  child_names: ["Child One"],
  status: "upcoming",
  created_at: "2026-08-09T12:00:00Z",
  share_url: "https://hausklar.example/?caregiver=1#invite=one-time-secret",
};

function jsonResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("caregiver handover", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("shows parent-owned readiness and creates narrowly scoped access", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      if (path.endsWith("/handover") && !init?.method) return jsonResponse(handover);
      if (path.endsWith("/bookings") && !init?.method) return jsonResponse([]);
      if (path.endsWith("/bookings") && init?.method === "POST") return jsonResponse(createdBooking);
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<CaregiverSetupView />);

    expect(await screen.findByRole("heading", { name: "Ready to share" })).toBeInTheDocument();
    expect(screen.getByText("Parent-owned care details, shared only for one booking.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Edit handover" }));
    const wifiPassword = screen.getByLabelText("Wi-Fi password");
    expect(wifiPassword).toHaveAttribute("type", "password");
    fireEvent.click(screen.getByRole("button", { name: "Show Wi-Fi password" }));
    expect(wifiPassword).toHaveAttribute("type", "text");
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    fireEvent.click(screen.getByRole("button", { name: "Create sitter link" }));
    fireEvent.change(screen.getByLabelText("Booking name"), { target: { value: "Saturday evening" } });
    fireEvent.change(screen.getByLabelText("Starts"), { target: { value: "2030-08-10T18:00" } });
    fireEvent.change(screen.getByLabelText("Ends"), { target: { value: "2030-08-10T23:00" } });
    fireEvent.click(screen.getByRole("button", { name: "Create private link" }));

    await screen.findByRole("heading", { name: "Sitter link ready" });
    const post = fetchMock.mock.calls.find(([, init]) => init?.method === "POST");
    expect(post?.[0]).toBe("/api/babysitter/bookings");
    expect(JSON.parse(String(post?.[1]?.body))).toMatchObject({
      label: "Saturday evening",
      child_ids: ["max"],
    });
    expect(screen.getByText(/opened once/i)).toBeInTheDocument();
  });

  it("confirms before revoking an open caregiver session", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      if (path.endsWith("/handover") && !init?.method) return jsonResponse(handover);
      if (path.endsWith("/bookings") && !init?.method) return jsonResponse([createdBooking]);
      if (path.endsWith("/bookings/booking-1") && init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<CaregiverSetupView />);

    fireEvent.click(await screen.findByRole("button", { name: "Revoke" }));
    expect(screen.getByRole("heading", { name: "Revoke caregiver access?" })).toBeInTheDocument();
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Revoke now" }));
    await waitFor(() => expect(fetchMock.mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(true));
    expect(await screen.findByText("Caregiver access revoked.")).toBeInTheDocument();
  });

  it("exchanges the fragment once, clears it, and renders a read-only Now/Next/Emergency view", async () => {
    window.history.replaceState({}, "", "/?caregiver=1#invite=one-time-secret");
    const session = {
      booking: { label: "Saturday evening", starts_at: "2030-08-10T17:00:00Z", expires_at: "2030-08-10T22:00:00Z" },
      now: {
        children: [{
          child_id: "max", name: "Child One", age: 10,
          care_notes: "Keep his inhaler nearby.", allergies: "No known allergies",
          food: "Toast after school.", comfort: "Blue rabbit and a story.",
          toileting: "Independent.", bedtime: "Lights out 19:30.",
        }],
        active_naps: [],
        medicine_schedule: [{ child_name: "Child One", medicine_name: "Inhaler", dosage_notes: "Follow the labelled plan.", last_given_at: null }],
      },
      next: { events: [{ title: "Bedtime", start_time: "2030-08-10T19:00:00Z", end_time: "2030-08-10T19:30:00Z", location: "Upstairs" }] },
      emergency: {
        address: "1 Family Road\nExample Town",
        instructions: "Call us first; 999 for an emergency.",
        contacts: handover.contacts,
        allergies: [{ child_name: "Child One", details: "No known allergies" }],
      },
      house: handover.house,
      read_only: true,
      medicine_disclaimer: "Read-only record. Follow the parent-provided label or care plan; HausKlar does not recommend or record doses here.",
    };
    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      if (path.endsWith("/sessions/exchange") && init?.method === "POST") return jsonResponse({ status: "active" });
      if (path.endsWith("/sessions/view")) return jsonResponse(session);
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<StrictMode><CaregiverSessionView /></StrictMode>);

    expect(await screen.findByRole("heading", { name: "Saturday evening" })).toBeInTheDocument();
    expect(window.location.hash).toBe("");
    const exchange = fetchMock.mock.calls.find(([path]) => String(path).endsWith("/sessions/exchange"));
    expect(JSON.parse(String(exchange?.[1]?.body))).toEqual({ code: "one-time-secret" });
    expect(screen.getByRole("heading", { name: "Child One, 10" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /record medicine/i })).not.toBeInTheDocument();
    expect(screen.queryByText("tea-and-toast")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Show password" }));
    expect(screen.getByText("tea-and-toast")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Next" }));
    expect(await screen.findByText("Bedtime")).toBeInTheDocument();
    expect(screen.getByText(/Upstairs/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Emergency" }));
    expect(await screen.findByRole("link", { name: /Alex.*Dad.*\+00000000004/ })).toHaveAttribute("href", "tel:+00000000004");
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  });
});
