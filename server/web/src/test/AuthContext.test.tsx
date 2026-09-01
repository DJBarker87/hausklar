import { StrictMode } from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";

import { getAuthSessionEpoch, type AuthExpiredDetail } from "../api";
import { AuthProvider, useAuth } from "../AuthContext";
import { cachedFitnessRecords, saveFitnessRecord } from "../fitness/offlineStore";
import {
  cacheOfflineSession,
  cacheCycleProfiles,
  cachedCycleProfiles,
  enqueueMutation,
  queuedMutations,
  setOfflineQueueOwner,
} from "../offlineQueue";

const user = {
  id: "user-b",
  family_id: "family-b",
  name: "B",
  email: "b@example.invalid",
  role: "user",
  priority: 10,
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function AuthProbe() {
  const { loading, signIn, signOut, user: currentUser } = useAuth();
  return <>
    <div data-testid="identity">{loading ? "loading" : currentUser?.id ?? "signed-out"}</div>
    <button type="button" onClick={() => void signOut()}>Sign out probe</button>
    <button type="button" onClick={() => void signIn("b@example.invalid", "password")}>Sign in B probe</button>
  </>;
}

describe("AuthProvider session epochs", () => {
  const originalServiceWorker = Object.getOwnPropertyDescriptor(navigator, "serviceWorker");
  const originalIndexedDB = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
  const originalOnline = Object.getOwnPropertyDescriptor(navigator, "onLine");

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    if (originalServiceWorker) Object.defineProperty(navigator, "serviceWorker", originalServiceWorker);
    else Reflect.deleteProperty(navigator, "serviceWorker");
    if (originalIndexedDB) Object.defineProperty(globalThis, "indexedDB", originalIndexedDB);
    else Reflect.deleteProperty(globalThis, "indexedDB");
    if (originalOnline) Object.defineProperty(navigator, "onLine", originalOnline);
    else Reflect.deleteProperty(navigator, "onLine");
  });

  it("ignores stale expiry events but clears the current identity", async () => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(jsonResponse(user)));
    render(<AuthProvider><AuthProbe /></AuthProvider>);

    expect(await screen.findByText("user-b")).toBeInTheDocument();
    const currentEpoch = getAuthSessionEpoch();

    act(() => {
      window.dispatchEvent(new CustomEvent<AuthExpiredDetail>("hausklar:auth-expired", {
        detail: { epoch: currentEpoch - 1 },
      }));
    });
    expect(screen.getByTestId("identity")).toHaveTextContent("user-b");

    act(() => {
      window.dispatchEvent(new CustomEvent<AuthExpiredDetail>("hausklar:auth-expired", {
        detail: { epoch: currentEpoch },
      }));
    });
    expect(screen.getByTestId("identity")).toHaveTextContent("signed-out");
  });

  it("restores one browser session when Strict Mode starts two checks", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => jsonResponse(user));
    vi.stubGlobal("fetch", fetchMock);

    render(<StrictMode><AuthProvider><AuthProbe /></AuthProvider></StrictMode>);

    expect(await screen.findByText("user-b")).toBeInTheDocument();
    expect(fetchMock.mock.calls.filter(([path]) => String(path) === "/api/auth/web/session")).toHaveLength(2);
  });

  it("opens the last signed-in family immediately when offline", async () => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    await cacheOfflineSession(user);
    Object.defineProperty(navigator, "onLine", { configurable: true, value: false });
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);

    render(<AuthProvider><AuthProbe /></AuthProvider>);

    expect(await screen.findByText("user-b")).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("revokes only A's browser subscription before logout and cannot carry it into B's session", async () => {
    const userA = { ...user, id: "user-a", family_id: "family-a", email: "a@example.invalid", name: "A" };
    const events: string[] = [];
    const unsubscribe = vi.fn(async () => { events.push("browser-unsubscribe"); return true; });
    const hausklarNotificationClose = vi.fn();
    const unrelatedNotificationClose = vi.fn();
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue({
          endpoint: "https://push.example/browser-a",
          unsubscribe,
        }),
      },
      getNotifications: vi.fn().mockResolvedValue([
        { tag: "hausklar-task", close: hausklarNotificationClose },
        { tag: "another-feature", close: unrelatedNotificationClose },
      ]),
    };
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: { ready: Promise.resolve(registration) },
    });

    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      const path = String(input);
      if (path === "/api/auth/web/session") return jsonResponse(userA);
      if (path.startsWith("/api/reminders/push/subscriptions/")) {
        events.push("server-remove-a-browser");
        expect(init?.method).toBe("DELETE");
        return new Response(null, { status: 204 });
      }
      if (path === "/api/auth/web/logout") {
        events.push("logout-a");
        return new Response(null, { status: 204 });
      }
      if (path === "/api/auth/web/login") {
        events.push("login-b");
        return jsonResponse(user);
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<AuthProvider><AuthProbe /></AuthProvider>);

    expect(await screen.findByText("user-a")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Sign out probe" }));
    await waitFor(() => expect(screen.getByTestId("identity")).toHaveTextContent("signed-out"));
    fireEvent.click(screen.getByRole("button", { name: "Sign in B probe" }));
    expect(await screen.findByText("user-b")).toBeInTheDocument();

    const removalPath = fetchMock.mock.calls.map(([path]) => String(path)).find((path) => (
      path.startsWith("/api/reminders/push/subscriptions/")
    ));
    expect(removalPath).toMatch(/^\/api\/reminders\/push\/subscriptions\/[a-f0-9]{64}$/);
    expect(fetchMock.mock.calls.map(([path]) => String(path))).not.toContain("/api/reminders/push/subscriptions");
    expect(events).toEqual(["server-remove-a-browser", "browser-unsubscribe", "logout-a", "login-b"]);
    expect(hausklarNotificationClose).toHaveBeenCalledOnce();
    expect(unrelatedNotificationClose).not.toHaveBeenCalled();
  });

  it("purges private owner caches on explicit sign-out", async () => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    const fetchMock = vi.fn<typeof fetch>(async (input) => {
      const path = String(input);
      if (path === "/api/auth/web/session") return jsonResponse(user);
      if (path === "/api/auth/web/logout") return new Response(null, { status: 204 });
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<AuthProvider><AuthProbe /></AuthProvider>);
    expect(await screen.findByText("user-b")).toBeInTheDocument();

    await saveFitnessRecord("goal", {
      goal_type: "running_consistency",
      metric_key: "running.sessions_weekly",
      name: "Private goal",
      starts_on: "2026-08-03",
      status: "active",
    });
    await enqueueMutation({ path: "/tasks/", method: "POST", body: "{}" });
    await cacheCycleProfiles([{ id: "private-cycle" }]);
    fireEvent.click(screen.getByRole("button", { name: "Sign out probe" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(
      "/api/auth/web/logout",
      expect.objectContaining({ method: "POST" }),
    ));

    setOfflineQueueOwner(user);
    expect(await cachedFitnessRecords("goal")).toEqual([]);
    expect(await queuedMutations()).toEqual([]);
    expect(await cachedCycleProfiles()).toBeNull();
  });

  it("keeps offline Fitness data through a transient auth-expiry lock", async () => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(jsonResponse(user)));
    render(<AuthProvider><AuthProbe /></AuthProvider>);
    expect(await screen.findByText("user-b")).toBeInTheDocument();
    await saveFitnessRecord("goal", {
      goal_type: "running_consistency",
      metric_key: "running.sessions_weekly",
      name: "Resume after sign-in",
      starts_on: "2026-08-03",
      status: "active",
    });

    const currentEpoch = getAuthSessionEpoch();
    act(() => {
      window.dispatchEvent(new CustomEvent<AuthExpiredDetail>("hausklar:auth-expired", {
        detail: { epoch: currentEpoch },
      }));
    });
    setOfflineQueueOwner(user);

    expect(await cachedFitnessRecords("goal")).toEqual([
      expect.objectContaining({ name: "Resume after sign-in" }),
    ]);
  });
});
