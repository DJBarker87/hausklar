import { expect, test, type Page, type TestInfo } from "@playwright/test";

const productionCsp = [
  "default-src 'self'",
  "base-uri 'self'",
  "connect-src 'self'",
  "font-src 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  "img-src 'self' data: blob:",
  "manifest-src 'self'",
  "media-src 'self' blob:",
  "object-src 'none'",
  // Vite's development harness injects the React refresh bootstrap and CSS.
  // Resource origins remain self-only, which is the privacy boundary under test.
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "worker-src 'self'",
].join("; ");

// A compact but genuinely shaped sample route. The production parser keeps
// every timestamped FIT record; this fixture uses a point every 45 seconds so
// screenshots remain lightweight while still exercising bends and a loop.
const routeSamples: Array<[latitude: number, longitude: number]> = [
  [51.48730, -0.61060],
  [51.48765, -0.61100],
  [51.48800, -0.61140],
  [51.48840, -0.61172],
  [51.48882, -0.61202],
  [51.48922, -0.61238],
  [51.48962, -0.61272],
  [51.49002, -0.61302],
  [51.49042, -0.61318],
  [51.49080, -0.61282],
  [51.49110, -0.61222],
  [51.49136, -0.61142],
  [51.49156, -0.61052],
  [51.49166, -0.60952],
  [51.49160, -0.60850],
  [51.49144, -0.60750],
  [51.49120, -0.60662],
  [51.49086, -0.60602],
  [51.49046, -0.60570],
  [51.49002, -0.60572],
  [51.48960, -0.60592],
  [51.48922, -0.60624],
  [51.48886, -0.60670],
  [51.48854, -0.60730],
  [51.48826, -0.60802],
  [51.48802, -0.60882],
  [51.48782, -0.60948],
  [51.48756, -0.61002],
  [51.48764, -0.60958],
];

const offsets = routeSamples.map((_, index) => index * 45_000);
const distances = routeSamples.map((_, index) => index * 4_000 / (routeSamples.length - 1));
const privateTile = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");

const activity = {
  id: "run-map",
  title: "Example School morning run",
  sport_key: "running",
  started_at_utc: "2026-08-02T06:00:00Z",
  status: "complete",
  workout_classification: "easy",
  distance_m: 4_000,
  duration_s: 1_260,
  elapsed_duration_s: 1_260,
  timer_duration_s: 1_230,
  moving_duration_s: 1_220,
  energy_kcal: 310,
  route_preview: routeSamples.filter((_, index) => index % 4 === 0 || index === routeSamples.length - 1),
};

const activityDetail = {
  activity,
  sources: [{ id: "source-1", source_type: "healthkit", device_name: "Apple Watch", is_primary: true }],
  summary_metrics: [
    { metric_key: "speed.average_mps", value_number: 3.25, unit_key: "m/s" },
    { metric_key: "heart_rate.average_bpm", value_number: 146, unit_key: "bpm" },
    { metric_key: "elevation.gain_m", value_number: 38, unit_key: "m" },
  ],
  available_stream_metrics: [
    "pace_s_per_km",
    "heart_rate_bpm",
    "altitude_m",
    "latitude_deg",
    "longitude_deg",
  ],
  intervals: [310, 315, 315, 320].map((pace, index) => ({
    id: `split-${index + 1}`,
    sequence: index,
    interval_kind: "kilometre_split",
    origin: "derived",
    start_offset_ms: [0, 310_000, 625_000, 940_000][index],
    end_offset_ms: [310_000, 625_000, 940_000, 1_260_000][index],
    start_distance_m: index * 1_000,
    end_distance_m: (index + 1) * 1_000,
    label: `Kilometre ${index + 1}`,
    metrics: {
      pace_s_per_km: pace,
      "elevation.change_m": [2, -1, 4, 0][index],
      "heart_rate.average_bpm": [136, 143, 148, 151][index],
      "power.average_w": [268, 274, 279, 271][index],
    },
  })),
  records: [],
  achievements: [],
  checkins: [],
  body_issues: [],
  gear: [],
  goal_links: [],
  data_quality: [],
};

