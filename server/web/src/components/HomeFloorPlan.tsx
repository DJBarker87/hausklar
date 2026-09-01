import { DoorOpen, Lightbulb, Thermometer } from "lucide-react";
import { useMemo, useState } from "react";

import { Segmented, cn } from "./ui";

export type FloorPlanEntity = {
  entity_id: string;
  name: string;
  domain: string;
  state: string;
  current_temperature?: number | null;
};

type Floor = 0 | 1;
type Point = [number, number];
type Line = [number, number, number, number];

type Room = {
  id: string;
  label: string;
  bounds: { x: number; y: number; width: number; height: number };
  polygon?: Point[] | null;
  light_entity_ids: string[];
  label_at: Point;
};

type FloorLayout = {
  id: Floor;
  name: string;
  rooms: Room[];
  walls: Line[];
  stairs: Line[];
};

export type HomeFloorPlanLayout = {
  width: number;
  height: number;
  floors: FloorLayout[];
  temperatures: Array<{ floor: Floor; entity_ids: string[]; at: Point }>;
  doors: Array<{ floor: Floor; entity_ids: string[]; at: Point; label: string }>;
};

function findEntity(entities: FloorPlanEntity[], entityIDs: string[]): FloorPlanEntity | undefined {
  return entityIDs.map((id) => entities.find((entity) => entity.entity_id === id)).find(Boolean);
}

function position([x, y]: Point, layout: HomeFloorPlanLayout) {
  return { left: `${(x / layout.width) * 100}%`, top: `${(y / layout.height) * 100}%` };
}

export function HomeFloorPlan({
  entities,
  layout,
  busy,
  onToggle,
}: {
  entities: FloorPlanEntity[];
  layout: HomeFloorPlanLayout;
  busy: boolean;
  onToggle: (entity: FloorPlanEntity) => void;
}) {
  const [floor, setFloor] = useState<Floor>(0);
  const currentFloor = layout.floors.find((item) => item.id === floor) ?? layout.floors[0];
  const selectedFloor = currentFloor?.id ?? 0;
  const rooms = currentFloor?.rooms ?? [];
  const roomStates = useMemo(() => rooms.map((room) => {
    const light = findEntity(entities, room.light_entity_ids);
    return { room, light, lit: light?.state === "on" };
  }), [entities, rooms]);
  const temperatures = layout.temperatures
    .filter((point) => point.floor === selectedFloor)
    .map((point) => ({ ...point, entity: findEntity(entities, point.entity_ids) }))
    .filter((point) => point.entity?.current_temperature != null);
  const doors = layout.doors
    .filter((point) => point.floor === selectedFloor)
    .map((point) => ({ ...point, entity: findEntity(entities, point.entity_ids) }))
    .filter((point) => point.entity);
  const lightsOn = roomStates.filter((state) => state.lit).length;
  const doorsOpen = doors.filter((door) => door.entity?.state === "on").length;
  const floorName = currentFloor?.name ?? "House";

  return (
    <section className="home-floor-plan" aria-labelledby="house-map-title">
      <header className="home-floor-plan-header">
        <div>
          <h2 id="house-map-title">House map</h2>
          <p>{lightsOn} {lightsOn === 1 ? "light" : "lights"} on{selectedFloor === 0 ? ` · ${doorsOpen} open` : ""}</p>
        </div>
        <Segmented
          label="Choose floor"
          value={String(selectedFloor)}
          onChange={(value) => setFloor(Number(value) === 1 ? 1 : 0)}
          options={layout.floors.map((item) => ({ value: String(item.id), label: item.name.replace(/ floor$/i, "") }))}
        />
      </header>

      <div className="home-floor-plan-canvas">
        <svg viewBox={`0 0 ${layout.width} ${layout.height}`} role="img" aria-label={`${floorName} house map. ${lightsOn} ${lightsOn === 1 ? "light" : "lights"} on${selectedFloor === 0 ? ` and ${doorsOpen} ${doorsOpen === 1 ? "door" : "doors"} open` : ""}.`}>
          <rect className="floor-plan-background" width={layout.width} height={layout.height} rx="24" />
          <g className="floor-plan-rooms">
            {roomStates.map(({ room, lit, light }) => room.polygon ? (
              <polygon key={room.id} className={cn(lit && "is-lit", !light && "is-unavailable")} points={room.polygon.map((point) => point.join(",")).join(" ")} />
            ) : (
              <rect key={room.id} className={cn(lit && "is-lit", !light && "is-unavailable")} {...room.bounds} />
            ))}
          </g>
          <g className="floor-plan-walls" aria-hidden="true">
            {(currentFloor?.walls ?? []).map(([x1, y1, x2, y2], index) => <line key={`${x1}-${y1}-${index}`} x1={x1} y1={y1} x2={x2} y2={y2} />)}
          </g>
          <g className="floor-plan-stairs" aria-hidden="true">
            {(currentFloor?.stairs ?? []).map(([x1, y1, x2, y2], index) => <line key={`${x1}-${y1}-${index}`} x1={x1} y1={y1} x2={x2} y2={y2} />)}
          </g>
        </svg>

        <div className="floor-plan-label-layer">
          {roomStates.map(({ room, light, lit }) => light ? (
            <button
              type="button"
              className={cn("floor-plan-room-label", "floor-plan-room-control", lit && "is-lit")}
              style={position(room.label_at, layout)}
              disabled={busy}
              aria-pressed={lit}
              aria-label={`${room.label} light, ${lit ? "on" : "off"}`}
              onClick={() => onToggle(light)}
              key={room.id}
            >
              <Lightbulb aria-hidden="true" size={13} fill={lit ? "currentColor" : "none"} />
              {room.label}
            </button>
          ) : (
            <span className="floor-plan-room-label" style={position(room.label_at, layout)} key={room.id}>{room.label}</span>
          ))}
          {temperatures.map(({ entity, at }) => <span className="floor-plan-temperature" aria-hidden="true" style={position(at, layout)} key={entity!.entity_id}><Thermometer size={12} />{entity!.current_temperature!.toFixed(1)}°</span>)}
          {doors.map(({ entity, at }) => <span className={cn("floor-plan-door", entity!.state === "on" && "is-open")} aria-hidden="true" style={position(at, layout)} key={entity!.entity_id}><DoorOpen size={13} /></span>)}
        </div>
      </div>
    </section>
  );
}
