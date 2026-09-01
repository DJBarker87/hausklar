import { IDBFactory } from "fake-indexeddb";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { setOfflineQueueOwner } from "../offlineQueue";
import {
  cacheFitnessFoodLogDay,
  cacheFitnessProgressCharts,
  cacheFitnessPlannedMeals,
  cacheFitnessRecords,
  deleteFitnessRecord,
  cachedFitnessProgressCharts,
  cachedFitnessPlannedMeals,
  cachedFitnessRecords,
  fitnessLogUndo,
  fitnessNotices,
  fitnessPendingImports,
  fitnessSyncSummary,
  flushFitnessFitImports,
  flushFitnessPlannedMealLogs,
  flushFitnessSync,
  purgeCurrentFitnessOwnerData,
  queueFitnessFitImport,
  rememberFitnessLogUndo,
  removeFitnessPlannedMealLogFromDevice,
  saveFitnessPlannedMealLog,
  saveFitnessRecord,
  saveFitnessRecords,
} from "../fitness/offlineStore";
import type {
  FitnessExercise,
  FitnessExerciseSetup,
  FitnessFood,
  FitnessFoodLogEntry,
  FitnessProgressCharts,
} from "../fitness/contract";

const owner = { id: "dom", family_id: "family-a" };

function setOnline(value: boolean) {
  Object.defineProperty(window.navigator, "onLine", { configurable: true, value });
}

function syncResponse(overrides: Record<string, unknown> = {}) {
  return {
    status: "ok",
    current_sync_protocol_version: 1,
    current_client_schema_version: 1,
    minimum_supported_client_schema_version: 1,
    accepted: [],
    acked_mutation_ids: [],
    rejected_mutations: [],
    changes: [],
    redirects: [],
    notices: [],
    next_cursor: 1,
    ...overrides,
  };
}