const activityStream = {
  activity_id: "run-map",
  clock: "elapsed",
  offset_ms: offsets,
  distance_m: distances,
  series: {
    pace_s_per_km: routeSamples.map((_, index) => Math.round(315 + 8 * Math.sin(index / 2.2) + 3 * Math.cos(index / 4.1))),
    heart_rate_bpm: routeSamples.map((_, index) => Math.round(126 + 27 * index / (routeSamples.length - 1) + 3 * Math.sin(index / 3))),
    altitude_m: routeSamples.map((_, index) => Number((22 + 0.32 * index + 3.5 * Math.sin(index / 3.5)).toFixed(1))),
    latitude_deg: routeSamples.map(([latitude]) => latitude),
    longitude_deg: routeSamples.map(([, longitude]) => longitude),
  },
  units: {
    pace_s_per_km: "s/km",
    heart_rate_bpm: "bpm",
    altitude_m: "m",
    latitude_deg: "deg",
    longitude_deg: "deg",
  },
  downsampled: false,
  source_point_count: routeSamples.length,
};

async function mockActivityApi(page: Page) {
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    let body: unknown = [];

    if (/^\/api\/fitness\/maps\/tiles\/\d+\/\d+\/\d+\.(png|jpg|webp|pbf)$/.test(path)) {
      await route.fulfill({
        status: 200,
        contentType: "image/png",
        headers: { "cache-control": "private, max-age=60" },
        body: privateTile,
      });
      return;
    }

    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/fitness/sync") {
      body = { status: "ok", accepted: [], changes: [], redirects: [], notices: [], next_cursor: 0 };
    } else if (path === "/api/fitness/activity-registry") {
      body = { sports: [], metrics: [] };
    } else if (path === "/api/fitness/running/load") {
      body = {
        windows: {
          "7d": { days: 7, distance_m: 4_000, duration_s: 1_260, session_count: 1, hard_session_count: 0, session_rpe_load: null },
          "28d": { days: 28, distance_m: 16_000, duration_s: 5_040, session_count: 4, hard_session_count: 0, session_rpe_load: null },
          "42d": { days: 42, distance_m: 24_000, duration_s: 7_560, session_count: 6, hard_session_count: 0, session_rpe_load: null },
        },
        volume_change_pct: 0,
        missing_rpe_sessions: 1,
        explanation: "",
      };
    } else if (path === "/api/fitness/maps") {
      body = {
        available: true,
        format: "png",
        min_zoom: 0,
        max_zoom: 16,
        bounds: [-1, 50, 1, 52],
        style_url: "/api/fitness/maps/style.json",
        tilejson_url: "/api/fitness/maps/tilejson.json",
        has_sprites: false,
        has_glyphs: false,
      };
    } else if (path === "/api/fitness/maps/style.json") {
      body = {
        version: 8,
        name: "HausKlar private archive",
        sources: {
          archive: { type: "raster", url: "/api/fitness/maps/tilejson.json", tileSize: 256 },
        },
        layers: [
          { id: "private-background", type: "background", paint: { "background-color": "#e7ece8" } },
          { id: "private-archive", type: "raster", source: "archive", paint: { "raster-opacity": 0.18 } },
        ],
      };
    } else if (path === "/api/fitness/maps/tilejson.json") {
      body = {
        tilejson: "3.0.0",
        name: "HausKlar private archive",
        scheme: "xyz",
        minzoom: 0,
        maxzoom: 16,
        bounds: [-1, 50, 1, 52],
        tiles: [`${url.origin}/api/fitness/maps/tiles/{z}/{x}/{y}.png`],
      };
    } else if (path === "/api/fitness/activities/run-map/streams") {
      body = activityStream;
    } else if (path === "/api/fitness/activities/run-map/analysis") {
      body = {};
    } else if (path === "/api/fitness/activities/run-map/comparisons") {
      body = [];
    } else if (path === "/api/fitness/activities/run-map") {
      body = activityDetail;
    } else if (path === "/api/fitness/activities") {
      body = [activity];
    }

    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

async function applyProductionCsp(page: Page) {
  await page.route("**/*", async (route) => {
    if (route.request().resourceType() !== "document") {
      await route.fallback();
      return;
    }
    const response = await route.fetch();
    await route.fulfill({
      response,
      headers: { ...response.headers(), "content-security-policy": productionCsp },
    });
  });
}

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

