import {
  AlertTriangle,
  Camera,
  CheckCircle2,
  ChevronRight,
  CircleOff,
  Flame,
  Gauge,
  Home as HomeIcon,
  Lightbulb,
  Minus,
  Music2,
  Pause,
  Play,
  Plus,
  Power,
  RefreshCw,
  Settings2,
  ShieldCheck,
  Star,
  Thermometer,
  ToggleLeft,
  ToggleRight,
} from "lucide-react";
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";

import { api } from "../api";
import { HomeFloorPlan, type HomeFloorPlanLayout } from "../components/HomeFloorPlan";
import {
  ConfirmDialog,
  EmptyState,
  ErrorState,
  IconButton,
  Modal,
  SkeletonList,
  cn,
} from "../components/ui";
import "./home.css";

type HomeEntity = {
  entity_id: string;
  name: string;
  domain: string;
  state: string;
  device_class?: string | null;
  unit_of_measurement?: string | null;
  current_temperature?: number | null;
  temperature?: number | null;
  hvac_action?: string | null;
  brightness?: number | null;
  media_title?: string | null;
  media_artist?: string | null;
  volume_level?: number | null;
  operation_mode?: string | null;
  operation_list?: string[] | null;
  min_temp?: number | null;
  max_temp?: number | null;
};

type HomeControlKind = "camera" | "climate" | "light" | "media" | "mode" | "scene" | "sensor" | "switch";
type HomeCapability = "activate" | "play_pause" | "select_option" | "set_temperature" | "toggle" | "turn_off" | "turn_on" | "view";

type HomeManifestEntity = {
  entity_id: string;
  name: string;
  domain: string;
  room_id: string | null;
  room_name: string | null;
  control_kind: HomeControlKind;
  capabilities: HomeCapability[];
  favourite: boolean;
  advanced: boolean;
};

type HomeManifestRoom = {
  id: string;
  name: string;
  floor: number;
  entity_ids: string[];
  light_entity_ids: string[];
};

type HomeManifest = {
  rooms: HomeManifestRoom[];
  entities: HomeManifestEntity[];
  favourite_entity_ids: string[];
  mode_selector: { entity_id: string; name: string; current: string; options: string[] } | null;
  broad_action_scopes: Array<"favourites" | "room" | "all">;
  advanced_features: string[];
};

type HomeException = {
  id: string;
  severity: "attention" | "urgent";
  title: string;
  detail: string;
  entity_id: string | null;
  room_id: string | null;
};

type HomeSitrep = {
  tone: "calm" | "attention";
  headline: string;
  summary: string;
  exceptions: HomeException[];
  updated_at: string;
};

type HomeSnapshot = {
  configured: boolean;
  available: boolean;
  entities: HomeEntity[];
  manifest?: HomeManifest | null;
  sitrep?: HomeSitrep | null;
};

type HomeTemperatureHistoryPoint = {
  recorded_at: string;
  temperature: number;
  target_temperature?: number | null;
  heating: boolean;
};

type HomeTemperatureHistory = {
  entity_id: string;
  unit?: string | null;
  hours: 24;
  points: HomeTemperatureHistoryPoint[];
};

type RoomTemperature = {
  id: string;
  name: string;
  value: number | null;
  dewPoint: number | null;
  temperatureEntityID: string | null;
  climateProfile: HomeManifestEntity | null;
  targetTemperature: number | null;
  minimumTemperature: number;
  maximumTemperature: number;
  isHeating: boolean;
};

type ActionName = "turn_on" | "turn_off" | "toggle" | "play_pause" | "set_temperature";
type BroadAction = "lights_on" | "lights_off";
type BroadScope = "favourites" | "room" | "all";

function statusName(state: string): string {
  return state.replaceAll("_", " ").replace(/^./, (letter) => letter.toUpperCase());
}

function entitySummary(profile: HomeManifestEntity, entity: HomeEntity | undefined): string {
  if (!entity) return "State unavailable";
  if (profile.control_kind === "climate") {
    const current = entity.current_temperature == null ? null : `${entity.current_temperature.toFixed(1)}° now`;
    const heating = entity.hvac_action === "heating" ? "Heating" : statusName(entity.hvac_action ?? entity.state);
    return [current, heating].filter(Boolean).join(" · ");
  }
  if (profile.control_kind === "media") {
    return entity.media_title
      ? `${entity.media_title}${entity.media_artist ? ` · ${entity.media_artist}` : ""}`
      : statusName(entity.state);
  }
  if (profile.control_kind === "sensor" && entity.unit_of_measurement) {
    return `${entity.state} ${entity.unit_of_measurement}`;
  }
  return statusName(entity.state);
}

function scopeLabel(scope: BroadScope, roomName?: string): string {
  if (scope === "favourites") return "favourite lights";
  if (scope === "room") return roomName ? `${roomName} lights` : "one room";
  return "every controllable light";
}

function isBroadControllableLight(profile: HomeManifestEntity): boolean {
  return profile.control_kind === "light"
    && (profile.capabilities.includes("turn_on") || profile.capabilities.includes("turn_off"));
}

function isProminentClimateReading(
  profile: HomeManifestEntity,
  entity: HomeEntity | undefined,
): boolean {
  if (profile.advanced) return false;
  if (profile.control_kind === "climate") return true;
  const words = `${profile.entity_id} ${profile.name} ${profile.room_id ?? ""} ${profile.room_name ?? ""}`.toLowerCase();
  const temperature = entity?.device_class === "temperature"
    || ["°c", "°f"].includes((entity?.unit_of_measurement ?? "").toLowerCase())
    || words.includes("temperature");
  const bathroom = words.includes("bathroom") || words.includes("bath_room");
  const bathroomAir = bathroom && (
    entity?.device_class === "humidity"
    || words.includes("humidity")
    || words.includes("dew point")
    || words.includes("dew_point")
    || words.includes("dewpoint")
  );
  return temperature || bathroomAir;
}

