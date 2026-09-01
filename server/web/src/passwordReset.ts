const RESET_FRAGMENT_PREFIX = "#reset-password=";

export function consumePasswordResetToken(): string | null {
  const fragment = window.location.hash;
  if (!fragment.startsWith(RESET_FRAGMENT_PREFIX)) return null;

  const encodedToken = fragment.slice(RESET_FRAGMENT_PREFIX.length);
  window.history.replaceState(window.history.state, "", `${window.location.pathname}${window.location.search}`);
  if (!encodedToken) return null;

  try {
    return decodeURIComponent(encodedToken).trim() || null;
  } catch {
    return null;
  }
}
