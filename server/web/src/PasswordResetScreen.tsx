import { CheckCircle2, Eye, EyeOff, KeyRound, LoaderCircle } from "lucide-react";
import { useState, type FormEvent } from "react";

import { resetPassword } from "./api";

export function PasswordResetScreen({ token, onFinished }: { token: string; onFinished: () => void }) {
  const [newPassword, setNewPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [complete, setComplete] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    if (newPassword.length < 12) {
      setError("Use at least 12 characters for the new password.");
      window.setTimeout(() => document.getElementById("reset-new-password")?.focus(), 0);
      return;
    }
    if (newPassword !== confirmation) {
      setError("The new passwords do not match.");
      window.setTimeout(() => document.getElementById("reset-confirm-password")?.focus(), 0);
      return;
    }

    setSubmitting(true);
    try {
      await resetPassword(token, newPassword);
      setNewPassword("");
      setConfirmation("");
      setComplete(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "This password reset link could not be used.");
      window.setTimeout(() => document.getElementById("reset-new-password")?.focus(), 0);
    } finally {
      setSubmitting(false);
    }
  }

  const inputType = showPassword ? "text" : "password";

  return (
    <main className="login-page">
      <section className="login-panel reset-password-panel" aria-labelledby="reset-password-title">
        <div className="login-brand">
          <img src="/icons/hausklar-192.png" width="88" height="88" alt="HausKlar" />
          <div><h1 id="reset-password-title">Reset password</h1><p>Choose a new password for HausKlar.</p></div>
        </div>

        {complete ? (
          <div className="reset-password-complete" role="status">
            <CheckCircle2 aria-hidden="true" size={34} />
            <strong>Password changed</strong>
            <p>Sign in with your new password.</p>
            <button type="button" className="button button--primary button--large" onClick={onFinished}>Return to sign in</button>
          </div>
        ) : (
          <form className="form-stack" onSubmit={submit} aria-busy={submitting}>
            {error ? <div className="form-error" role="alert" id="reset-password-error">{error}</div> : null}
            <div className="field">
              <label htmlFor="reset-new-password">New password</label>
              <div className="password-field">
                <input id="reset-new-password" type={inputType} autoComplete="new-password" minLength={12} maxLength={128} value={newPassword} onChange={(event) => { setNewPassword(event.target.value); setError(null); }} aria-invalid={error ? "true" : undefined} aria-describedby={error ? "reset-password-error" : undefined} required autoFocus />
                <button type="button" className="password-toggle" aria-label={showPassword ? "Hide passwords" : "Show passwords"} onClick={() => setShowPassword((shown) => !shown)}>{showPassword ? <EyeOff aria-hidden="true" size={18} /> : <Eye aria-hidden="true" size={18} />}</button>
              </div>
            </div>
            <div className="field">
              <label htmlFor="reset-confirm-password">Confirm new password</label>
              <input id="reset-confirm-password" type={inputType} autoComplete="new-password" minLength={12} maxLength={128} value={confirmation} onChange={(event) => { setConfirmation(event.target.value); setError(null); }} aria-invalid={error ? "true" : undefined} aria-describedby={error ? "reset-password-error" : undefined} required />
            </div>
            <button type="submit" className="button button--primary button--large" disabled={submitting || !newPassword || !confirmation}>
              {submitting ? <LoaderCircle className="spin" aria-hidden="true" size={18} /> : <KeyRound aria-hidden="true" size={18} />}
              {submitting ? "Resetting…" : "Reset password"}
            </button>
            <button type="button" className="button button--secondary" onClick={onFinished}>Back to sign in</button>
          </form>
        )}
      </section>
    </main>
  );
}