function measuredTemperature(entity: HomeEntity | undefined): number | null {
  if (!entity) return null;
  if (entity.current_temperature != null) return entity.current_temperature;

  const words = `${entity.entity_id} ${entity.name}`.toLowerCase();
  if (["dew", "target", "setpoint", "apparent", "feels like"].some((word) => words.includes(word))) {
    return null;
  }
  const unit = (entity.unit_of_measurement ?? "").toLowerCase();
  if (entity.device_class !== "temperature" && unit !== "°c" && unit !== "°f") return null;
  const reading = Number(entity.state);
  return Number.isFinite(reading) ? reading : null;
}

function measuredDewPoint(entity: HomeEntity | undefined): number | null {
  if (!entity) return null;
  const words = `${entity.entity_id} ${entity.name}`.toLowerCase();
  if (!["dew point", "dew_point", "dewpoint"].some((word) => words.includes(word))) return null;
  const unit = (entity.unit_of_measurement ?? "").toLowerCase();
  if (entity.device_class !== "temperature" && unit !== "°c" && unit !== "°f") return null;
  const reading = Number(entity.state);
  return Number.isFinite(reading) ? reading : null;
}

export function HomeView({ revision, notify }: { revision: number; notify: (message: string) => void }) {
  const [snapshot, setSnapshot] = useState<HomeSnapshot | null>(null);
  const [layout, setLayout] = useState<HomeFloorPlanLayout | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [layoutError, setLayoutError] = useState<string | null>(null);
  const [layoutLoading, setLayoutLoading] = useState(false);
  const [working, setWorking] = useState<string | null>(null);
  const [favouritesOpen, setFavouritesOpen] = useState(false);
  const [favouriteDraft, setFavouriteDraft] = useState<string[]>([]);
  const [broadOpen, setBroadOpen] = useState(false);
  const [broadAction, setBroadAction] = useState<BroadAction>("lights_off");
  const [broadScope, setBroadScope] = useState<BroadScope>("favourites");
  const [broadRoomID, setBroadRoomID] = useState("");
  const [confirmBroad, setConfirmBroad] = useState(false);
  const [modeOpen, setModeOpen] = useState(false);
  const [selectedMode, setSelectedMode] = useState("");
  const [confirmMode, setConfirmMode] = useState(false);
  const [pendingScene, setPendingScene] = useState<HomeManifestEntity | null>(null);
  const [selectedTemperatureRoomID, setSelectedTemperatureRoomID] = useState<string | null>(null);

  const load = useCallback(async (background = false) => {
    if (!background) setLoading(true);
    setError(null);
    try {
      setSnapshot(await api<HomeSnapshot>("/home/status"));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Home Assistant is unavailable.");
    } finally {
      setLoading(false);
    }
  }, []);

  const loadLayout = useCallback(async () => {
    if (layout || layoutLoading) return;
    setLayoutLoading(true);
    setLayoutError(null);
    try {
      setLayout(await api<HomeFloorPlanLayout>("/home/layout"));
    } catch {
      setLayoutError("The private house map could not be loaded.");
    } finally {
      setLayoutLoading(false);
    }
  }, [layout, layoutLoading]);

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  const manifest = snapshot?.manifest ?? null;
  const entityByID = useMemo(
    () => new Map((snapshot?.entities ?? []).map((entity) => [entity.entity_id, entity])),
    [snapshot],
  );
  const profileByID = useMemo(
    () => new Map((manifest?.entities ?? []).map((profile) => [profile.entity_id, profile])),
    [manifest],
  );

  async function action(profile: HomeManifestEntity, actionName: ActionName, value?: number) {
    const key = `${profile.entity_id}-${actionName}`;
    setWorking(key);
    setError(null);
    try {
      await api("/home/actions", {
        method: "POST",
        body: JSON.stringify({ entity_id: profile.entity_id, action: actionName, value }),
      });
      notify(`${profile.name} updated.`);
      await load(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The house action could not be completed.");
    } finally {
      setWorking(null);
    }
  }

  async function setRoomTemperature(profile: HomeManifestEntity, value: number) {
    const key = `${profile.entity_id}-room-temperature`;
    const previousTarget = entityByID.get(profile.entity_id)?.temperature ?? null;
    setWorking(key);
    setSnapshot((current) => current ? {
      ...current,
      entities: current.entities.map((entity) => entity.entity_id === profile.entity_id
        ? { ...entity, temperature: value }
        : entity),
    } : current);
    try {
      await api("/home/actions", {
        method: "POST",
        body: JSON.stringify({ entity_id: profile.entity_id, action: "set_temperature", value }),
      });
      notify(`${profile.room_name ?? profile.name} set to ${value.toFixed(1)}°.`);
      void load(true);
    } catch (requestError) {
      setSnapshot((current) => current ? {
        ...current,
        entities: current.entities.map((entity) => entity.entity_id === profile.entity_id
          ? { ...entity, temperature: previousTarget }
          : entity),
      } : current);
      throw requestError;
    } finally {
      setWorking(null);
    }
  }

  async function boostHotWater() {
    const heater = snapshot?.entities.find((entity) => entity.domain === "water_heater");
    if (!heater) return;
    setWorking("hot-water-boost");
    setError(null);
    try {
      await api("/home/services", {
        method: "POST",
        body: JSON.stringify({
          domain: "water_heater",
          service: "set_operation_mode",
          data: { entity_id: heater.entity_id, operation_mode: "on" },
        }),
      });
      notify("Hot water boost started.");
      await load(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Hot water could not be boosted.");
    } finally {
      setWorking(null);
    }
  }

  function openFavourites() {
    setFavouriteDraft(manifest?.favourite_entity_ids ?? []);
    setFavouritesOpen(true);
  }

  function toggleFavourite(entityID: string) {
    setFavouriteDraft((current) => current.includes(entityID)
      ? current.filter((item) => item !== entityID)
      : current.length < 12 ? [...current, entityID] : current);
  }

  async function saveFavourites() {
    setWorking("favourites");
    setError(null);
    try {
      await api("/home/favourites", {
        method: "PUT",
        body: JSON.stringify({ entity_ids: favouriteDraft }),
      });
      setFavouritesOpen(false);
      notify("House favourites saved.");
      await load(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Favourites could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  function openBroadAction() {
    const controllableLights = (manifest?.entities ?? []).filter(isBroadControllableLight);
    const firstRoom = manifest?.rooms.find(
      (room) => controllableLights.some((profile) => profile.room_id === room.id),
    )?.id ?? "";
    setBroadRoomID(firstRoom);
    setBroadScope(
      controllableLights.some((profile) => profile.favourite)
        ? "favourites"
        : firstRoom
          ? "room"
          : "all",
    );
    setBroadAction("lights_off");
    setBroadOpen(true);
  }

  async function executeBroadAction() {
    setWorking("broad-action");
    setError(null);
    try {
      const response = await api<{ entity_ids: string[] }>("/home/broad-actions", {
        method: "POST",
        body: JSON.stringify({
          action: broadAction,
          scope: broadScope,
          room_id: broadScope === "room" ? broadRoomID : null,
          confirmed: true,
        }),
      });
      setConfirmBroad(false);
      notify(`${response.entity_ids.length} light${response.entity_ids.length === 1 ? "" : "s"} updated.`);
      await load(true);
    } catch (requestError) {
      setConfirmBroad(false);
      setError(requestError instanceof Error ? requestError.message : "The broad house action could not be completed.");
    } finally {
      setWorking(null);
    }
  }

  function openModePicker() {
    const selector = manifest?.mode_selector;
    if (!selector) return;
    setSelectedMode(selector.current);
    setModeOpen(true);
  }

  async function executeModeChange() {
    const selector = manifest?.mode_selector;
    if (!selector) return;
    setWorking("house-mode");
    setError(null);
    try {
      await api("/home/services", {
        method: "POST",
        body: JSON.stringify({
          domain: selector.entity_id.split(".", 1)[0],
          service: "select_option",
          data: { entity_id: selector.entity_id, option: selectedMode },
        }),
      });
      setConfirmMode(false);
      notify(`House mode changed to ${selectedMode}.`);
      await load(true);
    } catch (requestError) {
      setConfirmMode(false);
      setError(requestError instanceof Error ? requestError.message : "House mode could not be changed.");
    } finally {
      setWorking(null);
    }
  }

  const favourites = (manifest?.entities ?? []).filter(
    (profile) => profile.favourite && !profile.advanced && profile.control_kind !== "mode",
  );
  const roomGroups = (manifest?.rooms ?? []).map((room) => ({
    room,
    profiles: room.entity_ids
      .map((entityID) => profileByID.get(entityID))
      .filter((profile): profile is HomeManifestEntity => Boolean(profile && !profile.advanced && profile.control_kind !== "mode")),
  })).filter((group) => group.profiles.length > 0);
  const unassigned = (manifest?.entities ?? []).filter(
    (profile) => !profile.room_id && !profile.advanced && profile.control_kind !== "mode",
  );
  const advancedProfiles = (manifest?.entities ?? []).filter((profile) => profile.advanced);
  const selectedRoom = manifest?.rooms.find((room) => room.id === broadRoomID);
  const broadControllableLights = (manifest?.entities ?? []).filter(isBroadControllableLight);
  const broadTargetCount = broadControllableLights.filter((profile) => {
    if (broadScope === "favourites") return profile.favourite;
    if (broadScope === "room") return profile.room_id === broadRoomID;
    return true;
  }).length;
  const prominentClimate = (manifest?.entities ?? [])
    .filter((profile) => isProminentClimateReading(profile, entityByID.get(profile.entity_id)))
    .sort((left, right) => (
      (left.room_name ?? left.name).localeCompare(right.room_name ?? right.name)
      || left.name.localeCompare(right.name)
    ));
  const roomTemperatures: RoomTemperature[] = (manifest?.rooms ?? []).map((room) => {
    const roomEntities = room.entity_ids.map((entityID) => ({
      entity: entityByID.get(entityID),
      profile: profileByID.get(entityID),
    }));
    const candidates = roomEntities
      .map(({ entity, profile }) => ({
        entity,
        profile,
        value: measuredTemperature(entity),
        priority: entity?.current_temperature != null
          ? 0
          : `${entity?.entity_id ?? ""} ${entity?.name ?? ""}`.toLowerCase().includes("temperature")
            ? 1
            : 2,
      }))
      .filter((candidate) => candidate.value != null)
      .sort((left, right) => left.priority - right.priority || (left.profile?.name ?? "").localeCompare(right.profile?.name ?? ""));
    const roomWords = `${room.id} ${room.name}`.toLowerCase();
    const dewPoint = (roomWords.includes("bathroom") || roomWords.includes("bath_room"))
      ? roomEntities.map(({ entity }) => measuredDewPoint(entity)).find((value) => value != null) ?? null
      : null;
    const climateProfile = roomEntities
      .map(({ profile }) => profile)
      .find((profile) => profile?.control_kind === "climate" && profile.capabilities.includes("set_temperature")) ?? null;
    const climateEntity = climateProfile ? entityByID.get(climateProfile.entity_id) : undefined;
    return {
      id: room.id,
      name: room.name,
      value: candidates[0]?.value ?? null,
      dewPoint,
      temperatureEntityID: candidates[0]?.entity?.entity_id ?? null,
      climateProfile,
      targetTemperature: climateEntity?.temperature ?? null,
      minimumTemperature: climateEntity?.min_temp ?? 5,
      maximumTemperature: climateEntity?.max_temp ?? 30,
      isHeating: roomEntities.some(({ entity }) => entity?.hvac_action === "heating"),
    };
  });
  const selectedTemperatureRoom = roomTemperatures.find(
    (room) => room.id === selectedTemperatureRoomID,
  ) ?? null;
  const hotWaterHeater = snapshot?.entities.find((entity) => entity.domain === "water_heater");
  const hotWaterBoostActive = snapshot?.entities.some((entity) => (
    entity.entity_id === "binary_sensor.example_e5ed4cd5" && entity.state === "on"
  )) || hotWaterHeater?.state === "on" || hotWaterHeater?.operation_mode === "on";

  return (
    <div className="standard-page home-page home-command-page">
      <header className="page-header home-header">
        <div><p className="page-eyebrow">What needs attention now</p><h1>House</h1></div>
        <IconButton label="Refresh house" icon={RefreshCw} disabled={loading} onClick={() => void load()} />
      </header>

      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <div className="home-command-skeleton"><SkeletonList rows={4} /></div> : null}
      {!loading && snapshot && !snapshot.configured ? (
        <EmptyState title="Home Assistant is not configured" detail="An admin can connect it from HausKlar settings." />
      ) : null}
      {!loading && snapshot?.configured && !snapshot.available ? (
        <ErrorState message="HausKlar cannot reach Home Assistant from the server right now. No sample state has been substituted." retry={load} />
      ) : null}

      {!loading && snapshot?.available && !manifest ? (
        <ErrorState message="House controls aren’t available right now. Try again in a moment." retry={load} />
      ) : null}

      {!loading && snapshot?.available && manifest ? (
        <>
          {snapshot.sitrep ? <SitrepCard sitrep={snapshot.sitrep} /> : null}

          <section className="home-glance" aria-labelledby="home-room-temperatures-title">
            <header>
              <Thermometer aria-hidden="true" size={20} />
              <h2 id="home-room-temperatures-title">Room temperatures</h2>
            </header>
            <div className="home-temperature-list">
              {roomTemperatures.length ? roomTemperatures.map((room) => (
                  <button
                    type="button"
                    className={cn("home-temperature-reading", room.isHeating && "is-heating")}
                    key={room.id}
                    disabled={room.value == null || !room.temperatureEntityID}
                    aria-label={`${room.name}, ${room.value == null ? "temperature unavailable" : `${room.value.toFixed(1)} degrees`}${room.dewPoint == null ? "" : `, dew point ${room.dewPoint.toFixed(1)} degrees`}${room.isHeating ? ", heating" : ""}`}
                    onClick={() => setSelectedTemperatureRoomID(room.id)}
                  >
                    <span className="home-temperature-name">{room.name}</span>
                    <span className="home-temperature-values">
                      <strong>{room.value == null ? "—" : `${room.value.toFixed(1)}°`}</strong>
                      {room.dewPoint == null ? null : (
                        <small aria-label={`Dew point ${room.dewPoint.toFixed(1)} degrees`}>
                          Dew {room.dewPoint.toFixed(1)}°
                        </small>
                      )}
                    </span>
                  </button>
                )) : <p className="home-temperature-empty">No room temperatures available.</p>}
            </div>
            <button
              type="button"
              className={cn("home-hot-water-boost", hotWaterBoostActive && "is-active")}
              aria-busy={working === "hot-water-boost"}
              disabled={!hotWaterHeater || Boolean(working) || hotWaterBoostActive}
              onClick={() => void boostHotWater()}
            >
              <Flame aria-hidden="true" size={19} />
              {working === "hot-water-boost"
                ? "Boosting…"
                : hotWaterBoostActive
                  ? "Hot water boost active"
                  : hotWaterHeater
                    ? "Boost hot water"
                    : "Hot water unavailable"}
            </button>
          </section>

          <details className="home-full-controls">
            <summary><span><Settings2 aria-hidden="true" size={20} />Full controls</span><ChevronRight aria-hidden="true" size={18} /></summary>
            <div className="home-full-controls-content">
              {prominentClimate.length ? (
                <section className="home-command-section" aria-labelledby="home-climate-title">
                  <header><div><p className="home-command-kicker">Heating &amp; air</p><h2 id="home-climate-title">Temperatures &amp; bathroom air</h2></div></header>
                  <div className="home-favourite-grid">
                    {prominentClimate.map((profile) => (
                      <HomeControl
                        key={profile.entity_id}
                        profile={profile}
                        entity={entityByID.get(profile.entity_id)}
                        busy={Boolean(working)}
                        onAction={action}
                        onScene={() => setPendingScene(profile)}
                      />
                    ))}
                  </div>
                </section>
              ) : null}

              <section className="home-command-section" aria-labelledby="home-favourites-title">
                <header>
                  <div><p className="home-command-kicker">One tap</p><h2 id="home-favourites-title">Favourites</h2></div>
                  <button type="button" className="button button--secondary button--compact" onClick={openFavourites}>
                    <Star aria-hidden="true" size={16} /> Manage
                  </button>
                </header>
                {favourites.length ? (
                  <div className="home-favourite-grid">
                    {favourites.map((profile) => (
                      <HomeControl
                        key={profile.entity_id}
                        profile={profile}
                        entity={entityByID.get(profile.entity_id)}
                        busy={Boolean(working)}
                        onAction={action}
                        onScene={() => setPendingScene(profile)}
                      />
                    ))}
                  </div>
                ) : (
                  <EmptyState title="No favourites yet" detail="Choose the controls you reach for most. HausKlar will keep them here." action={openFavourites} actionLabel="Choose favourites" />
                )}
              </section>

              <section className="home-command-section home-intentions" aria-labelledby="home-intentions-title">
                <header><div><p className="home-command-kicker">Deliberate controls</p><h2 id="home-intentions-title">House state</h2></div></header>
                <div className="home-intention-grid">
                  {manifest.mode_selector ? (
                    <button type="button" className="home-intention-card" aria-label={`Change ${manifest.mode_selector.name} from ${manifest.mode_selector.current}`} onClick={openModePicker}>
                      <HomeIcon aria-hidden="true" size={21} />
                      <span><small>{manifest.mode_selector.name}</small><strong>{manifest.mode_selector.current}</strong></span>
                      <ChevronRight aria-hidden="true" size={18} />
                    </button>
                  ) : null}
                  <button type="button" className="home-intention-card" aria-label="Control several lights" onClick={openBroadAction}>
                    <Lightbulb aria-hidden="true" size={21} />
                    <span><small>Several lights</small><strong>Choose scope and action</strong></span>
                    <ChevronRight aria-hidden="true" size={18} />
                  </button>
                </div>
              </section>

              <section className="home-command-section" aria-labelledby="home-rooms-title">
                <header><div><p className="home-command-kicker">By place</p><h2 id="home-rooms-title">Rooms</h2></div></header>
                <div className="home-room-grid">
                  {roomGroups.map(({ room, profiles }) => (
                    <RoomControls room={room} profiles={profiles} entityByID={entityByID} busy={Boolean(working)} onAction={action} onScene={setPendingScene} key={room.id} />
                  ))}
                  {unassigned.length ? (
                    <RoomControls room={{ id: "elsewhere", name: "Elsewhere", floor: -1, entity_ids: [], light_entity_ids: [] }} profiles={unassigned} entityByID={entityByID} busy={Boolean(working)} onAction={action} onScene={setPendingScene} />
                  ) : null}
                </div>
              </section>

              <details
                className="home-advanced"
                onToggle={(event) => {
                  if (event.currentTarget.open) void loadLayout();
                }}
              >
                <summary>
                  <span><Settings2 aria-hidden="true" size={20} /><span><strong>Advanced</strong><small>Floor plan, cameras, mesh and diagnostics</small></span></span>
                  <ChevronRight aria-hidden="true" size={18} />
                </summary>
                <div className="home-advanced-content">
                  <section aria-labelledby="home-floor-plan-title">
                    <header><h2 id="home-floor-plan-title">Floor plan</h2><p>Private floor geometry and room controls.</p></header>
                    {layout ? (
                      <HomeFloorPlan entities={snapshot.entities} layout={layout} busy={Boolean(working)} onToggle={(entity) => {
                        const profile = profileByID.get(entity.entity_id);
                        if (profile) void action(profile, "toggle");
                      }} />
                    ) : layoutError ? <ErrorState message={layoutError} retry={() => void loadLayout()} /> : <SkeletonList rows={4} />}
                  </section>
                  <section aria-labelledby="home-diagnostics-title">
                    <header><h2 id="home-diagnostics-title">Devices and diagnostics</h2><p>{advancedProfiles.length} advanced signal{advancedProfiles.length === 1 ? "" : "s"} exposed by the server manifest.</p></header>
                    {advancedProfiles.length ? <div className="home-diagnostic-list">{advancedProfiles.map((profile) => {
                      const entity = entityByID.get(profile.entity_id);
                      return <div key={profile.entity_id}>{profile.control_kind === "camera" ? <Camera aria-hidden="true" size={18} /> : <Gauge aria-hidden="true" size={18} />}<span><strong>{profile.name}</strong><small>{entitySummary(profile, entity)}</small></span></div>;
                    })}</div> : <p className="home-advanced-empty"><CircleOff aria-hidden="true" size={18} /> No camera or mesh diagnostics are available.</p>}
                  </section>
                </div>
              </details>
            </div>
          </details>
        </>
      ) : null}

      <Modal open={favouritesOpen} onOpenChange={setFavouritesOpen} title="Choose House favourites" description="Keep up to 12 everyday controls at the top. This list is shared for the family.">
        <div className="home-favourite-picker">
          {(manifest?.entities ?? []).filter((profile) => !profile.advanced && profile.control_kind !== "mode").map((profile) => {
            const checked = favouriteDraft.includes(profile.entity_id);
            return <label key={profile.entity_id}><input type="checkbox" checked={checked} disabled={!checked && favouriteDraft.length >= 12} onChange={() => toggleFavourite(profile.entity_id)} /><span><strong>{profile.name}</strong><small>{profile.room_name ?? statusName(profile.control_kind)}</small></span><Star aria-hidden="true" size={17} fill={checked ? "currentColor" : "none"} /></label>;
          })}
        </div>
        <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "favourites"} onClick={() => setFavouritesOpen(false)}>Cancel</button><button type="button" className="button button--primary" aria-busy={working === "favourites"} disabled={working === "favourites"} onClick={() => void saveFavourites()}>{working === "favourites" ? "Saving…" : `Save ${favouriteDraft.length} favourite${favouriteDraft.length === 1 ? "" : "s"}`}</button></div>
      </Modal>

      <Modal open={broadOpen} onOpenChange={setBroadOpen} title="Control several lights" description="Choose the exact action and its reach. Nothing runs from this screen.">
        <form className="home-broad-form" onSubmit={(event) => { event.preventDefault(); setBroadOpen(false); setConfirmBroad(true); }}>
          <fieldset><legend>Action</legend><label><input type="radio" name="broad-action" checked={broadAction === "lights_off"} onChange={() => setBroadAction("lights_off")} /><span><strong>Turn lights off</strong><small>Leave other devices unchanged.</small></span></label><label><input type="radio" name="broad-action" checked={broadAction === "lights_on"} onChange={() => setBroadAction("lights_on")} /><span><strong>Turn lights on</strong><small>Keep current brightness where Home Assistant can.</small></span></label></fieldset>
          <fieldset><legend>Where</legend>{(manifest?.broad_action_scopes ?? []).map((scope) => <label key={scope}><input type="radio" name="broad-scope" checked={broadScope === scope} onChange={() => setBroadScope(scope)} /><span><strong>{scope === "favourites" ? "Favourite lights" : scope === "room" ? "One room" : "All controllable lights"}</strong><small>{scope === "all" ? "The broadest option; you will confirm next." : scope === "room" ? "Choose one room below." : "Only starred lights."}</small></span></label>)}</fieldset>
          {broadScope === "room" ? <div className="field"><label htmlFor="home-broad-room">Room</label><select id="home-broad-room" value={broadRoomID} required onChange={(event) => setBroadRoomID(event.target.value)}>{(manifest?.rooms ?? []).filter((room) => broadControllableLights.some((profile) => profile.room_id === room.id)).map((room) => <option key={room.id} value={room.id}>{room.name}</option>)}</select></div> : null}
          <p className="home-broad-count" role="status">{broadTargetCount} light{broadTargetCount === 1 ? "" : "s"} match this scope.</p>
          <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setBroadOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={broadTargetCount === 0}>Review action</button></div>
        </form>
      </Modal>

      <ConfirmDialog open={confirmBroad} onOpenChange={setConfirmBroad} title={broadAction === "lights_off" ? "Turn these lights off?" : "Turn these lights on?"} description={`This will ${broadAction === "lights_off" ? "turn off" : "turn on"} ${scopeLabel(broadScope, selectedRoom?.name)} (${broadTargetCount} light${broadTargetCount === 1 ? "" : "s"}). No other devices will change.`} confirmLabel={broadAction === "lights_off" ? "Turn lights off" : "Turn lights on"} busy={working === "broad-action"} onConfirm={() => void executeBroadAction()} />

      <Modal open={modeOpen} onOpenChange={setModeOpen} title="Choose house mode" description="Select the mode deliberately. You will review it before anything changes.">
        <form className="home-mode-form" onSubmit={(event) => { event.preventDefault(); setModeOpen(false); setConfirmMode(true); }}><fieldset><legend>Mode</legend>{manifest?.mode_selector?.options.map((option) => <label key={option}><input type="radio" name="house-mode" checked={selectedMode === option} onChange={() => setSelectedMode(option)} /><span><strong>{option}</strong>{option === manifest.mode_selector?.current ? <small>Current mode</small> : null}</span></label>)}</fieldset><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setModeOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={!selectedMode || selectedMode === manifest?.mode_selector?.current}>Review change</button></div></form>
      </Modal>

      <ConfirmDialog open={confirmMode} onOpenChange={setConfirmMode} title={`Change house mode to ${selectedMode}?`} description={`Home Assistant may run automations attached to ${selectedMode}. HausKlar will send only this exact mode selection.`} confirmLabel={`Use ${selectedMode}`} busy={working === "house-mode"} onConfirm={() => void executeModeChange()} />

      <ConfirmDialog open={Boolean(pendingScene)} onOpenChange={(open) => { if (!open) setPendingScene(null); }} title={`Run ${pendingScene?.name ?? "this scene"}?`} description="Scenes can change several devices. HausKlar will run only this explicitly approved Home Assistant scene." confirmLabel="Run scene" busy={working === "scene"} onConfirm={() => { if (!pendingScene) return; const scene = pendingScene; setWorking("scene"); void api("/home/services", { method: "POST", body: JSON.stringify({ domain: scene.domain, service: "turn_on", data: { entity_id: scene.entity_id } }) }).then(async () => { setPendingScene(null); notify(`${scene.name} ran.`); await load(true); }).catch((requestError: unknown) => { setPendingScene(null); setError(requestError instanceof Error ? requestError.message : "The scene could not be run."); }).finally(() => setWorking(null)); }} />

      {selectedTemperatureRoom ? (
        <Modal
          open
          onOpenChange={(open) => { if (!open) setSelectedTemperatureRoomID(null); }}
          title={selectedTemperatureRoom.name}
          description={selectedTemperatureRoom.isHeating ? "Heating now" : "Room temperature"}
          size="wide"
        >
          <RoomTemperatureDetail
            room={selectedTemperatureRoom}
            saving={working === `${selectedTemperatureRoom.climateProfile?.entity_id}-room-temperature`}
            onSetTemperature={setRoomTemperature}
          />
        </Modal>
      ) : null}
    </div>
  );
}

function RoomTemperatureDetail({
  room,
  saving,
  onSetTemperature,
}: {
  room: RoomTemperature;
  saving: boolean;
  onSetTemperature: (profile: HomeManifestEntity, value: number) => Promise<void>;
}) {
  const [history, setHistory] = useState<HomeTemperatureHistory | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [historyRevision, setHistoryRevision] = useState(0);
  const [controlError, setControlError] = useState<string | null>(null);

  useEffect(() => {
    if (!room.temperatureEntityID) return;
    const controller = new AbortController();
    setHistory(null);
    setHistoryError(null);
    void api<HomeTemperatureHistory>(
      `/home/temperature-history/${encodeURIComponent(room.temperatureEntityID)}`,
      { signal: controller.signal },
    ).then((loaded) => {
      if (!controller.signal.aborted) setHistory(loaded);
    }).catch((requestError: unknown) => {
      if (controller.signal.aborted) return;
      setHistoryError(requestError instanceof Error ? requestError.message : "Temperature history could not be loaded.");
    });
    return () => controller.abort();
  }, [historyRevision, room.temperatureEntityID]);

  const target = room.targetTemperature
    ?? Math.round((room.value ?? 20) * 2) / 2;

  async function adjustTarget(delta: number) {
    if (!room.climateProfile) return;
    const next = Math.max(
      room.minimumTemperature,
      Math.min(room.maximumTemperature, target + delta),
    );
    setControlError(null);
    try {
      await onSetTemperature(room.climateProfile, next);
    } catch (requestError) {
      setControlError(requestError instanceof Error ? requestError.message : "Temperature could not be changed.");
    }
  }

  return (
    <div className="home-temperature-detail">
      <div className={cn("home-temperature-now", room.isHeating && "is-heating")}>
        <Thermometer aria-hidden="true" size={24} />
        <span><small>Now</small><strong>{room.value == null ? "—" : `${room.value.toFixed(1)}°`}</strong></span>
        {room.dewPoint == null ? null : <span><small>Dew point</small><strong>{room.dewPoint.toFixed(1)}°</strong></span>}
      </div>

      <section className="home-temperature-history" aria-label="Temperature over the last 24 hours">
        {historyError ? (
          <div className="home-temperature-history-state" role="alert">
            <span>Couldn’t load the graph.</span>
            <button type="button" className="button button--secondary button--compact" onClick={() => setHistoryRevision((value) => value + 1)}>Try again</button>
          </div>
        ) : !history ? (
          <div className="home-temperature-history-skeleton" role="status" aria-busy="true" aria-label="Loading temperature graph"><span /><span /><span /></div>
        ) : history.points.length ? (
          <TemperatureHistoryChart points={history.points} isHeating={room.isHeating} />
        ) : (
          <p className="home-temperature-history-state">No recent readings.</p>
        )}
      </section>

      {room.climateProfile ? (
        <section className="home-room-target" aria-labelledby={`home-room-target-${room.id}`}>
          <div><span id={`home-room-target-${room.id}`}>Target</span><strong>{target.toFixed(1)}°</strong></div>
          <div className="home-room-target-stepper" role="group" aria-label={`${room.name} target temperature`}>
            <button type="button" aria-label={`Lower ${room.name} target temperature`} disabled={saving || target <= room.minimumTemperature} onClick={() => void adjustTarget(-0.5)}><Minus aria-hidden="true" size={19} /></button>
            <button type="button" aria-label={`Raise ${room.name} target temperature`} disabled={saving || target >= room.maximumTemperature} onClick={() => void adjustTarget(0.5)}><Plus aria-hidden="true" size={19} /></button>
          </div>
          <p role="status" aria-live="polite">{saving ? "Setting…" : controlError ?? ""}</p>
        </section>
      ) : null}
    </div>
  );
}

function TemperatureHistoryChart({
  points,
  isHeating,
}: {
  points: HomeTemperatureHistoryPoint[];
  isHeating: boolean;
}) {
  const gradientID = `home-temperature-${useId().replaceAll(":", "")}`;
  const width = 620;
  const height = 190;
  const insetX = 12;
  const insetY = 16;
  const temperatures = points.map((point) => point.temperature);
  const rawMinimum = Math.min(...temperatures);
  const rawMaximum = Math.max(...temperatures);
  const padding = Math.max(0.5, (rawMaximum - rawMinimum) * 0.15);
  const minimum = rawMinimum - padding;
  const maximum = rawMaximum + padding;
  const range = Math.max(1, maximum - minimum);
  const firstTime = Date.parse(points[0].recorded_at);
  const lastTime = Date.parse(points.at(-1)!.recorded_at);
  const timeRange = Math.max(1, lastTime - firstTime);
  const plotted = points.map((point) => ({
    x: insetX + (Date.parse(point.recorded_at) - firstTime) / timeRange * (width - insetX * 2),
    y: insetY + (maximum - point.temperature) / range * (height - insetY * 2),
  }));
  const line = plotted.map((point, index) => `${index ? "L" : "M"}${point.x.toFixed(1)} ${point.y.toFixed(1)}`).join(" ");
  const area = `${line} L${plotted.at(-1)!.x.toFixed(1)} ${height - insetY} L${plotted[0].x.toFixed(1)} ${height - insetY} Z`;
  const summary = `Temperature ranged from ${rawMinimum.toFixed(1)} to ${rawMaximum.toFixed(1)} degrees over the last 24 hours.`;

  return (
    <figure className={cn("home-temperature-chart", isHeating && "is-heating")}>
      <figcaption><span>Last 24 hours</span><strong>{rawMinimum.toFixed(1)}–{rawMaximum.toFixed(1)}°</strong></figcaption>
      <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" role="img" aria-label={summary}>
        <defs><linearGradient id={gradientID} x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="currentColor" stopOpacity="0.22" /><stop offset="1" stopColor="currentColor" stopOpacity="0" /></linearGradient></defs>
        {[0.25, 0.5, 0.75].map((ratio) => <path className="home-temperature-chart-grid" d={`M${insetX} ${height * ratio}H${width - insetX}`} key={ratio} />)}
        <path className="home-temperature-chart-area" d={area} fill={`url(#${gradientID})`} />
        <path className="home-temperature-chart-line" d={line} />
        <circle className="home-temperature-chart-last" cx={plotted.at(-1)!.x} cy={plotted.at(-1)!.y} r="4" />
      </svg>
      <div aria-hidden="true"><span>{new Date(points[0].recorded_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span><span>Now</span></div>
    </figure>
  );
}

function SitrepCard({ sitrep }: { sitrep: HomeSitrep }) {
  return (
    <section className={cn("home-sitrep", sitrep.tone === "attention" && "is-attention")} aria-labelledby="home-sitrep-title" aria-live="polite">
      <div className="home-sitrep-icon">{sitrep.tone === "calm" ? <ShieldCheck aria-hidden="true" size={25} /> : <AlertTriangle aria-hidden="true" size={25} />}</div>
      <div className="home-sitrep-copy"><p className="home-command-kicker">Now</p><h2 id="home-sitrep-title">{sitrep.headline}</h2><p>{sitrep.summary}</p></div>
      <time dateTime={sitrep.updated_at}>{new Date(sitrep.updated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
      {sitrep.exceptions.length ? <div className="home-exception-list">{sitrep.exceptions.map((item) => <article className={cn(item.severity === "urgent" && "is-urgent")} key={item.id}><AlertTriangle aria-hidden="true" size={18} /><span><strong>{item.title}</strong><small>{item.detail}</small></span></article>)}</div> : <div className="home-sitrep-clear"><CheckCircle2 aria-hidden="true" size={17} /> No exceptions to deal with.</div>}
    </section>
  );
}

function HomeControl({ profile, entity, busy, onAction, onScene }: { profile: HomeManifestEntity; entity: HomeEntity | undefined; busy: boolean; onAction: (profile: HomeManifestEntity, action: ActionName, value?: number) => Promise<void>; onScene: () => void }) {
  const isOn = entity?.state === "on";
  const target = entity?.temperature ?? 18;
  const icon = profile.control_kind === "light" ? <Lightbulb aria-hidden="true" size={20} fill={isOn ? "currentColor" : "none"} /> : profile.control_kind === "climate" ? <Thermometer aria-hidden="true" size={20} /> : profile.control_kind === "media" ? <Music2 aria-hidden="true" size={20} /> : profile.control_kind === "scene" ? <Star aria-hidden="true" size={20} /> : profile.control_kind === "switch" ? <Power aria-hidden="true" size={20} /> : <Gauge aria-hidden="true" size={20} />;
  return (
    <article className={cn("home-control", isOn && "is-on")}>
      <div className="home-control-heading"><span className="home-control-icon">{icon}</span><span><strong>{profile.name}</strong><small>{profile.room_name ?? entitySummary(profile, entity)}</small></span></div>
      {profile.room_name ? <p>{entitySummary(profile, entity)}</p> : null}
      {profile.capabilities.includes("toggle") ? <button type="button" className="home-control-action" aria-label={`${isOn ? "Turn off" : "Turn on"} ${profile.name}`} disabled={busy || !entity} onClick={() => void onAction(profile, "toggle")}>{isOn ? <ToggleRight aria-hidden="true" size={23} /> : <ToggleLeft aria-hidden="true" size={23} />}<span>{isOn ? "On" : "Off"}</span></button> : null}
      {profile.capabilities.includes("set_temperature") ? <div className="home-temperature-stepper"><button type="button" aria-label={`Lower ${profile.name} temperature`} disabled={busy || !entity} onClick={() => void onAction(profile, "set_temperature", target - 0.5)}><Minus aria-hidden="true" size={16} /></button><strong>{target.toFixed(1)}°</strong><button type="button" aria-label={`Raise ${profile.name} temperature`} disabled={busy || !entity} onClick={() => void onAction(profile, "set_temperature", target + 0.5)}><Plus aria-hidden="true" size={16} /></button></div> : null}
      {profile.capabilities.includes("play_pause") ? <button type="button" className="home-control-action" disabled={busy || !entity} onClick={() => void onAction(profile, "play_pause")}>{entity?.state === "playing" ? <Pause aria-hidden="true" size={18} /> : <Play aria-hidden="true" size={18} />}<span>{entity?.state === "playing" ? "Pause" : "Play"}</span></button> : null}
      {profile.capabilities.includes("activate") ? <button type="button" className="home-control-action" disabled={busy} onClick={onScene}><Play aria-hidden="true" size={18} /><span>Run</span></button> : null}
    </article>
  );
}

function RoomControls({ room, profiles, entityByID, busy, onAction, onScene }: { room: HomeManifestRoom; profiles: HomeManifestEntity[]; entityByID: Map<string, HomeEntity>; busy: boolean; onAction: (profile: HomeManifestEntity, action: ActionName, value?: number) => Promise<void>; onScene: (profile: HomeManifestEntity) => void }) {
  const onCount = profiles.filter((profile) => entityByID.get(profile.entity_id)?.state === "on").length;
  return (
    <details className="home-room-card">
      <summary><span><strong>{room.name}</strong><small>{profiles.length} signal{profiles.length === 1 ? "" : "s"}{onCount ? ` · ${onCount} on` : ""}</small></span><ChevronRight aria-hidden="true" size={18} /></summary>
      <div className="home-room-controls">{profiles.map((profile) => <HomeControl key={profile.entity_id} profile={profile} entity={entityByID.get(profile.entity_id)} busy={busy} onAction={onAction} onScene={() => onScene(profile)} />)}</div>
    </details>
  );
}
