import { expect, test, type Page, type TestInfo } from "@playwright/test";

const members = [
  { id: "dom", name: "Alex", member_type: "user" },
  { id: "max", name: "Child One", member_type: "child" },
  { id: "lily", name: "Lily", member_type: "child" },
];

function document(id: string, title: string, personID: string, personName: string) {
  return {
    id,
    title,
    original_filename: `${id}.pdf`,
    media_type: "application/pdf",
    file_size: 4_096,
    source: "upload",
    category: "school",
    status: "inbox",
    page_count: 1,
    processor: "device",
    people: [{ id: `person-${id}`, person_id: personID, person_name: personName, person_type: "child" }],
    suggestions: [],
    pending_suggestion_count: 0,
    download_url: `/api/documents/${id}/download`,
    created_at: "2026-07-11T08:00:00Z",
    updated_at: "2026-07-11T08:00:00Z",
  };
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

test("document capture and person filters are usable at every supported width", async ({ page }, testInfo: TestInfo) => {
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname + new URL(route.request().url()).search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    } else if (path === "/api/family/members") {
      body = members;
    } else if (path.startsWith("/api/documents/?")) {
      body = [
        document("max-letter", "Child One nursery letter", "max", "Child One"),
        document("lily-letter", "Lily school letter", "lily", "Lily"),
      ];
    } else if (path === "/api/documents/email-address") {
      body = { configured: true, address: "demo-person-10@example.invalid" };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=documents");
  await expect(page.getByRole("heading", { name: "Documents" })).toBeVisible();
  const personFilters = page.getByRole("group", { name: "Filter documents by person" });
  await expect(personFilters.getByRole("button", { name: "Everyone" })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByText("Child One nursery letter")).toBeVisible();
  await expect(page.getByText("Lily school letter")).toBeVisible();

  await personFilters.getByRole("button", { name: "Child One" }).click();
  await expect(personFilters.getByRole("button", { name: "Child One" })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByText("Child One nursery letter")).toBeVisible();
  await expect(page.getByText("Lily school letter")).toHaveCount(0);

  await page.getByRole("button", { name: "Add document" }).click();
  const capture = page.getByRole("dialog", { name: "Add" });
  await expect(capture.getByRole("button", { name: "Letter or file", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(capture.getByText("Add the original photo or document")).toBeVisible();
  await expect(capture.getByRole("button", { name: "Scan document", exact: true })).toBeVisible();
  await expect(capture.getByRole("button", { name: "Upload photo or file", exact: true })).toBeVisible();
  await capture.getByRole("button", { name: "Close" }).click();

  const undersized = await page.locator(".document-toolbar button:visible, .filter-chips button:visible, .documents-page > .page-header .button:visible").evaluateAll((elements) => elements.map((element) => {
    const box = element.getBoundingClientRect();
    return { label: element.textContent?.trim(), width: Math.round(box.width), height: Math.round(box.height) };
  }).filter(({ width, height }) => {
    const minimum = window.innerWidth <= 600 ? 44 : 40;
    return width < minimum || height < minimum;
  }));
  expect(undersized).toEqual([]);
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("documents.png"), fullPage: false });
});
