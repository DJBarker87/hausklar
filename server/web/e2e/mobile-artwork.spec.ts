import { expect, test, type Page, type TestInfo } from "@playwright/test";

const artworks = [
  {
    id: "art-1", child_id: "child-1", child_name: "Child One", title: "Rainbow city",
    approx_date: "2026-06", date_precision: "month", age_label: "Age 6", notes: null,
    medium: "Watercolour", story: "Painted after the rain stopped.", child_quote: "Everyone lives in the clouds",
    school_year: "Year 1", favourite: true, include_in_yearbook: true, yearbook_position: null,
    original_available: true, rotation_degrees: 0, enhanced: false,
    created_at: "2026-06-10T10:00:00Z", updated_at: "2026-06-10T10:00:00Z",
    image_url: "/artworks/art-1/image?v=20260610100000", original_image_url: "/artworks/art-1/image?size=original",
  },
  {
    id: "art-2", child_id: "child-1", child_name: "Child One", title: "Night dragon",
    approx_date: "2026", date_precision: "year", age_label: "Age 6", notes: null,
    medium: "Crayon", story: null, child_quote: null, school_year: null,
    favourite: false, include_in_yearbook: false, yearbook_position: null,
    original_available: true, rotation_degrees: 0, enhanced: false,
    created_at: "2026-05-01T10:00:00Z", updated_at: "2026-05-01T10:00:00Z",
    image_url: "/artworks/art-2/image?v=20260501100000", original_image_url: "/artworks/art-2/image?size=original",
  },
  {
    id: "art-3", child_id: "child-1", child_name: "Child One", title: null,
    approx_date: "2025-11-03", date_precision: "day", age_label: "Age 5", notes: "Made at school",
    medium: "Collage", story: null, child_quote: null, school_year: "Reception",
    favourite: false, include_in_yearbook: true, yearbook_position: null,
    original_available: true, rotation_degrees: 0, enhanced: true,
    created_at: "2025-11-03T10:00:00Z", updated_at: "2025-11-03T10:00:00Z",
    image_url: "/artworks/art-3/image?v=20251103100000", original_image_url: "/artworks/art-3/image?size=original",
  },
];

function drawing(id: string): string {
  const palette = id === "art-1"
    ? ["#fff4d6", "#4f9ee8", "#ec6f88", "#f7bd52"]
    : id === "art-2"
      ? ["#161a35", "#9f8cff", "#f0b95c", "#6f78d9"]
      : ["#f3ead7", "#58a87b", "#e87952", "#f3c84d"];
  return `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600" viewBox="0 0 800 600"><rect width="800" height="600" fill="${palette[0]}"/><path d="M80 430 Q200 120 360 390 T720 250" fill="none" stroke="${palette[1]}" stroke-width="56" stroke-linecap="round"/><circle cx="250" cy="230" r="88" fill="${palette[2]}" opacity=".88"/><path d="M120 510 L330 290 L510 500 L670 360 L760 520 Z" fill="${palette[3]}" opacity=".9"/></svg>`;
}

async function expectNoOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

test("Artwork keeps pile capture and the full archive calm at every supported width", async ({ page }, testInfo: TestInfo) => {
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname + url.search;
    if (/^\/api\/artworks\/art-[123]\/image/.test(url.pathname)) {
      const id = url.pathname.match(/art-[123]/)?.[0] ?? "art-1";
      await route.fulfill({ status: 200, contentType: "image/svg+xml", body: drawing(id) });
      return;
    }
    let body: unknown = [];
    if (path === "/api/auth/web/session") body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    else if (path === "/api/family/members") body = [{ id: "dom", name: "Alex", member_type: "user" }, { id: "child-1", name: "Child One", member_type: "child" }];
    else if (path === "/api/children/") body = [{ id: "child-1", name: "Child One", date_of_birth: "2020-01-02" }];
    else if (path.startsWith("/api/artworks/?")) body = artworks;
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=family&section=artwork");
  await expect(page.getByRole("heading", { name: "Artwork", level: 2 })).toBeVisible();
  await expect(page.getByRole("button", { name: /Rainbow city/ })).toBeVisible();
  await expect(page.getByText("Gallery only")).toBeVisible();
  await expect(page.getByAltText("Rainbow city")).toHaveAttribute("src", /v=20260610100000&size=thumb/);
  await expectNoOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("artwork-gallery.png"), fullPage: false });

  await page.getByRole("button", { name: /Rainbow city/ }).click();
  const viewer = page.getByRole("dialog", { name: "Rainbow city" });
  await expect(viewer.getByText("Painted after the rain stopped.")).toBeVisible();
  await expect(viewer.getByText("“Everyone lives in the clouds”")).toBeVisible();
  await expect(viewer.getByRole("button", { name: "Remove favourite" })).toBeVisible();
  await expect(viewer.getByRole("link", { name: "Original" })).toBeVisible();
  await expectNoOverflow(page);
  await viewer.getByRole("button", { name: "Close" }).click();

  await page.getByRole("button", { name: "Add artwork" }).click();
  const capture = page.getByRole("dialog", { name: "Add artwork" });
  const tinyPng = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zk0cAAAAASUVORK5CYII=", "base64");
  await capture.getByLabel(/Photograph or choose a pile/).setInputFiles([
    { name: "drawing-one.png", mimeType: "image/png", buffer: tinyPng },
    { name: "drawing-two.png", mimeType: "image/png", buffer: tinyPng },
  ]);
  await expect(capture.getByText("Piece 1")).toBeVisible();
  await expect(capture.getByText("Piece 2")).toBeVisible();
  await capture.getByRole("button", { name: /More details/ }).click();
  await expect(capture.getByLabel("The story behind it")).toBeVisible();
  await expect(capture.getByLabel("What they said about it")).toBeVisible();
  await expectNoOverflow(page);

  if (testInfo.project.name === "mobile") {
    const undersized = await page.locator(".artwork-panel button:visible, .artwork-panel a:visible, .artwork-panel__capture-zone label:visible").evaluateAll((elements) => elements.map((element) => {
      const box = element.getBoundingClientRect();
      return { label: element.textContent?.trim(), width: Math.round(box.width), height: Math.round(box.height) };
    }).filter(({ width, height }) => width < 44 || height < 44));
    expect(undersized).toEqual([]);
  }
  await page.screenshot({ path: testInfo.outputPath("artwork-capture.png"), fullPage: false });
});
