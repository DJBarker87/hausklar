import { expect, test } from "@playwright/test";

test("the house map is visible, responsive, and controls live rooms", async ({ page }, testInfo) => {
  let actionBody: unknown = null;

  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    let body: unknown = [];

    if (url.pathname.endsWith("/auth/web/session")) {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (url.pathname.endsWith("/family/members")) {
      body = [];
    } else if (url.pathname.endsWith("/home/layout")) {
      body = {
        width: 900,
        height: 820,
        floors: [
          { id: 0, name: "Ground floor", rooms: [{ id: "kitchen", label: "Kitchen", bounds: { x: 463, y: 463, width: 368, height: 289 }, polygon: [[463, 519], [758, 519], [758, 463], [831, 463], [831, 752], [463, 752]], light_entity_ids: ["light.example_3f2a461f"], label_at: [650, 650] }], walls: [[463, 519, 758, 519]], stairs: [] },
          { id: 1, name: "First floor", rooms: [{ id: "bathroom", label: "Bathroom", bounds: { x: 490, y: 519, width: 341, height: 233 }, light_entity_ids: ["light.example_f62d9439"], label_at: [660, 650] }], walls: [[490, 519, 831, 519]], stairs: [] },
        ],
        temperatures: [{ floor: 0, entity_ids: ["climate.example_9feafd80"], at: [504, 546] }],
        doors: [{ floor: 0, entity_ids: ["binary_sensor.example_e1938001"], at: [567, 155], label: "Front door" }],
      };
    } else if (url.pathname.endsWith("/home/status")) {
      body = {
        configured: true,
        available: true,
        entities: [
          { entity_id: "light.example_3f2a461f", name: "Kitchen", domain: "light", state: "on" },
          { entity_id: "light.example_f62d9439", name: "Bathroom", domain: "light", state: "off" },
          { entity_id: "climate.example_9feafd80", name: "Kitchen", domain: "climate", state: "heat", current_temperature: 20.5, temperature: 21 },
          { entity_id: "binary_sensor.example_e1938001", name: "Front door", domain: "binary_sensor", state: "off", device_class: "door" },
        ],
        manifest: {
          rooms: [
            { id: "kitchen", name: "Kitchen", floor: 0, entity_ids: ["light.example_3f2a461f", "climate.example_9feafd80"], light_entity_ids: ["light.example_3f2a461f"] },
            { id: "bathroom", name: "Bathroom", floor: 1, entity_ids: ["light.example_f62d9439"], light_entity_ids: ["light.example_f62d9439"] },
          ],
          entities: [
            { entity_id: "light.example_3f2a461f", name: "Kitchen", domain: "light", room_id: "kitchen", room_name: "Kitchen", control_kind: "light", capabilities: ["toggle", "turn_on", "turn_off"], favourite: true, advanced: false },
            { entity_id: "light.example_f62d9439", name: "Bathroom", domain: "light", room_id: "bathroom", room_name: "Bathroom", control_kind: "light", capabilities: ["toggle", "turn_on", "turn_off"], favourite: false, advanced: false },
            { entity_id: "climate.example_9feafd80", name: "Kitchen heating", domain: "climate", room_id: "kitchen", room_name: "Kitchen", control_kind: "climate", capabilities: ["set_temperature"], favourite: false, advanced: false },
            { entity_id: "binary_sensor.example_e1938001", name: "Front door", domain: "binary_sensor", room_id: "kitchen", room_name: "Kitchen", control_kind: "sensor", capabilities: ["view"], favourite: false, advanced: false },
          ],
          favourite_entity_ids: ["light.example_3f2a461f"],
          mode_selector: null,
          broad_action_scopes: ["favourites", "room", "all"],
          advanced_features: ["floor_plan_2d"],
        },
      };
    } else if (url.pathname.endsWith("/home/actions")) {
      actionBody = route.request().postDataJSON();
      body = { success: true };
    }

    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=home");
  await page.getByText("Advanced", { exact: true }).click();

  const map = page.getByRole("region", { name: "House map" });
  await expect(map).toBeVisible();
  await expect(map.getByRole("img", { name: /Ground floor house map. 1 light on/ })).toBeVisible();

  const canvasBox = await map.locator(".home-floor-plan-canvas").boundingBox();
  expect(canvasBox).not.toBeNull();
  expect(canvasBox!.x).toBeGreaterThanOrEqual(0);
  expect(canvasBox!.x + canvasBox!.width).toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth));

  const kitchen = map.getByRole("button", { name: "Kitchen light, on" });
  const kitchenBox = await kitchen.boundingBox();
  expect(kitchenBox?.width).toBeGreaterThanOrEqual(44);
  expect(kitchenBox?.height).toBeGreaterThanOrEqual(44);
  await page.screenshot({ path: testInfo.outputPath("house-map.png"), fullPage: false });
  await kitchen.click();
  await expect.poll(() => actionBody).toEqual({ entity_id: "light.example_3f2a461f", action: "toggle" });

  await map.getByRole("button", { name: "First" }).click();
  await expect(map.getByRole("img", { name: /First floor house map/ })).toBeVisible();
  await expect(map.getByRole("button", { name: "Bathroom light, off" })).toBeVisible();

  const overflow = await page.evaluate(() => ({ viewport: window.innerWidth, document: document.documentElement.scrollWidth }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
});
