import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { constrainCropOffset, PersonAvatarEditor } from "../components/PersonAvatar";
import type { FamilyMember } from "../types";

vi.mock("../api", () => ({ api: vi.fn(), isOfflineQueuedResult: vi.fn(() => false) }));

const apiMock = vi.mocked(api);
const member: FamilyMember = { id: "child-1", name: "Child One", member_type: "child" };

class LoadedImage {
  decoding = "";
  naturalWidth = 1200;
  naturalHeight = 800;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;

  set src(_value: string) {
    queueMicrotask(() => this.onload?.());
  }
}

describe("PersonAvatarEditor", () => {
  beforeEach(() => {
    apiMock.mockReset();
    vi.stubGlobal("Image", LoadedImage);
    Object.defineProperty(URL, "createObjectURL", { configurable: true, value: vi.fn(() => "blob:portrait") });
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: vi.fn() });
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({ drawImage: vi.fn() } as unknown as CanvasRenderingContext2D);
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation((callback) => callback(new Blob(["avatar"], { type: "image/jpeg" })));
  });

  it("previews the circular crop and only uploads after explicit save", async () => {
    const saved = { ...member, avatar_url: "/family/members/child-1/avatar?v=abc" };
    apiMock.mockResolvedValue(saved);
    const onSaved = vi.fn();
    const onOpenChange = vi.fn();
    render(<PersonAvatarEditor member={member} open onOpenChange={onOpenChange} onSaved={onSaved} />);

    expect(screen.getByRole("button", { name: "Save photo" })).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Choose a photo"), {
      target: { files: [new File(["photo"], "portrait.png", { type: "image/png" })] },
    });

    expect(await screen.findByRole("button", { name: "Reposition Child One's photo" })).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText("Zoom"), { target: { value: "1.5" } });
    fireEvent.keyDown(screen.getByRole("button", { name: "Reposition Child One's photo" }), { key: "ArrowLeft" });
    fireEvent.click(screen.getByRole("button", { name: "Save photo" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledOnce());
    expect(apiMock).toHaveBeenCalledWith("/family/members/child-1/avatar", expect.objectContaining({
      method: "PUT",
      body: expect.any(FormData),
    }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledWith(saved));
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("keeps the crop inside the source image", () => {
    expect(constrainCropOffset({ x: 500, y: -500 }, 1, { width: 1200, height: 800 }, 300)).toEqual({ x: 75, y: 0 });
    expect(constrainCropOffset({ x: 500, y: -500 }, 2, { width: 1200, height: 800 }, 300)).toEqual({ x: 300, y: -150 });
  });

  it("rejects unsupported files before creating a preview", async () => {
    render(<PersonAvatarEditor member={member} open onOpenChange={vi.fn()} onSaved={vi.fn()} />);
    fireEvent.change(screen.getByLabelText("Choose a photo"), {
      target: { files: [new File(["svg"], "portrait.svg", { type: "image/svg+xml" })] },
    });
    expect(await screen.findByRole("alert")).toHaveTextContent("JPEG, PNG, or WebP");
    expect(apiMock).not.toHaveBeenCalled();
  });
});
