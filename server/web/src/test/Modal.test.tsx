import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it } from "vitest";

import { Modal } from "../components/ui";

function ControlledModal() {
  const [open, setOpen] = useState(false);
  return <>
    <button type="button" onClick={() => setOpen(true)}>Open details</button>
    <Modal open={open} onOpenChange={setOpen} title="Activity details">
      <button type="button">Inside action</button>
    </Modal>
  </>;
}

describe("Modal", () => {
  it("returns focus to the element that opened a controlled dialog", async () => {
    render(<ControlledModal />);
    const trigger = screen.getByRole("button", { name: "Open details" });
    trigger.focus();
    fireEvent.click(trigger);

    const dialog = await screen.findByRole("dialog", { name: "Activity details" });
    await waitFor(() => expect(dialog).toContainElement(document.activeElement as HTMLElement | null));

    fireEvent.keyDown(dialog, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Activity details" })).not.toBeInTheDocument());
    expect(trigger).toHaveFocus();
  });
});
