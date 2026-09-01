import { expect, test, type Page, type TestInfo } from "@playwright/test";

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({ viewport: window.innerWidth, document: document.documentElement.scrollWidth, body: document.body.scrollWidth }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

test("medicine safety and illness logging are editable at 375px", async ({ page }, testInfo: TestInfo) => {
  test.skip(testInfo.project.name !== "mobile", "This check targets the phone layout.");
  let temperaturePayload: Record<string, unknown> | null = null;
  const medicine = { id: "calpol", child_id: "max", name: "Calpol", default_dose_amount: "5 ml", min_hours_between_doses: 4, max_doses_24h: 4, notes: "With food" };
  const illness = { id: "illness-1", child_id: "max", started_at: "2026-07-11T08:00:00Z", ended_at: null, notes: "Sore throat" };

  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname + url.search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    else if (path === "/api/family/members") body = [{ id: "dom", name: "Alex", member_type: "user" }, { id: "max", name: "Child One", member_type: "child" }];
    else if (path === "/api/children/") body = [{ id: "max", name: "Child One", date_of_birth: "2020-01-02" }];
    else if (path.startsWith("/api/medicine/types")) body = [medicine];
    else if (path.startsWith("/api/medicine/doses")) body = [];
    else if (path.startsWith("/api/illness/?")) body = [illness];
    else if (path.startsWith("/api/illness/temperature") && request.method() === "GET") body = [];
    else if (path === "/api/illness/illness-1/detail") body = { illness, temperature_readings: [], medicine_doses: [], next_dose_times: [{ medicine_type_id: "calpol", medicine_name: "Calpol", next_safe_at: null, is_safe_now: true, default_dose_amount: "5 ml", last_given_at: null }] };
    else if (path === "/api/illness/temperature" && request.method() === "POST") {
      temperaturePayload = request.postDataJSON() as Record<string, unknown>;
      body = { id: "temperature-1", ...temperaturePayload };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=family&section=medicine");
  await expect(page.getByRole("heading", { name: "Medicine", level: 1 })).toBeVisible();
  await expect(page.getByText("Every 4h · Child One 4 in 24h")).toBeVisible();
  await page.getByRole("button", { name: "Add medicine" }).click();
  const addMedicine = page.getByRole("dialog", { name: "Add medicine" });
  await expect(addMedicine.getByLabel("Minimum hours between doses")).toHaveValue("4");
  await expect(addMedicine.getByLabel("Maximum doses in 24 hours")).toHaveValue("4");
  await addMedicine.getByRole("button", { name: "Close" }).click();
  await page.getByRole("button", { name: "Edit Calpol" }).click();
  const editMedicine = page.getByRole("dialog", { name: "Edit medicine" });
  await expect(editMedicine.getByLabel("Saved dose amount (optional — copy from label)")).toHaveValue("5 ml");
  await editMedicine.getByRole("button", { name: "Close" }).click();
  await expectNoDocumentOverflow(page);

  await page.goto("/?view=family&section=illness");
  await expect(page.getByRole("heading", { name: "Illness", level: 1 })).toBeVisible();
  await expect(page.locator(".illness-mode-heading p")).toContainText("Sore throat");
  await page.getByRole("button", { name: "Edit notes" }).click();
  const illnessNotes = page.getByRole("dialog", { name: "Edit illness notes" });
  await expect(illnessNotes.getByLabel("Symptoms or notes")).toHaveValue("Sore throat");
  await illnessNotes.getByRole("button", { name: "Close" }).click();
  await page.getByLabel("Temperature (°C)").fill("38.1");
  await page.getByLabel("Recorded at").fill("2026-07-10T21:15");
  await page.getByLabel("Notes (optional)").fill("After waking");
  await page.getByRole("button", { name: "Log temperature" }).click();
  await expect.poll(() => temperaturePayload).not.toBeNull();
  expect(temperaturePayload).toMatchObject({ child_id: "max", illness_id: "illness-1", value_celsius: 38.1, notes: "After waking" });

  await page.getByRole("button", { name: "Record medicine", exact: true }).click();
  const dose = page.getByRole("dialog", { name: "Record medicine" });
  await expect(dose.getByLabel("Given at")).toBeVisible();
  await dose.getByRole("button", { name: "Close" }).click();
  const undersized = await page.locator(".child-filter button:visible, .illness-mode button:visible, .family-section-title button:visible").evaluateAll((elements) => elements.map((element) => {
    const box = element.getBoundingClientRect();
    return { label: element.getAttribute("aria-label") || element.textContent?.trim(), width: Math.round(box.width), height: Math.round(box.height) };
  }).filter(({ width, height }) => width < 44 || height < 44));
  expect(undersized).toEqual([]);
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("illness.png"), fullPage: false });
});
