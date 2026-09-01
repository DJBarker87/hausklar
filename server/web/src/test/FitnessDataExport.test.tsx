import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { installAuthIdentity } from "../api";
import { FitnessDataExportCard } from "../views/fitness/FitnessProgressView";

describe("Fitness owner data export", () => {
  afterEach(() => vi.restoreAllMocks());

  it("downloads the authenticated backend ZIP without building a client export", async () => {
    const archive = new Blob(["private archive"], { type: "application/zip" });
    const response = {
      ok: true,
      status: 200,
      headers: new Headers({ "Content-Type": "application/zip", "Content-Disposition": "attachment; filename=hausklar-fitness-export-2026-08-02.zip" }),
      blob: vi.fn().mockResolvedValue(archive),
      json: vi.fn(),
    } as unknown as Response;
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => String(input).endsWith("/auth/web/session")
      ? new Response(JSON.stringify({ id: "dom", family_id: "family-a", email: "dom@example.invalid", name: "Alex", role: "admin", priority: 5 }), { status: 200, headers: { "content-type": "application/json" } })
      : response);
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:fitness-export");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    let downloadedAs = "";
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function click(this: HTMLAnchorElement) { downloadedAs = this.download; });

    render(<FitnessDataExportCard online />);
    expect(screen.getByText(/private copy of the Fitness records and files/)).toBeInTheDocument();
    expect(screen.getByText(/may take a moment if it includes activity files or private photos/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Download ZIP" }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/fitness/export", {
      credentials: "same-origin",
      cache: "no-store",
      headers: { Accept: "application/zip" },
    }));
    await waitFor(() => expect(downloadedAs).toBe("hausklar-fitness-export-2026-08-02.zip"));
    expect(URL.createObjectURL).toHaveBeenCalledWith(archive);
  });

  it("discards an in-flight archive if the signed-in account changes", async () => {
    installAuthIdentity({ id: "dom", family_id: "family-a" });
    const archive = new Blob(["private archive"], { type: "application/zip" });
    const response = {
      ok: true,
      status: 200,
      headers: new Headers({ "Content-Type": "application/zip" }),
      blob: vi.fn().mockImplementation(async () => {
        installAuthIdentity({ id: "kat", family_id: "family-a" });
        return archive;
      }),
      json: vi.fn(),
    } as unknown as Response;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => String(input).endsWith("/auth/web/session")
      ? new Response(JSON.stringify({ id: "dom", family_id: "family-a", email: "dom@example.invalid", name: "Alex", role: "admin", priority: 5 }), { status: 200, headers: { "content-type": "application/json" } })
      : response);
    const createObjectUrl = vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:should-not-download");

    render(<FitnessDataExportCard online />);
    fireEvent.click(screen.getByRole("button", { name: "Download ZIP" }));

    expect(await screen.findByText(/signed-in account changed/)).toBeInTheDocument();
    expect(createObjectUrl).not.toHaveBeenCalled();
  });

  it("refreshes an expired browser session before requesting the ZIP", async () => {
    const archive = new Blob(["private archive"], { type: "application/zip" });
    const paths: string[] = [];
    let sessionCalls = 0;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const path = String(input);
      paths.push(path);
      if (path.endsWith("/auth/web/session")) {
        sessionCalls += 1;
        if (sessionCalls === 1) return new Response(JSON.stringify({ detail: "Expired" }), { status: 401, headers: { "content-type": "application/json" } });
        return new Response(JSON.stringify({ id: "dom", family_id: "family-a", email: "dom@example.invalid", name: "Alex", role: "admin", priority: 5 }), { status: 200, headers: { "content-type": "application/json" } });
      }
      if (path.endsWith("/auth/web/refresh")) return new Response(null, { status: 204 });
      if (path.endsWith("/fitness/export")) return {
        ok: true,
        status: 200,
        headers: new Headers({ "content-type": "application/zip" }),
        blob: vi.fn().mockResolvedValue(archive),
        json: vi.fn(),
      } as unknown as Response;
      throw new Error(path);
    });
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:fitness-export");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);

    render(<FitnessDataExportCard online />);
    fireEvent.click(screen.getByRole("button", { name: "Download ZIP" }));

    await waitFor(() => expect(URL.createObjectURL).toHaveBeenCalledWith(archive));
    expect(paths).toEqual([
      "/api/auth/web/session",
      "/api/auth/web/refresh",
      "/api/auth/web/session",
      "/api/fitness/export",
    ]);
  });
});
