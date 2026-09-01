import { lazy, StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";

import App from "./App";
import { AuthProvider } from "./AuthContext";
import { PasswordResetScreen } from "./PasswordResetScreen";
import { consumePasswordResetToken } from "./passwordReset";
import "./styles.css";

const passwordResetToken = consumePasswordResetToken();
const caregiverMode = new URLSearchParams(window.location.search).get("caregiver") === "1";
const CaregiverSessionView = lazy(() => import("./views/CaregiverView").then((module) => ({
  default: module.CaregiverSessionView,
})));

// An open installed PWA can briefly reference a lazy chunk from the previous
// deploy. Vite emits this event before React's route boundary sees the failed
// import. Reload once so the tab picks up the matching shell and chunk set.
window.addEventListener("vite:preloadError", (event) => {
  event.preventDefault();
  const reloadKey = "hausklar:preload-reload";
  const lastReload = Number(window.sessionStorage.getItem(reloadKey) ?? 0);
  if (Date.now() - lastReload < 60_000) return;
  window.sessionStorage.setItem(reloadKey, String(Date.now()));
  window.location.reload();
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {passwordResetToken ? (
      <PasswordResetScreen token={passwordResetToken} onFinished={() => window.location.assign("/")} />
    ) : caregiverMode ? (
      <Suspense fallback={<main className="app-loading" aria-label="Opening caregiver handover"><img src="/icons/hausklar-192.png" width="72" height="72" alt="" /><div className="loading-bar" /></main>}>
        <CaregiverSessionView />
      </Suspense>
    ) : (
      <AuthProvider>
        <App />
      </AuthProvider>
    )}
  </StrictMode>,
);

if ("serviceWorker" in navigator && import.meta.env.PROD) {
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js").catch(() => {
      // The app remains fully usable online when worker registration is blocked.
    });
  });
}
