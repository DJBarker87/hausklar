import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import {
  DocumentAttachmentField,
  uploadPendingDocument,
  type PendingDocumentAttachment,
} from "../components/DocumentAttachmentField";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

function setOnline(online: boolean) {
  Object.defineProperty(window.navigator, "onLine", { configurable: true, value: online });
}

function field(overrides: Partial<{
  pending: PendingDocumentAttachment | null;
  onPending: (pending: PendingDocumentAttachment | null) => void;
  onSelect: (id: string | null) => void;
}> = {}) {
  return <DocumentAttachmentField
    active
    idPrefix="test"
    selectedDocumentID={null}
    pending={overrides.pending ?? null}
    onSelect={overrides.onSelect ?? vi.fn()}
    onPending={overrides.onPending ?? vi.fn()}
  />;
}

describe("DocumentAttachmentField", () => {
  beforeEach(() => {
    setOnline(true);
    apiMock.mockReset();
    apiMock.mockResolvedValue([{
      id: "saved-document",
      title: "Saved letter",
      original_filename: "letter.pdf",
    }]);
  });
  afterEach(() => setOnline(true));

  it("loads saved documents and keeps capture available offline", async () => {
    const onSelect = vi.fn();
    setOnline(false);
    render(field({ onSelect }));

    expect(screen.getByRole("button", { name: "Scan document" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Upload photo or file" })).toBeEnabled();
    expect(await screen.findByRole("option", { name: "Saved letter · letter.pdf" })).toBeInTheDocument();

    setOnline(true);
    fireEvent(window, new Event("online"));
    expect(screen.getByRole("button", { name: "Scan document" })).toBeEnabled();
    fireEvent.change(screen.getByLabelText("Choose an existing document"), { target: { value: "saved-document" } });
    expect(onSelect).toHaveBeenCalledWith("saved-document");

    setOnline(false);
    fireEvent(window, new Event("offline"));
    expect(screen.getByRole("button", { name: "Upload photo or file" })).toBeEnabled();
    expect(screen.getByLabelText("Choose an existing document")).toBeEnabled();
    expect(screen.getByRole("option", { name: "Saved letter · letter.pdf" })).toBeInTheDocument();
  });

  it("keeps a selected file ready to save across an offline round trip", async () => {
    const onBlocked = vi.fn();
    const selectedIDs: string[] = [];
    function Harness() {
      const [pending, setPending] = useState<PendingDocumentAttachment | null>(null);
      return <DocumentAttachmentField
        active
        idPrefix="round-trip"
        selectedDocumentID={null}
        pending={pending}
        onSelect={vi.fn()}
        onPending={(nextPending) => {
          if (nextPending) selectedIDs.push(nextPending.documentID);
          setPending(nextPending);
        }}
        onUploadBlockedChange={onBlocked}
      />;
    }
    render(<Harness />);
    fireEvent.change(screen.getByLabelText("Upload photo or document"), {
      target: { files: [new File(["document"], "private.pdf", { type: "application/pdf" })] },
    });
    expect(screen.getByText("private.pdf")).toBeInTheDocument();

    setOnline(false);
    fireEvent(window, new Event("offline"));

    await waitFor(() => expect(onBlocked).toHaveBeenLastCalledWith(false));
    expect(screen.getByText("private.pdf")).toBeInTheDocument();
    expect(screen.getByText(/uploads when you save/)).toBeInTheDocument();

    setOnline(true);
    fireEvent(window, new Event("online"));
    await waitFor(() => expect(onBlocked).toHaveBeenLastCalledWith(false));
    expect(screen.getByText("private.pdf")).toBeInTheDocument();
    expect(screen.getByText(/uploads when you save/)).toBeInTheDocument();
    expect(selectedIDs).toHaveLength(1);
    expect(selectedIDs[0]).toMatch(/^[0-9a-f-]{36}$/i);
  });

  it("reuses one upload ID for retries and gives a replacement file a fresh ID", async () => {
    const onPending = vi.fn();
    render(field({ onPending }));
    const input = screen.getByLabelText("Upload photo or document");

    fireEvent.change(input, {
      target: { files: [new File(["first"], "first.pdf", { type: "application/pdf" })] },
    });
    const firstPending = onPending.mock.calls.at(-1)?.[0] as PendingDocumentAttachment;
    expect(firstPending.documentID).toMatch(/^[0-9a-f-]{36}$/i);

    await uploadPendingDocument(firstPending);
    await uploadPendingDocument(firstPending);
    const uploadForms = apiMock.mock.calls
      .filter(([path, init]) => path === "/documents/" && init?.method === "POST")
      .map(([, init]) => init?.body as FormData);
    expect(uploadForms).toHaveLength(2);
    expect(uploadForms[0].get("document_id")).toBe(firstPending.documentID);
    expect(uploadForms[1].get("document_id")).toBe(firstPending.documentID);

    fireEvent.change(input, {
      target: { files: [new File(["second"], "second.pdf", { type: "application/pdf" })] },
    });
    const secondPending = onPending.mock.calls.at(-1)?.[0] as PendingDocumentAttachment;
    expect(secondPending.documentID).toMatch(/^[0-9a-f-]{36}$/i);
    expect(secondPending.documentID).not.toBe(firstPending.documentID);
  });

  it("rejects formats the document API cannot store", async () => {
    const onPending = vi.fn();
    render(field({ onPending }));
    const input = screen.getByLabelText("Upload photo or document");
    expect(input).toHaveAttribute("accept", "image/jpeg,image/png,image/tiff,image/heic,image/heif,application/pdf,text/plain");

    fireEvent.change(input, { target: { files: [new File(["webp"], "photo.webp", { type: "image/webp" })] } });

    expect(await screen.findByRole("alert")).toHaveTextContent("Use a JPEG, PNG, TIFF, HEIC, PDF or plain-text file.");
    expect(onPending).not.toHaveBeenCalled();
  });
});
