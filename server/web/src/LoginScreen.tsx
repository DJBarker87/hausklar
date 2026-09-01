import { ArrowLeft, CheckCircle2, Eye, EyeOff, LoaderCircle, Mail, UsersRound } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";

import { useAuth } from "./AuthContext";
import { api, requestPasswordReset } from "./api";

type LoginMode = "sign-in" | "create-family" | "join-family" | "forgot-password" | "reset-sent";

export function LoginScreen() {
  const { error, signIn, registerFamily, joinFamily } = useAuth();
  const initialInvite = new URLSearchParams(window.location.hash.replace(/^#/, "")).get("join") ?? "";
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [familyName, setFamilyName] = useState("");
  const [inviteCode, setInviteCode] = useState(initialInvite.toUpperCase());
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [mode, setMode] = useState<LoginMode>(initialInvite ? "join-family" : "sign-in");
  const [resetError, setResetError] = useState<string | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const [requestingReset, setRequestingReset] = useState(false);
  const [publicRegistration, setPublicRegistration] = useState(false);

  useEffect(() => {
    if (mode !== "create-family") return;
    let active = true;
    void api<{ public_registration: boolean }>("/auth/capabilities")
      .then((result) => { if (active) setPublicRegistration(result.public_registration); })
      .catch(() => { if (active) setPublicRegistration(false); });
    return () => { active = false; };
  }, [mode]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    if (mode !== "sign-in" && password.length < 12) {
      setLocalError("Use at least 12 characters for your password.");
      return;
    }
    setSubmitting(true);
    try {
      if (mode === "create-family") await registerFamily(familyName, name, email, password);
      else if (mode === "join-family") await joinFamily(inviteCode, name, email, password);
      else await signIn(email, password);
      if (initialInvite) window.history.replaceState({}, "", `${window.location.pathname}${window.location.search}`);
    } catch {
      document.getElementById(mode === "join-family" ? "join-code" : "login-email")?.focus();
    } finally {
      setSubmitting(false);
    }
  }

  async function submitPasswordReset(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setRequestingReset(true);
    setResetError(null);
    try {
      await requestPasswordReset(email);
      setMode("reset-sent");
    } catch (requestError) {
      setResetError(requestError instanceof Error ? requestError.message : "The reset request could not be sent.");
      window.setTimeout(() => document.getElementById("reset-email")?.focus(), 0);
    } finally {
      setRequestingReset(false);
    }
  }

  function showSignIn() {
    setMode("sign-in");
    setResetError(null);
    setLocalError(null);
  }

  const signingUp = mode === "create-family" || mode === "join-family";
  const title = mode === "sign-in" ? "HausKlar" : mode === "forgot-password" ? "Reset password" : mode === "reset-sent" ? "Check your inbox" : mode === "create-family" ? "Create your household" : "Join your household";
  const subtitle = mode === "sign-in"
    ? "Know what’s happening today."
    : mode === "create-family"
      ? "A calm shared plan starts with the people who use it."
      : mode === "join-family"
        ? "Your invitation connects you to the same private family plan."
        : mode === "forgot-password"
          ? "Request a secure password reset link."
          : "Password reset requested.";

  return (
    <main className="login-page">
      <section className="login-panel" aria-labelledby="login-title">
        <div className="login-brand">
          <img src="/icons/hausklar-192.png" width="88" height="88" alt="HausKlar" />
          <div><h1 id="login-title">{title}</h1><p>{subtitle}</p></div>
        </div>

        {mode === "sign-in" || signingUp ? (
          <form className="form-stack" onSubmit={submit} aria-busy={submitting}>
            {error || localError ? <div className="form-error" role="alert" id="login-error">{localError ?? error}</div> : null}
            {signingUp ? <>
              {mode === "join-family" ? <div className="field"><label htmlFor="join-code">Invite code</label><input id="join-code" value={inviteCode} onChange={(event) => setInviteCode(event.target.value.toUpperCase())} autoComplete="one-time-code" maxLength={32} required autoFocus /></div> : null}
              {mode === "create-family" ? <div className="field"><label htmlFor="family-name">Household name</label><input id="family-name" value={familyName} onChange={(event) => setFamilyName(event.target.value)} autoComplete="organization" required autoFocus /></div> : null}
              <div className="field"><label htmlFor="your-name">Your name</label><input id="your-name" value={name} onChange={(event) => setName(event.target.value)} autoComplete="name" required /></div>
            </> : null}
            <div className="field"><label htmlFor="login-email">Email</label><input id="login-email" type="email" autoComplete="email" spellCheck={false} value={email} onChange={(event) => setEmail(event.target.value)} aria-invalid={error || localError ? "true" : undefined} aria-describedby={error || localError ? "login-error" : undefined} required autoFocus={!signingUp} /></div>
            <div className="field">
              <label htmlFor="login-password">Password</label>
              <div className="password-field"><input id="login-password" type={showPassword ? "text" : "password"} autoComplete={signingUp ? "new-password" : "current-password"} minLength={signingUp ? 12 : undefined} value={password} onChange={(event) => setPassword(event.target.value)} required /><button type="button" className="password-toggle" aria-label={showPassword ? "Hide password" : "Show password"} onClick={() => setShowPassword((shown) => !shown)}>{showPassword ? <EyeOff aria-hidden="true" size={18} /> : <Eye aria-hidden="true" size={18} />}</button></div>
              {!signingUp ? <button type="button" className="login-link-button" onClick={() => { setResetError(null); setMode("forgot-password"); }}>Forgot password?</button> : <small>Use 12 or more characters.</small>}
            </div>
            <button type="submit" className="button button--primary button--large" disabled={submitting || (mode === "create-family" && !publicRegistration)}>{submitting ? <LoaderCircle className="spin" aria-hidden="true" size={18} /> : signingUp ? <UsersRound aria-hidden="true" size={18} /> : null}{submitting ? "Working…" : mode === "create-family" ? publicRegistration ? "Create household" : "Household creation is closed" : mode === "join-family" ? "Join household" : "Sign in"}</button>
            {signingUp ? <button type="button" className="button button--secondary" onClick={showSignIn}><ArrowLeft aria-hidden="true" size={17} /> Back to sign in</button> : null}
          </form>
        ) : null}

        {mode === "sign-in" ? <div className="login-family-actions"><span>New to HausKlar?</span><button type="button" className="login-link-button" onClick={() => setMode("join-family")}>Join with an invite</button><span aria-hidden="true">·</span><button type="button" className="login-link-button" onClick={() => setMode("create-family")}>Create a household</button></div> : null}

        {mode === "forgot-password" ? <form className="form-stack" onSubmit={submitPasswordReset} aria-busy={requestingReset}>{resetError ? <div className="form-error" role="alert" id="reset-request-error">{resetError}</div> : null}<div className="field"><label htmlFor="reset-email">Email</label><input id="reset-email" type="email" autoComplete="email" spellCheck={false} value={email} onChange={(event) => setEmail(event.target.value)} aria-invalid={resetError ? "true" : undefined} aria-describedby={resetError ? "reset-request-error" : undefined} required autoFocus /></div><button type="submit" className="button button--primary button--large" disabled={requestingReset}>{requestingReset ? <LoaderCircle className="spin" aria-hidden="true" size={18} /> : <Mail aria-hidden="true" size={18} />}{requestingReset ? "Sending…" : "Send reset link"}</button><button type="button" className="button button--secondary" disabled={requestingReset} onClick={showSignIn}><ArrowLeft aria-hidden="true" size={17} /> Back to sign in</button></form> : null}

        {mode === "reset-sent" ? <div className="reset-password-complete" role="status"><CheckCircle2 aria-hidden="true" size={34} /><strong>Check your inbox</strong><p>If {email} is registered, a password reset link is on its way.</p><button type="button" className="button button--primary button--large" onClick={showSignIn}>Return to sign in</button></div> : null}

        <a className="login-help" href="/privacy-policy">Privacy</a>
      </section>
    </main>
  );
}