test("private activity route is scan-first, interactive and same-origin", async ({ page }, testInfo: TestInfo) => {
  const pageErrors: string[] = [];
  const streamRequests: string[] = [];
  const networkRequests: string[] = [];
  const privateMapRequests: Array<{ url: string; cookie: string }> = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("request", (request) => {
    networkRequests.push(request.url());
    const requestPath = new URL(request.url()).pathname;
    if (requestPath === "/api/fitness/activities/run-map/streams") streamRequests.push(request.url());
    if (requestPath.startsWith("/api/fitness/maps/")) privateMapRequests.push({
      url: request.url(),
      cookie: request.headers()["cookie"] ?? "",
    });
  });
  const baseURL = String(testInfo.project.use.baseURL);
  await page.context().addCookies([{ name: "hausklar_session", value: "private-test-session", url: baseURL }]);
  await page.emulateMedia({ reducedMotion: "reduce", contrast: "more", colorScheme: testInfo.project.name === "desktop" ? "dark" : "light" });
  if (testInfo.project.name === "desktop") {
    await page.addInitScript(() => localStorage.setItem("hausklar-theme", "dark"));
  }
  await mockActivityApi(page);
  await applyProductionCsp(page);

  await page.goto("/?view=fitness&section=activity&activity=run-map");
  const dialog = page.getByRole("dialog", { name: "Example School morning run" });
  await expect(dialog).toBeVisible();
  const map = dialog.getByRole("region", { name: "Interactive activity route map" });
  await expect(map).toHaveAttribute("aria-busy", "false");
  const routeFigure = dialog.locator(".activity-route-map--private");
  await expect(routeFigure).toBeVisible();
  const routeSurface = map.locator("canvas.maplibregl-canvas");
  await expect(routeSurface).toBeVisible();
  await expect(map.getByRole("link", { name: "© OpenStreetMap contributors" })).toHaveAttribute("href", "https://www.openstreetmap.org/copyright");
  await expect(map.getByRole("link", { name: "Protomaps" })).toHaveAttribute("href", "https://protomaps.com");
  await expect(map.locator(".fitness-module__route-marker")).toHaveCount(3);
  await expect(map.locator(".fitness-module__route-marker.is-start")).toBeVisible();
  await expect(map.locator(".fitness-module__route-marker.is-finish")).toBeVisible();
  await expect(map.locator(".fitness-module__route-marker.is-selected")).toBeVisible();
  await expect(dialog.getByText("2.00 km · 10:30")).toBeVisible();
  const mapSurfaceBox = await routeSurface.boundingBox();
  expect(mapSurfaceBox).not.toBeNull();
  expect(mapSurfaceBox!.height).toBeGreaterThanOrEqual(250);

  const hierarchy = await dialog.locator("#activity-route, #activity-overview, #activity-splits, #activity-charts, #activity-manage").evaluateAll((elements) => elements.map((element) => element.id));
  expect(hierarchy).toEqual(["activity-route", "activity-overview", "activity-splits", "activity-charts", "activity-manage"]);
  await expect(dialog.getByText("Average pace")).toBeVisible();
  await expect(dialog.getByRole("heading", { name: "Splits", exact: true })).toBeVisible();
  const splitTable = dialog.getByRole("table", { name: "Kilometres split comparison" });
  await expect(splitTable.getByRole("columnheader", { name: "Km" })).toBeVisible();
  await expect(splitTable.getByRole("columnheader", { name: "Pace" })).toBeVisible();
  await expect(splitTable.getByRole("columnheader", { name: "Elevation change in metres" })).toHaveText("Elev");
  await expect(splitTable.getByRole("columnheader", { name: "Average heart rate" })).toHaveText("HR");
  await expect(splitTable.getByRole("columnheader", { name: "Average power in watts" })).toHaveText("W");
  const splitRows = splitTable.getByRole("row");
  await expect(splitRows).toHaveCount(5);
  const firstSplit = splitRows.nth(1);
  await expect(firstSplit.getByText("5:10", { exact: true })).toBeVisible();
  await expect(firstSplit.getByText("2", { exact: true })).toBeVisible();
  await expect(firstSplit.getByText("136", { exact: true })).toBeVisible();
  await expect(firstSplit.getByText("268", { exact: true })).toBeVisible();
  await expect(splitRows.nth(2).getByText("-1", { exact: true })).toBeVisible();
  const firstBar = firstSplit.locator(".fitness-module__run-split-bar > span");
  const lastBar = splitRows.nth(4).locator(".fitness-module__run-split-bar > span");
  await expect(firstBar).toHaveAttribute("style", "width: 96%;");
  await expect(lastBar).toHaveAttribute("style", "width: 36%;");
  expect((await firstBar.boundingBox())!.width).toBeGreaterThan((await lastBar.boundingBox())!.width);
  await expect(dialog.getByText("Follow the effort")).toBeVisible();
  await expect(dialog.getByText("Manage activity")).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath(`fitness-wave6-activity-${testInfo.project.name}.png`), fullPage: false });
  await map.screenshot({ path: testInfo.outputPath(`fitness-wave6-route-${testInfo.project.name}.png`) });
  await splitTable.screenshot({ path: testInfo.outputPath(`fitness-wave6-splits-${testInfo.project.name}.png`) });

  await routeSurface.focus();
  await routeSurface.press("Home");
  await expect(dialog.locator(".fitness-module__route-map figcaption strong")).toHaveText("0 m · 0:00");
  const paceChart = dialog.getByRole("img", { name: /Pace chart/ });
  await paceChart.focus();
  await paceChart.press("End");
  await expect(dialog.locator(".fitness-module__route-map figcaption strong")).toHaveText("4.00 km · 21:00");

  const reset = map.getByRole("button", { name: "Reset route view" });
  const zoomOut = map.getByRole("button", { name: "Zoom out route" });
  const zoomIn = map.getByRole("button", { name: "Zoom in route" });
  const expand = map.getByRole("button", { name: "Expand map" });
  await expect(reset).toBeDisabled();
  for (const button of [reset, zoomOut, zoomIn, expand]) {
    const box = await button.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width).toBeGreaterThanOrEqual(44);
    expect(box!.height).toBeGreaterThanOrEqual(44);
  }
  await zoomIn.click();
  await expect(reset).toBeEnabled();
  await reset.click();
  await expect(reset).toBeDisabled();

  const compactHeight = (await map.boundingBox())?.height ?? 0;
  await expand.click();
  await expect(map.getByRole("button", { name: "Reduce map" })).toBeVisible();
  await expect.poll(async () => (await map.boundingBox())?.height ?? 0).toBeGreaterThan(compactHeight + 100);

  if (testInfo.project.name === "desktop") await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");

  await expectNoDocumentOverflow(page);
  expect(streamRequests.some((requestUrl) => {
    const query = new URL(requestUrl).searchParams;
    return query.get("metrics") === "latitude_deg,longitude_deg" && query.get("max_points") === "20000";
  })).toBe(true);
  const applicationOrigin = new URL(page.url()).origin;
  expect(privateMapRequests.some(({ url }) => new URL(url).pathname === "/api/fitness/maps/style.json")).toBe(true);
  expect(privateMapRequests.some(({ url }) => new URL(url).pathname === "/api/fitness/maps/tilejson.json")).toBe(true);
  expect(privateMapRequests.some(({ url }) => /\/api\/fitness\/maps\/tiles\//.test(new URL(url).pathname))).toBe(true);
  expect(privateMapRequests.every(({ url, cookie }) => new URL(url).origin === applicationOrigin && cookie.includes("hausklar_session="))).toBe(true);
  expect(privateMapRequests.every(({ url }) => /^\/api\/fitness\/maps\/(style\.json|tilejson\.json|tiles\/\d+\/\d+\/\d+\.(png|jpg|webp|pbf))$/.test(new URL(url).pathname))).toBe(true);
  expect(networkRequests.filter((requestUrl) => (
    requestUrl.startsWith("http") && new URL(requestUrl).origin !== applicationOrigin
  ))).toEqual([]);
  expect(pageErrors).toEqual([]);
});
