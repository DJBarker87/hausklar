import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { LoginScreen } from "../LoginScreen";

const { signIn, registerFamily, joinFamily, requestPasswordReset, apiMock } = vi.hoisted(() => ({
  signIn: vi.fn(),
  registerFamily: vi.fn(),
  joinFamily: vi.fn(),
  requestPasswordReset: vi.fn(),
  apiMock: vi.fn(),
}));

vi.mock("../AuthContext", () => ({
  useAuth: () => ({
    user: null,
    loading: false,
    error: null,
    signIn,
    registerFamily,
    joinFamily,
    signOut: vi.fn(),
  }),
}));

vi.mock("../api", () => ({ requestPasswordReset, api: apiMock }));

describe("LoginScreen", () => {
  beforeEach(() => {
    signIn.mockReset();
    registerFamily.mockReset();
    joinFamily.mockReset();
    requestPasswordReset.mockReset();
    apiMock.mockReset();
    apiMock.mockResolvedValue({ public_registration: true });
    window.history.replaceState({}, "", "/");
  });

  it("opens a household invitation deep link with its code ready", async () => {
    window.history.replaceState({}, "", "/#join=ABCD1234");
    joinFamily.mockResolvedValue(undefined);
    render(<LoginScreen />);

    expect(screen.getByRole("heading", { name: "Join your household" })).toBeInTheDocument();
    expect(screen.getByLabelText("Invite code")).toHaveValue("ABCD1234");
    fireEvent.change(screen.getByLabelText("Your name"), { target: { value: "Morgan" } });
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "kat@example.invalid" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "a-private-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Join household" }));

    await waitFor(() => expect(joinFamily).toHaveBeenCalledWith("ABCD1234", "Morgan", "kat@example.invalid", "a-private-password"));
  });

  it("submits the family account through the web sign-in flow", async () => {
    signIn.mockResolvedValue(undefined);
    render(<LoginScreen />);

    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "dom@example.invalid" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "secret" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => expect(signIn).toHaveBeenCalledWith("dom@example.invalid", "secret"));
  });

  it("keeps password reveal behind an explicitly labelled control", () => {
    render(<LoginScreen />);
    const password = screen.getByLabelText("Password");

    expect(password).toHaveAttribute("type", "password");
    fireEvent.click(screen.getByRole("button", { name: "Show password" }));
    expect(password).toHaveAttribute("type", "text");
    expect(screen.getByRole("button", { name: "Hide password" })).toBeInTheDocument();
  });

  it("requests a password reset without losing the entered email", async () => {
    requestPasswordReset.mockResolvedValue(undefined);
    render(<LoginScreen />);

    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "kat@example.invalid" } });
    fireEvent.click(screen.getByRole("button", { name: "Forgot password?" }));

    expect(screen.getByRole("heading", { name: "Reset password" })).toBeInTheDocument();
    expect(screen.getByLabelText("Email")).toHaveValue("kat@example.invalid");
    fireEvent.click(screen.getByRole("button", { name: "Send reset link" }));

    await waitFor(() => expect(requestPasswordReset).toHaveBeenCalledWith("kat@example.invalid"));
    expect(screen.getByRole("heading", { name: "Check your inbox" })).toBeInTheDocument();
    expect(screen.getByText(/If kat@example.invalid is registered/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Return to sign in" }));
    expect(screen.getByRole("button", { name: "Sign in" })).toBeInTheDocument();
    expect(screen.getByLabelText("Email")).toHaveValue("kat@example.invalid");
  });

  it("keeps the reset form editable and focuses it after a request error", async () => {
    requestPasswordReset.mockRejectedValue(new Error("Reset email is temporarily unavailable."));
    render(<LoginScreen />);

    fireEvent.click(screen.getByRole("button", { name: "Forgot password?" }));
    const email = screen.getByLabelText("Email");
    fireEvent.change(email, { target: { value: "dom@example.invalid" } });
    fireEvent.click(screen.getByRole("button", { name: "Send reset link" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Reset email is temporarily unavailable.");
    await waitFor(() => expect(email).toHaveFocus());
    expect(email).toHaveAttribute("aria-describedby", "reset-request-error");
    expect(screen.getByRole("button", { name: "Send reset link" })).toBeEnabled();
  });
});
