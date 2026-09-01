import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { resetPassword } from "../api";
import { PasswordResetScreen } from "../PasswordResetScreen";
import { consumePasswordResetToken } from "../passwordReset";

vi.mock("../api", () => ({ resetPassword: vi.fn() }));

const resetPasswordMock = vi.mocked(resetPassword);

describe("password reset link", () => {
  beforeEach(() => {
    resetPasswordMock.mockReset();
    window.history.replaceState({}, "", "/");
  });

  it("consumes and scrubs the reset token fragment immediately", () => {
    window.history.replaceState({}, "", "/#reset-password=header.payload.signature");

    expect(consumePasswordResetToken()).toBe("header.payload.signature");
    expect(window.location.pathname).toBe("/");
    expect(window.location.search).toBe("");
    expect(window.location.hash).toBe("");
  });

  it("submits the in-memory token and returns to sign in after success", async () => {
    resetPasswordMock.mockResolvedValue(undefined);
    const finished = vi.fn();
    render(<PasswordResetScreen token="header.payload.signature" onFinished={finished} />);

    fireEvent.change(screen.getByLabelText("New password"), { target: { value: "a-new-private-password" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "a-new-private-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Reset password" }));

    await waitFor(() => expect(resetPasswordMock).toHaveBeenCalledWith(
      "header.payload.signature",
      "a-new-private-password",
    ));
    expect(screen.getByRole("status")).toHaveTextContent("Password changed");
    fireEvent.click(screen.getByRole("button", { name: "Return to sign in" }));
    expect(finished).toHaveBeenCalled();
  });

  it("validates the replacement password and focuses the field that needs attention", async () => {
    render(<PasswordResetScreen token="secret" onFinished={vi.fn()} />);
    const newPassword = screen.getByLabelText("New password");
    fireEvent.change(newPassword, { target: { value: "short" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "short" } });
    fireEvent.click(screen.getByRole("button", { name: "Reset password" }));

    expect(screen.getByRole("alert")).toHaveTextContent("at least 12 characters");
    expect(newPassword).toHaveAttribute("aria-describedby", "reset-password-error");
    await waitFor(() => expect(newPassword).toHaveFocus());
    expect(resetPasswordMock).not.toHaveBeenCalled();
  });
});