describe("Fitness offline store", () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    window.localStorage.clear();
    setOfflineQueueOwner(owner);
    setOnline(false);
    vi.restoreAllMocks();
  });

  it("keeps derived progress charts available offline and private to their owner", async () => {
    const charts: FitnessProgressCharts = {
      weight: [{ measurement_id: "weight-1", measured_at_utc: "2026-08-01T07:00:00Z", weight_kg: 80.6 }],
      running: [
        { key: "5k", label: "5K", distance_m: 5000, points: [] },
        { key: "10k", label: "10K", distance_m: 10000, points: [] },
      ],
      strength: [
        { key: "squat", label: "Squat", points: [] },
        { key: "chest_press", label: "Chest press", points: [] },
        { key: "overhead_press", label: "Overhead press", points: [] },
      ],
    };

    await cacheFitnessProgressCharts(charts);
    expect(await cachedFitnessProgressCharts()).toEqual(charts);

    setOfflineQueueOwner({ id: "kat", family_id: "family-a" });
    expect(await cachedFitnessProgressCharts()).toBeNull();
    setOfflineQueueOwner(owner);
    expect(await cachedFitnessProgressCharts()).toEqual(charts);
  });

  it("creates a food with an immutable version and logs it before any sync", async () => {
    const foodId = "00000000-0000-4000-8000-000000000101";
    const versionId = "00000000-0000-4000-8000-000000000102";
    await saveFitnessRecord("food", {
      name: "Greek yoghurt",
      household_shared: false,
      favourite: true,
      active: true,
      version: {
        id: versionId,
        reference_amount: 100,
        reference_unit: "g",
        calories_kcal: 97,
        protein_g: 9,
        source_type: "manual",
      },
    }, { entityId: foodId });
    await saveFitnessRecord("food_log_entry", {
      food_version_id: versionId,
      logged_at_utc: "2026-08-02T07:30:00Z",
      local_timezone: "Europe/Berlin",
      meal_key: "breakfast",
      entered_amount: 150,
      entered_unit: "g",
      canonical_amount: 150,
      canonical_unit: "g",
      measurement_quality: "weighed",
    });

    const [food] = await cachedFitnessRecords<FitnessFood>("food");
    const [entry] = await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry");
    expect(food.id).toBe(foodId);
    expect(food.version?.id).toBe(versionId);
    expect(entry.food_version_id).toBe(versionId);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 2, failed: 0 });
  });

  it("keeps a removed diary entry removed when a diary list request answers late", async () => {
    const entryId = "00000000-0000-4000-8000-000000000111";
    const entry: FitnessFoodLogEntry = {
      id: entryId,
      revision: 3,
      food_version_id: "00000000-0000-4000-8000-000000000112",
      logged_at_utc: "2026-08-02T07:30:00Z",
      local_timezone: "Europe/London",
      nutrition_date: "2026-08-02",
      meal_key: "breakfast",
      entered_amount: 150,
      entered_unit: "g",
      canonical_amount: 150,
      canonical_unit: "g",
      measurement_quality: "weighed",
    } as unknown as FitnessFoodLogEntry;
    await cacheFitnessRecords("food_log_entry", [entry]);
    await deleteFitnessRecord("food_log_entry", entryId, 3);
    expect(await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry")).toEqual([]);

    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (_input, init) => {
      const mutations = (JSON.parse(String(init?.body)) as {
        mutations: Array<{ mutation_id: string; entity_id: string }>;
      }).mutations;
      return new Response(JSON.stringify(syncResponse({
        accepted: mutations.map((mutation) => ({ mutation_id: mutation.mutation_id, entity_id: mutation.entity_id, revision: 4 })),
        acked_mutation_ids: mutations.map((mutation) => mutation.mutation_id),
      })), { status: 200, headers: { "content-type": "application/json" } });
    }));
    setOnline(true);
    await flushFitnessSync();
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });

    // The diary request left before the removal reached the server, so its
    // response still contains the entry.
    await cacheFitnessRecords("food_log_entry", [entry]);

    expect(await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry")).toEqual([]);
  });

  it("drops a cached diary entry the server no longer holds without losing newer local work", async () => {
    const removedElsewhereId = "00000000-0000-4000-8000-000000000121";
    const keptId = "00000000-0000-4000-8000-000000000122";
    const otherDayId = "00000000-0000-4000-8000-000000000123";
    const savedAfterRequestId = "00000000-0000-4000-8000-000000000124";
    function entry(id: string, nutritionDate: string): FitnessFoodLogEntry {
      return {
        id,
        revision: 1,
        food_version_id: "00000000-0000-4000-8000-000000000125",
        logged_at_utc: `${nutritionDate}T07:30:00Z`,
        local_timezone: "Europe/London",
        nutrition_date: nutritionDate,
        meal_key: "breakfast",
        entered_amount: 100,
        entered_unit: "g",
        canonical_amount: 100,
        canonical_unit: "g",
        measurement_quality: "weighed",
      } as unknown as FitnessFoodLogEntry;
    }
    await cacheFitnessRecords("food_log_entry", [
      entry(removedElsewhereId, "2026-08-02"),
      entry(keptId, "2026-08-02"),
      entry(otherDayId, "2026-08-01"),
    ]);
    await new Promise((resolve) => { setTimeout(resolve, 2); });
    const requestStartedAt = new Date().toISOString();
    await saveFitnessRecord("food_log_entry", {
      food_version_id: "00000000-0000-4000-8000-000000000125",
      logged_at_utc: "2026-08-02T12:00:00Z",
      local_timezone: "Europe/London",
      nutrition_date: "2026-08-02",
      meal_key: "lunch",
      entered_amount: 80,
      entered_unit: "g",
      canonical_amount: 80,
      canonical_unit: "g",
      measurement_quality: "weighed",
    }, { entityId: savedAfterRequestId });

    await cacheFitnessFoodLogDay("2026-08-02", [entry(keptId, "2026-08-02")], requestStartedAt);

    const cached = await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry");
    expect(cached.map((item) => item.id).sort()).toEqual([keptId, otherDayId, savedAfterRequestId].sort());
  });

  it("never replays a merged identity edit against its survivor and rewrites child references", async () => {
    const sourceId = "00000000-0000-4000-8000-000000000201";
    const targetId = "00000000-0000-4000-8000-000000000202";
    const setupId = "00000000-0000-4000-8000-000000000203";
    await saveFitnessRecords([
      {
        entityType: "exercise",
        payload: { name: "Attempted source edit", favourite: true, active: true },
        options: { entityId: sourceId },
      },
      {
        entityType: "exercise_setup",
        payload: { exercise_id: sourceId, name: "Home", is_default: true, active: true },
        options: { entityId: setupId },
      },
    ]);

    const requests: Array<Record<string, unknown>> = [];
    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (_input, init) => {
      const request = JSON.parse(String(init?.body)) as Record<string, unknown>;
      requests.push(request);
      if (requests.length === 1) {
        return new Response(JSON.stringify(syncResponse({
          changes: [{
            sequence: 1,
            entity_type: "exercise",
            entity_id: targetId,
            revision: 7,
            operation: "upsert",
            data: { id: targetId, name: "Canonical survivor", favourite: false, active: true },
            changed_at: "2026-08-02T08:00:00Z",
          }],
          redirects: [{ entity_type: "exercise", source_id: sourceId, target_id: targetId }],
          notices: [{
            id: "canonical-change",
            message: "The exercise was merged.",
            attempted_fields: { name: "Attempted source edit" },
          }],
        })), { status: 200, headers: { "content-type": "application/json" } });
      }
      const mutations = request.mutations as Array<{ mutation_id: string; entity_id: string }>;
      return new Response(JSON.stringify(syncResponse({
        accepted: mutations.map((mutation) => ({
          mutation_id: mutation.mutation_id,
          entity_id: mutation.entity_id,
          revision: 2,
        })),
        acked_mutation_ids: mutations.map((mutation) => mutation.mutation_id),
        next_cursor: 2,
      })), { status: 200, headers: { "content-type": "application/json" } });
    });
    vi.stubGlobal("fetch", fetchMock);
    setOnline(true);

    await flushFitnessSync();

    expect(await cachedFitnessRecords<FitnessExercise>("exercise")).toEqual([
      expect.objectContaining({ id: targetId, name: "Canonical survivor" }),
    ]);
    expect(await cachedFitnessRecords<FitnessExerciseSetup>("exercise_setup")).toEqual([
      expect.objectContaining({ id: setupId, exercise_id: targetId }),
    ]);
    expect(await fitnessNotices()).toEqual([
      expect.objectContaining({ attempted_fields: { name: "Attempted source edit" } }),
    ]);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 1 });

    await flushFitnessSync();
    const replayed = requests[1]?.mutations as Array<{
      entity_type: string;
      entity_id: string;
      payload: Record<string, unknown>;
    }>;
    expect(replayed).toHaveLength(1);
    expect(replayed[0]).toMatchObject({
      entity_type: "exercise_setup",
      entity_id: setupId,
      payload: { exercise_id: targetId },
    });
    expect(replayed).not.toContainEqual(expect.objectContaining({
      entity_type: "exercise",
      entity_id: targetId,
    }));
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });
  });

  it("retains the whole outbox when the server requires a newer client", async () => {
    await saveFitnessRecord("goal", {
      goal_type: "body_weight",
      metric_key: "body.weight_kg",
      name: "Keep this local",
      starts_on: "2026-08-02",
      status: "active",
    });
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({
      detail: "Update HausKlar before Fitness can sync.",
      status: "upgrade_required",
    }), { status: 426, headers: { "content-type": "application/json" } })));
    setOnline(true);

    await expect(flushFitnessSync()).rejects.toThrow("Update HausKlar");

    expect(await fitnessSyncSummary()).toMatchObject({
      pending: 1,
      compatibilityBlocked: true,
      compatibilityMessage: "Update HausKlar before Fitness can sync.",
    });
    expect(await cachedFitnessRecords("goal")).toEqual([
      expect.objectContaining({ name: "Keep this local" }),
    ]);
  });

  it("replaces retained owner state from a required snapshot without losing unacked local work", async () => {
    const acceptedId = "00000000-0000-4000-8000-000000000301";
    const pendingId = "00000000-0000-4000-8000-000000000302";
    const staleId = "00000000-0000-4000-8000-000000000303";
    const serverOnlyId = "00000000-0000-4000-8000-000000000304";
    await cacheFitnessRecords("goal", [{ id: staleId, revision: 2, goal_type: "general", name: "Pruned server record", starts_on: "2026-01-01", status: "active" }]);
    await saveFitnessRecord("goal", { goal_type: "running", name: "Accepted local", starts_on: "2026-08-02", status: "active" }, { entityId: acceptedId });
    await saveFitnessRecord("goal", { goal_type: "nutrition", name: "Still pending locally", starts_on: "2026-08-02", status: "active" }, { entityId: pendingId });

    const syncBodies: Array<Record<string, unknown>> = [];
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      if (String(input).endsWith("/fitness/sync/snapshot")) {
        return new Response(JSON.stringify({
          status: "ok",
          current_sync_protocol_version: 1,
          current_client_schema_version: 1,
          minimum_supported_client_schema_version: 1,
          generated_at: "2026-08-02T12:00:00Z",
          entities: [
            { entity_type: "goal", entity_id: acceptedId, revision: 4, data: { id: acceptedId, goal_type: "running", name: "Accepted canonical", starts_on: "2026-08-02", status: "active" } },
            { entity_type: "goal", entity_id: pendingId, revision: 1, data: { id: pendingId, goal_type: "nutrition", name: "Older server copy", starts_on: "2026-08-01", status: "draft" } },
            { entity_type: "goal", entity_id: serverOnlyId, revision: 3, data: { id: serverOnlyId, goal_type: "general", name: "Server only", starts_on: "2026-07-01", status: "active" } },
          ],
          redirects: [],
          next_cursor: 42,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      syncBodies.push(body);
      const mutations = body.mutations as Array<{ mutation_id: string; entity_id: string }>;
      if (syncBodies.length === 1) {
        const accepted = mutations.find((mutation) => mutation.entity_id === acceptedId)!;
        const pending = mutations.find((mutation) => mutation.entity_id === pendingId)!;
        return new Response(JSON.stringify(syncResponse({
          status: "full_snapshot_required",
          accepted: [{ mutation_id: accepted.mutation_id, entity_id: acceptedId, revision: 4 }],
          acked_mutation_ids: [accepted.mutation_id],
          rejected_mutations: [{ mutation_id: pending.mutation_id, code: "conflict", message: "Review the pending goal." }],
          next_cursor: 999,
          snapshot_url: "/api/fitness/sync/snapshot",
        })), { status: 200, headers: { "content-type": "application/json" } });
      }
      return new Response(JSON.stringify(syncResponse({
        accepted: mutations.map((mutation) => ({ mutation_id: mutation.mutation_id, entity_id: mutation.entity_id, revision: 5 })),
        acked_mutation_ids: mutations.map((mutation) => mutation.mutation_id),
        next_cursor: 43,
      })), { status: 200, headers: { "content-type": "application/json" } });
    }));
    setOnline(true);

    await flushFitnessSync();

    expect(await cachedFitnessRecords("goal")).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: acceptedId, name: "Accepted canonical", revision: 4 }),
      expect.objectContaining({ id: pendingId, name: "Still pending locally" }),
      expect.objectContaining({ id: serverOnlyId, name: "Server only", revision: 3 }),
    ]));
    expect(await cachedFitnessRecords("goal")).not.toEqual(expect.arrayContaining([expect.objectContaining({ id: staleId })]));
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 1, failed: 1 });

    await flushFitnessSync();
    expect(syncBodies[1]).toMatchObject({ cursor: 42 });
    expect(syncBodies[1]?.mutations).toEqual([expect.objectContaining({ entity_id: pendingId })]);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });
  });

  it("keeps the local FIT until the server explicitly acknowledges source retention", async () => {
    let uploadCount = 0;
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const isUpload = String(input).endsWith("/fitness/imports/fit") && init?.method === "POST";
      if (isUpload) uploadCount += 1;
      const retained = isUpload && uploadCount === 2;
      return new Response(JSON.stringify({
        id: crypto.randomUUID(),
        status: "complete",
        activity_id: crypto.randomUUID(),
        file_name: "run.fit",
        error: null,
        retryable: false,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        source_retained: retained,
        source_record_id: retained ? "00000000-0000-4000-8000-000000000991" : null,
      }), { status: 200, headers: { "content-type": "application/json" } });
    }));

    await queueFitnessFitImport(new File([new Uint8Array([1, 2, 3])], "first.fit"));
    setOnline(true);
    await flushFitnessFitImports();
    expect(await fitnessPendingImports()).toEqual([
      expect.objectContaining({ status: "complete", sourceRetained: false, hasLocalFile: true }),
    ]);

    setOnline(false);
    await queueFitnessFitImport(new File([new Uint8Array([4, 5, 6])], "second.fit"));
    setOnline(true);
    await flushFitnessFitImports();
    expect(await fitnessPendingImports()).toEqual(expect.arrayContaining([
      expect.objectContaining({ fileName: "second.fit", sourceRetained: true, hasLocalFile: false }),
      expect.objectContaining({ fileName: "first.fit", sourceRetained: false, hasLocalFile: true }),
    ]));
  });

  it("replays a private planned-meal log through its exact endpoint and scopes meals and Undo to the owner", async () => {
    const meal = {
      meal_plan_id: "meal-plan-1",
      date: "2026-08-03",
      meal_type: "dinner" as const,
      meal_id: "meal-1",
      meal_name: "Family pasta night",
      link_id: "link-1",
      recipe_id: "recipe-1",
      recipe_version_id: "recipe-version-1",
      recipe_name: "Tomato pasta",
      suggested_portion: 1,
      suggested_unit: "serving" as const,
    };
    await cacheFitnessPlannedMeals(meal.date, [meal]);
    const local = await saveFitnessPlannedMealLog({
      id: "planned-log-1",
      meal,
      portion: 1.5,
      unit: "serving",
      loggedAtUtc: "2026-08-03T17:00:00Z",
      localTimezone: "Europe/Berlin",
    });
    await rememberFitnessLogUndo({
      nutritionDate: meal.date,
      label: meal.recipe_name,
      highlight: "30 g protein",
      records: [{ id: local.id }],
      createdAt: "2026-08-03T17:00:01Z",
    });
    expect(local).toMatchObject({
      id: "planned-log-1",
      source_meal_plan_id: "meal-plan-1",
      household_meal_link_id: "link-1",
      entered_amount: 1.5,
      queued_offline: true,
    });
    expect(await cachedFitnessPlannedMeals(meal.date)).toEqual([meal]);
    expect(await fitnessLogUndo()).toMatchObject({
      highlight: "30 g protein",
      records: [{ id: "planned-log-1" }],
    });
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });

    setOfflineQueueOwner({ id: "kat", family_id: "family-a" });
    expect(await cachedFitnessPlannedMeals(meal.date)).toEqual([]);
    expect(await fitnessLogUndo()).toBeNull();
    setOfflineQueueOwner(owner);

    const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      expect(String(input)).toMatch(/\/fitness\/planned-meals\/meal-plan-1\/log$/);
      expect(init?.method).toBe("POST");
      expect(JSON.parse(String(init?.body))).toMatchObject({ id: "planned-log-1", portion: 1.5, unit: "serving" });
      return new Response(JSON.stringify({
        id: "planned-log-1",
        source_meal_plan_id: "meal-plan-1",
        household_meal_link_id: "link-1",
        recipe_version_id: "recipe-version-1",
        nutrition_date: meal.date,
        meal_type: "dinner",
        logged_at_utc: "2026-08-03T17:00:00Z",
        portion: 1.5,
        unit: "serving",
      }), { status: 200, headers: { "content-type": "application/json" } });
    });
    vi.stubGlobal("fetch", fetchMock);
    setOnline(true);
    await flushFitnessPlannedMealLogs();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes("/fitness/sync"))).toBe(false);
    expect(await removeFitnessPlannedMealLogFromDevice("planned-log-1")).toBe(false);
  });

  it("removes an unsubmitted planned-meal log locally so Undo does not replay it", async () => {
    const meal = {
      meal_plan_id: "meal-plan-2", date: "2026-08-03", meal_type: "dinner" as const,
      meal_id: "meal-2", meal_name: "Family curry", link_id: "link-2",
      recipe_id: "recipe-2", recipe_version_id: "recipe-version-2", recipe_name: "Curry",
      suggested_portion: 1, suggested_unit: "serving" as const,
    };
    const local = await saveFitnessPlannedMealLog({ meal, portion: 1, unit: "serving", loggedAtUtc: "2026-08-03T18:00:00Z", localTimezone: "Europe/Berlin" });
    expect(await removeFitnessPlannedMealLogFromDevice(local.id)).toBe(true);
    expect(await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry")).toEqual([]);
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);
    setOnline(true);
    expect(await flushFitnessPlannedMealLogs()).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("purges only the explicitly deleted owner and preserves another owner's cache", async () => {
    await saveFitnessRecord("goal", {
      goal_type: "running_consistency",
      metric_key: "running.sessions_weekly",
      name: "Owner A",
      starts_on: "2026-08-02",
      status: "active",
    });
    setOfflineQueueOwner({ id: "kat", family_id: "family-a" });
    await saveFitnessRecord("goal", {
      goal_type: "running_consistency",
      metric_key: "running.sessions_weekly",
      name: "Owner B",
      starts_on: "2026-08-02",
      status: "active",
    });
    setOfflineQueueOwner(owner);
    await purgeCurrentFitnessOwnerData();
    expect(await cachedFitnessRecords("goal")).toEqual([]);
    setOfflineQueueOwner({ id: "kat", family_id: "family-a" });
    expect(await cachedFitnessRecords("goal")).toEqual([
      expect.objectContaining({ name: "Owner B" }),
    ]);
  });
});
