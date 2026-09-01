import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";

import {
  ApiError,
  type AuthExpiredDetail,
  getAuthSessionEpoch,
  installAuthIdentity,
  joinFamily as joinFamilyRequest,
  login as loginRequest,
  logout as logoutRequest,
  registerFamily as registerFamilyRequest,
  resetAuthIdentity,
  session,
} from "./api";
import { purgeFitnessOwnerData } from "./fitness/offlineStore";
import {
  cacheOfflineSession,
  cachedOfflineSession,
  clearOfflineSession,
  currentOfflineQueueOwner,
  purgeOfflineOwnerData,
  setOfflineQueueOwner,
} from "./offlineQueue";
import { revokeCurrentBrowserPushSubscription } from "./pushSubscriptions";
import type { User } from "./types";

type AuthState = {
  user: User | null;
  loading: boolean;
  error: string | null;
  signIn: (email: string, password: string) => Promise<void>;
  registerFamily: (familyName: string, userName: string, email: string, password: string) => Promise<void>;
  joinFamily: (inviteCode: string, userName: string, email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  updateUser: (user: User) => void;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    const restoreSession = async () => {
      if (!navigator.onLine) {
        const cachedUser = await cachedOfflineSession<User>().catch(() => null);
        if (!active) return;
        if (cachedUser) {
          installAuthIdentity(cachedUser);
          setOfflineQueueOwner(cachedUser);
          setUser(cachedUser);
        } else {
          setError("No saved sign-in is available on this device yet.");
        }
        setLoading(false);
        return;
      }
      try {
        const currentUser = await session();
        if (active) {
          installAuthIdentity(currentUser);
          setOfflineQueueOwner(currentUser);
          setUser(currentUser);
          void cacheOfflineSession(currentUser);
        }
      } catch (requestError: unknown) {
        if (!active) return;
        if (requestError instanceof ApiError && requestError.status === 401) {
          await clearOfflineSession().catch(() => undefined);
          return;
        }
        const cachedUser = await cachedOfflineSession<User>().catch(() => null);
        if (active && cachedUser) {
          installAuthIdentity(cachedUser);
          setOfflineQueueOwner(cachedUser);
          setUser(cachedUser);
          return;
        }
        if (active) setError("Couldn't restore your session. You can still sign in below.");
      } finally {
        if (active) setLoading(false);
      }
    };
    void restoreSession();
    const expire = (event: Event) => {
      const epoch = (event as CustomEvent<AuthExpiredDetail>).detail?.epoch;
      if (typeof epoch !== "number" || !resetAuthIdentity(epoch)) return;
      setOfflineQueueOwner(null);
      setUser(null);
    };
    window.addEventListener("hausklar:auth-expired", expire);
    return () => {
      active = false;
      window.removeEventListener("hausklar:auth-expired", expire);
    };
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    setError(null);
    try {
      const signedInUser = await loginRequest(email, password);
      installAuthIdentity(signedInUser);
      setOfflineQueueOwner(signedInUser);
      setUser(signedInUser);
      await cacheOfflineSession(signedInUser);
    } catch (requestError) {
      const message = requestError instanceof Error ? requestError.message : "Sign-in failed.";
      setError(message);
      throw requestError;
    }
  }, []);

  const adoptNewSession = useCallback(async (signedInUser: User) => {
    installAuthIdentity(signedInUser);
    setOfflineQueueOwner(signedInUser);
    setUser(signedInUser);
    await cacheOfflineSession(signedInUser);
  }, []);

  const registerFamily = useCallback(async (
    familyName: string, userName: string, email: string, password: string,
  ) => {
    setError(null);
    try {
      await adoptNewSession(await registerFamilyRequest(familyName, userName, email, password));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Household creation failed.");
      throw requestError;
    }
  }, [adoptNewSession]);

  const joinFamily = useCallback(async (
    inviteCode: string, userName: string, email: string, password: string,
  ) => {
    setError(null);
    try {
      await adoptNewSession(await joinFamilyRequest(inviteCode, userName, email, password));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Joining the household failed.");
      throw requestError;
    }
  }, [adoptNewSession]);

  const signOut = useCallback(async () => {
    // Revoke this browser while its request still carries the old account's
    // cookie. The helper is best-effort and strictly time-bounded.
    try {
      await revokeCurrentBrowserPushSubscription(getAuthSessionEpoch());
    } catch {
      // Push cleanup is best-effort and must never trap the user in a session.
    }
    const previousOwner = currentOfflineQueueOwner();
    // Detach the owner before erasure so an in-flight response cannot repopulate
    // private local data while the cookie teardown is in flight.
    resetAuthIdentity();
    setOfflineQueueOwner(null);
    setUser(null);
    if (previousOwner) {
      await Promise.allSettled([
        purgeFitnessOwnerData(previousOwner),
        purgeOfflineOwnerData(previousOwner),
      ]);
    }
    await clearOfflineSession();
    await logoutRequest();
  }, []);

  const updateUser = useCallback((nextUser: User) => {
    installAuthIdentity(nextUser);
    setOfflineQueueOwner(nextUser);
    setUser(nextUser);
    void cacheOfflineSession(nextUser);
  }, []);

  const value = useMemo(
    () => ({ user, loading, error, signIn, registerFamily, joinFamily, signOut, updateUser }),
    [user, loading, error, signIn, registerFamily, joinFamily, signOut, updateUser],
  );
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used inside AuthProvider");
  return context;
}
