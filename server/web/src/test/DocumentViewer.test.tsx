import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { DocumentViewer } from "../components/DocumentViewer";
import type { LinkedDocument } from "../types";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const original: LinkedDocument = {
  id: "doctor-letter",
  title: "Doctor letter",
  original_filename: "doctor.pdf",
  media_type: "application/pdf",
  file_size: 2048,
  download_url: "/api/documents/doctor-letter/content",
};

describe("DocumentViewer", () => {
  beforeEach(() => apiMock.mockReset());

  it("refreshes the web session before assigning the protected media URL", async () => {
    let resolveSession!: () => void;
    apiMock.mockReturnValue(new Promise((resolve) => { resolveSession = () => resolve({}); }));

    render(<DocumentViewer document={original} onOpenChange={vi.fn()} />);

    const viewer = screen.getByRole("dialog", { name: "Doctor letter" });
    expect(apiMock).toHaveBeenCalledWith("/auth/web/session", { signal: expect.any(AbortSignal) });
    expect(within(viewer).getByRole("status")).toHaveTextContent("Opening document");
    expect(within(viewer).queryByTitle("Doctor letter")).not.toBeInTheDocument();

    await act(async () => resolveSession());

    expect(await within(viewer).findByTitle("Doctor letter")).toHaveAttribute("src", original.download_url);
    expect(within(viewer).getByTitle("Doctor letter")).toHaveAttribute("sandbox", "allow-same-origin");
  });

  it("shows an actionable error and retries session preparation", async () => {
    apiMock.mockRejectedValueOnce(new Error("Your session could not be refreshed."));
    apiMock.mockResolvedValueOnce({});
    render(<DocumentViewer document={original} onOpenChange={vi.fn()} />);

    const viewer = screen.getByRole("dialog", { name: "Doctor letter" });
    expect(await within(viewer).findByRole("alert")).toHaveTextContent("Your session could not be refreshed.");
    expect(within(viewer).queryByTitle("Doctor letter")).not.toBeInTheDocument();
    expect(within(viewer).queryByRole("link", { name: "Open separately" })).not.toBeInTheDocument();

    fireEvent.click(within(viewer).getByRole("button", { name: "Try again" }));

    expect(await within(viewer).findByTitle("Doctor letter")).toHaveAttribute("src", original.download_url);
    expect(apiMock).toHaveBeenCalledTimes(2);
  });

  it("unmounts a broken preview but keeps an authenticated open fallback", async () => {
    apiMock.mockResolvedValue({});
    const image = {
      ...original,
      title: "Referral photo",
      original_filename: "referral.jpg",
      media_type: "image/jpeg",
    };
    render(<DocumentViewer document={image} onOpenChange={vi.fn()} />);
    const viewer = screen.getByRole("dialog", { name: "Referral photo" });
    const preview = await within(viewer).findByRole("img", { name: "Referral photo" });

    fireEvent.error(preview);

    expect(await within(viewer).findByRole("alert")).toHaveTextContent("could not be previewed");
    await waitFor(() => expect(within(viewer).queryByRole("img", { name: "Referral photo" })).not.toBeInTheDocument());
    expect(within(viewer).getByRole("link", { name: "Open separately" })).toHaveAttribute(
      "href",
      original.download_url,
    );
  });
});
