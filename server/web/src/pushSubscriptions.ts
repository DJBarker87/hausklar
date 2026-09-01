import { api, getAuthSessionEpoch } from "./api";

type PushRevocationResult = {
  hadSubscription: boolean;
  removedFromServer: boolean;
  unsubscribed: boolean;
};

const READY_TIMEOUT_MS = 500;
const SUBSCRIPTION_TIMEOUT_MS = 300;
const DIGEST_TIMEOUT_MS = 300;
const SERVER_REMOVE_TIMEOUT_MS = 1_250;
const UNSUBSCRIBE_TIMEOUT_MS = 500;
const NOTIFICATION_CLOSE_TIMEOUT_MS = 300;

async function settleWithin<T>(promise: PromiseLike<T>, timeoutMs: number): Promise<T | null> {
  return new Promise((resolve) => {
    let settled = false;
    const timer = window.setTimeout(() => {
      settled = true;
      resolve(null);
    }, timeoutMs);
    Promise.resolve(promise).then(
      (value) => {
        if (settled) return;
        settled = true;
        window.clearTimeout(timer);
        resolve(value);
      },
      () => {
        if (settled) return;
        settled = true;
        window.clearTimeout(timer);
        resolve(null);
      },
    );
  });
}

async function invokeWithin<T>(operation: () => T | PromiseLike<T>, timeoutMs: number): Promise<T | null> {
  return settleWithin(Promise.resolve().then(operation), timeoutMs);
}

export async function pushEndpointDigest(endpoint: string): Promise<string | null> {
  if (!globalThis.crypto?.subtle) return null;
  const digest = await invokeWithin(
    () => globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(endpoint)),
    DIGEST_TIMEOUT_MS,
  );
  if (!digest) return null;
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function currentRegistration(): Promise<ServiceWorkerRegistration | null> {
  if (!("serviceWorker" in navigator)) return null;
  return invokeWithin(() => navigator.serviceWorker.ready, READY_TIMEOUT_MS);
}

export async function currentBrowserHasPushSubscription(): Promise<boolean> {
  const registration = await currentRegistration();
  if (!registration) return false;
  return Boolean(await invokeWithin(() => registration.pushManager.getSubscription(), SUBSCRIPTION_TIMEOUT_MS));
}

async function closeHausKlarNotifications(
  registration: ServiceWorkerRegistration,
  authEpoch: number,
): Promise<void> {
  if (!("getNotifications" in registration)) return;
  const notifications = await invokeWithin(() => registration.getNotifications(), NOTIFICATION_CLOSE_TIMEOUT_MS);
  if (getAuthSessionEpoch() !== authEpoch) return;
  notifications?.forEach((notification) => {
    if (notification.tag.startsWith("hausklar-")) notification.close();
  });
}

/**
 * Remove only this browser's endpoint. Every stage is bounded so sign-out can
 * never hang on service-worker or push-provider state. The epoch guard also
 * prevents a late A cleanup from issuing a request after B has signed in.
 */
export async function revokeCurrentBrowserPushSubscription(
  expectedAuthEpoch?: number,
): Promise<PushRevocationResult> {
  const authEpoch = expectedAuthEpoch ?? getAuthSessionEpoch();
  const registration = await currentRegistration();
  if (!registration) return { hadSubscription: false, removedFromServer: false, unsubscribed: false };
  if (getAuthSessionEpoch() !== authEpoch) {
    return { hadSubscription: false, removedFromServer: false, unsubscribed: false };
  }

  const subscription = await invokeWithin(
    () => registration.pushManager.getSubscription(),
    SUBSCRIPTION_TIMEOUT_MS,
  );
  if (getAuthSessionEpoch() !== authEpoch) {
    return { hadSubscription: false, removedFromServer: false, unsubscribed: false };
  }
  let removedFromServer = false;
  let unsubscribed = false;

  if (subscription) {
    const digest = await pushEndpointDigest(subscription.endpoint);
    if (digest && getAuthSessionEpoch() === authEpoch) {
      const controller = new AbortController();
      const removal = api<void>(
        `/reminders/push/subscriptions/${digest}`,
        { method: "DELETE", signal: controller.signal, timeoutMs: SERVER_REMOVE_TIMEOUT_MS },
        false,
        false,
      ).then(() => true, () => false);
      removedFromServer = (await settleWithin(removal, SERVER_REMOVE_TIMEOUT_MS)) ?? false;
      controller.abort();
    }
    if (getAuthSessionEpoch() !== authEpoch) {
      return { hadSubscription: true, removedFromServer, unsubscribed: false };
    }
    unsubscribed = (await invokeWithin(() => subscription.unsubscribe(), UNSUBSCRIBE_TIMEOUT_MS)) ?? false;
    if (getAuthSessionEpoch() !== authEpoch) {
      return { hadSubscription: true, removedFromServer, unsubscribed };
    }
  }

  await closeHausKlarNotifications(registration, authEpoch);
  return { hadSubscription: Boolean(subscription), removedFromServer, unsubscribed };
}
