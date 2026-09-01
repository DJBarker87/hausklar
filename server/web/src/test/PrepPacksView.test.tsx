import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { PrepPacksView } from "../views/PrepPacksView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const swimming = {
  id: "swimming",
  name: "Swimming",
  match_terms: ["swimming", "swim lesson"],
  items: ["Pack swim kit", "Pack towels"],
  lead_hours: 24,
  assigned_to: null,
  enabled: true,
};

describe("Preparation pack editor", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/prep-packs/templates" && !options) return [swimming] as never;
      if (path === "/prep-packs/templates/swimming" && options?.method === "PATCH") {
        return { ...swimming, items: ["Pack swim kit", "Pack towels", "Fill water bottle"] } as never;
      }
      return null as never;
    });
  });

  it("lets a non-technical user update the usual checklist", async () => {
    render(<PrepPacksView members={[]} revision={0} onDataChanged={vi.fn()} notify={vi.fn()} />);
    expect(await screen.findByRole("heading", { name: "Swimming" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
    const checklist = screen.getByLabelText("Checklist");
    fireEvent.change(checklist, { target: { value: "Pack swim kit\nPack towels\nFill water bottle" } });
    fireEvent.click(screen.getByRole("button", { name: "Save pack" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/prep-packs/templates/swimming",
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining("Fill water bottle") }),
    ));
    expect(await screen.findByText("Fill water bottle")).toBeInTheDocument();
  });
});
