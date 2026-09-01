import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { ActionRail } from "../components/ActionRail";
import { AddHub } from "../components/AddHub";
import { ShoppingItemDialog } from "../components/ShoppingItemDialog";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

describe("shared capture doorway", () => {
  beforeEach(() => apiMock.mockReset());

  it("opens reviewed text capture directly and keeps one Add shortcut on mobile", () => {
    const onCapture = vi.fn();
    const onAdd = vi.fn();
    const onSearch = vi.fn();
    render(<ActionRail placement="mobile" onCapture={onCapture} onAdd={onAdd} onSearch={onSearch} />);

    const capture = screen.getByRole("button", { name: "Tell HausKlar…" });
    const add = screen.getByRole("button", { name: "Add directly" });
    expect(screen.queryByRole("button", { name: "Find anything" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Bismarck" })).not.toBeInTheDocument();

    fireEvent.click(capture);
    fireEvent.click(add);
    expect(onCapture).toHaveBeenCalledWith(capture);
    expect(onAdd).toHaveBeenCalledWith(add);
    expect(onSearch).not.toHaveBeenCalled();
  });

  it("keeps Find in the desktop sidebar where the header search is absent", () => {
    const onSearch = vi.fn();
    render(<ActionRail placement="sidebar" onCapture={vi.fn()} onAdd={vi.fn()} onSearch={onSearch} />);
    const find = screen.getByRole("button", { name: "Find anything" });
    fireEvent.click(find);
    expect(onSearch).toHaveBeenCalledWith(find);
  });

  it("uses direct Log and Coach actions inside Fitness with no Bismarck doorway", () => {
    const onFitnessLog = vi.fn();
    const onFitnessCoach = vi.fn();
    render(<ActionRail placement="mobile" onCapture={vi.fn()} onAdd={vi.fn()} onSearch={vi.fn()} context="fitness" onFitnessLog={onFitnessLog} onFitnessCoach={onFitnessCoach} />);

    const launcher = screen.getByRole("button", { name: "Log or ask Coach" });
    fireEvent.click(launcher);
    expect(screen.queryByRole("button", { name: "Bismarck" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Log" }));
    expect(onFitnessLog).toHaveBeenCalledWith(launcher);

    fireEvent.click(launcher);
    fireEvent.click(screen.getByRole("button", { name: "Coach" }));
    expect(onFitnessCoach).toHaveBeenCalledWith(launcher);
  });

  it("offers every agreed direct and specialist workflow", () => {
    const onChoose = vi.fn();
    render(<AddHub open onOpenChange={vi.fn()} onChoose={onChoose} />);

    expect(screen.getAllByRole("button").filter((button) => button.classList.contains("add-hub-choice")).map((button) => button.textContent)).toEqual([
      "EventAdd a date or appointment",
      "TaskAdd something that needs doing",
      "Shopping itemAdd to the shared shopping list",
      "Record medicineLog a dose time and compare your saved limits",
      "Sleep & napsOpen the children's sleep controls",
      "Letter or fileScan or file family paperwork",
      "Plan from messageTurn a message or booking into one reviewed family plan",
      "Several events or tasksPaste a message and review every draft",
    ]);
    fireEvent.click(screen.getByRole("button", { name: /Shopping item/ }));
    expect(onChoose).toHaveBeenCalledWith("shopping");

    fireEvent.click(screen.getByRole("button", { name: /Plan from message/ }));
    expect(onChoose).toHaveBeenCalledWith("commitment");
  });

  it("adds a shopping item directly and reports its destination", async () => {
    apiMock.mockResolvedValue({});
    const onCreated = vi.fn();
    const notify = vi.fn();
    render(<ShoppingItemDialog open onOpenChange={vi.fn()} onCreated={onCreated} notify={notify} />);

    fireEvent.change(screen.getByLabelText("Item"), { target: { value: "Milk" } });
    fireEvent.change(screen.getByLabelText("Quantity (optional)"), { target: { value: "2 bottles" } });
    fireEvent.click(screen.getByRole("button", { name: "Add item" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/meals/shopping",
      expect.objectContaining({ method: "POST" }),
    ));
    const request = apiMock.mock.calls.find(([path]) => path === "/meals/shopping")?.[1];
    expect(JSON.parse(String(request?.body))).toMatchObject({
      id: expect.any(String),
      name: "Milk",
      quantity: "2 bottles",
      client_id: expect.any(String),
      client_timestamp: expect.any(String),
    });
    expect(onCreated).toHaveBeenCalledOnce();
    expect(notify).toHaveBeenCalledWith("Milk added to the shopping list.");
  });
});
