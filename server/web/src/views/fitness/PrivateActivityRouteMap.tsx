import { LocateFixed, MapPinned, Maximize2, Minimize2, ZoomIn, ZoomOut } from "lucide-react";
import * as maplibregl from "maplibre-gl";
import type { GeoJSONSource, MapLayerMouseEvent } from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import mapLibreWorkerURL from "maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url";
import { useEffect, useMemo, useRef, useState } from "react";

import {
  nearestRoutePoint,
  projectedRoutePath,
  projectRoutePoints,
  routeFeature,
  routePointNearestStreamIndex,
  routeProgressFeature,
  type ActivityRoutePoint,
} from "./activityRouteGeometry";
import { privateMapRequest } from "./privateMapPolicy";

maplibregl.setWorkerUrl(mapLibreWorkerURL);

type PrivateActivityRouteMapProps = {
  points: ActivityRoutePoint[];
  selectedStreamIndex: number;
  selectedSummary: string;
  styleURL: string;
  onSelectStreamIndex: (index: number) => void;
  onUnavailable: () => void;
};

function token(element: HTMLElement, name: string): string {
  return getComputedStyle(element).getPropertyValue(name).trim();
}

function reducedMotion(): boolean {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
}

function fitRoute(map: maplibregl.Map, points: ActivityRoutePoint[]) {
  if (!points.length) return;
  const bounds = points.reduce(
    (current, point) => current.extend(point.coordinate),
    new maplibregl.LngLatBounds(points[0].coordinate, points[0].coordinate),
  );
  map.fitBounds(bounds, {
    padding: { top: 52, right: 52, bottom: 52, left: 52 },
    maxZoom: 16,
    duration: reducedMotion() ? 0 : 250,
  });
}

function markerElement(kind: "start" | "finish" | "selected", label: string): HTMLDivElement {
  const element = document.createElement("div");
  element.className = `fitness-module__route-marker is-${kind}`;
  element.setAttribute("role", "img");
  element.setAttribute("aria-label", label);
  element.title = label;
  if (kind === "start") element.textContent = "S";
  if (kind === "finish") element.textContent = "F";
  return element;
}

type MapFeatureKind = "water" | "land" | "building" | "road" | "other";

function mapFeatureKind(layer: maplibregl.LayerSpecification): MapFeatureKind {
  const sourceLayer = "source-layer" in layer && typeof layer["source-layer"] === "string" ? layer["source-layer"] : "";
  const key = `${layer.id} ${sourceLayer}`.toLocaleLowerCase();
  if (["water", "ocean", "river"].some((term) => key.includes(term))) return "water";
  if (["park", "land", "wood", "green"].some((term) => key.includes(term))) return "land";
  if (key.includes("building")) return "building";
  if (["road", "transport", "street"].some((term) => key.includes(term))) return "road";
  return "other";
}

function applyTheme(map: maplibregl.Map, container: HTMLElement, increasedContrast: boolean) {
  const surface = token(container, "--surface");
  const accent = token(container, "--fitness-accent");
  const dark = document.documentElement.dataset.theme === "dark";

  // Keep the archive's land, water, road and building colours distinct. A
  // blanket token override makes a healthy vector basemap look empty.
  for (const layer of map.getStyle().layers ?? []) {
    if (layer.id.startsWith("activity-route")) continue;
    try {
      if (layer.type === "raster") {
        map.setPaintProperty(layer.id, "raster-saturation", dark ? -0.2 : -0.08);
        map.setPaintProperty(layer.id, "raster-brightness-max", dark ? 0.82 : 1);
        map.setPaintProperty(layer.id, "raster-contrast", increasedContrast ? 0.12 : 0.04);
      } else if (dark && layer.type === "background") {
        map.setPaintProperty(layer.id, "background-color", token(container, "--fitness-map-dark-background"));
      } else if (dark && layer.type === "fill") {
        map.setPaintProperty(layer.id, "fill-color", token(container, `--fitness-map-dark-${mapFeatureKind(layer)}-fill`));
      } else if (dark && layer.type === "line") {
        map.setPaintProperty(layer.id, "line-color", token(container, `--fitness-map-dark-${mapFeatureKind(layer)}-line`));
      } else if (dark && layer.type === "circle") {
        map.setPaintProperty(layer.id, "circle-color", token(container, "--fitness-map-dark-point"));
      } else if (dark && layer.type === "symbol") {
        map.setPaintProperty(layer.id, "text-color", token(container, "--fitness-map-dark-label"));
        map.setPaintProperty(layer.id, "text-halo-color", token(container, "--fitness-map-dark-background"));
      }
    } catch {
      // A private archive can omit any optional layer property. The route
      // remains usable even when a cosmetic override does not apply.
    }
  }
  if (surface) map.setPaintProperty("activity-route-casing", "line-color", surface);
  if (accent) {
    map.setPaintProperty("activity-route-line", "line-color", accent);
    map.setPaintProperty("activity-route-progress-line", "line-color", accent);
  }
  map.setPaintProperty("activity-route-casing", "line-width", increasedContrast ? 13 : 11);
  map.setPaintProperty("activity-route-line", "line-width", increasedContrast ? 8 : 6);
  map.setPaintProperty("activity-route-progress-line", "line-width", increasedContrast ? 8 : 6);
}

export function PrivateActivityRouteMap({
  points,
  selectedStreamIndex,
  selectedSummary,
  styleURL,
  onSelectStreamIndex,
  onUnavailable,
}: PrivateActivityRouteMapProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const selectedMarkerRef = useRef<maplibregl.Marker | null>(null);
  const selectedMarkerElementRef = useRef<HTMLDivElement | null>(null);
  const selectRef = useRef(onSelectStreamIndex);
  const unavailableRef = useRef(onUnavailable);
  const selectedIndexRef = useRef(selectedStreamIndex);
  const selectedSummaryRef = useRef(selectedSummary);
  const fitRef = useRef<() => void>(() => undefined);
  const [ready, setReady] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [viewChanged, setViewChanged] = useState(false);

  const fallbackPoints = useMemo(() => projectRoutePoints(points, 760, 310, 28), [points]);
  const fallbackPath = useMemo(() => projectedRoutePath(fallbackPoints), [fallbackPoints]);
  const selectedFallback = fallbackPoints.find((point) => point.streamIndex === routePointNearestStreamIndex(points, selectedStreamIndex)?.streamIndex)
    ?? fallbackPoints[0];

  useEffect(() => { selectRef.current = onSelectStreamIndex; }, [onSelectStreamIndex]);
  useEffect(() => { unavailableRef.current = onUnavailable; }, [onUnavailable]);
  useEffect(() => {
    selectedIndexRef.current = selectedStreamIndex;
    selectedSummaryRef.current = selectedSummary;
  }, [selectedStreamIndex, selectedSummary]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container || points.length < 2) return;
    let active = true;
    let initialMapReady = false;
    let unavailableSent = false;
    let contrastQuery: MediaQueryList | null = null;
    let themeObserver: MutationObserver | null = null;
    let retheme: (() => void) | null = null;
    setReady(false);
    setViewChanged(false);

    const failClosed = () => {
      if (!active || initialMapReady || unavailableSent) return;
      unavailableSent = true;
      unavailableRef.current();
    };

    let map: maplibregl.Map;
    try {
      map = new maplibregl.Map({
        container,
        style: styleURL,
        center: points[0].coordinate,
        zoom: 13,
        attributionControl: false,
        cooperativeGestures: true,
        transformRequest: (url) => privateMapRequest(url),
      });
    } catch {
      failClosed();
      return;
    }
    mapRef.current = map;
    const loadTimeout = window.setTimeout(failClosed, 10_000);
    map.on("error", failClosed);

    map.once("load", () => {
      if (!active) return;
      try {
        map.addSource("activity-route", { type: "geojson", data: routeFeature(points) });
        map.addSource("activity-route-progress", {
          type: "geojson",
          data: routeProgressFeature(points, selectedIndexRef.current),
        });
        map.addLayer({
          id: "activity-route-casing",
          type: "line",
          source: "activity-route",
          layout: { "line-cap": "round", "line-join": "round" },
          paint: { "line-color": token(container, "--surface"), "line-width": 11, "line-opacity": 0.96 },
        });
        map.addLayer({
          id: "activity-route-line",
          type: "line",
          source: "activity-route",
          layout: { "line-cap": "round", "line-join": "round" },
          paint: { "line-color": token(container, "--fitness-accent"), "line-width": 6, "line-opacity": 0.46 },
        });
        map.addLayer({
          id: "activity-route-progress-line",
          type: "line",
          source: "activity-route-progress",
          layout: { "line-cap": "round", "line-join": "round" },
          paint: { "line-color": token(container, "--fitness-accent"), "line-width": 6, "line-opacity": 1 },
        });
        map.addLayer({
          id: "activity-route-hit",
          type: "line",
          source: "activity-route",
          layout: { "line-cap": "round", "line-join": "round" },
          paint: { "line-color": token(container, "--fitness-accent"), "line-width": 32, "line-opacity": 0.01 },
        });

        new maplibregl.Marker({ element: markerElement("start", "Activity start") })
          .setLngLat(points[0].coordinate)
          .addTo(map);
        new maplibregl.Marker({ element: markerElement("finish", "Activity finish") })
          .setLngLat(points.at(-1)?.coordinate ?? points[0].coordinate)
          .addTo(map);
        const selectedElement = markerElement("selected", `Selected point, ${selectedSummaryRef.current}`);
        const selectedPoint = routePointNearestStreamIndex(points, selectedIndexRef.current) ?? points[0];
        selectedMarkerElementRef.current = selectedElement;
        selectedMarkerRef.current = new maplibregl.Marker({ element: selectedElement })
          .setLngLat(selectedPoint.coordinate)
          .addTo(map);

        const handleRouteClick = (event: MapLayerMouseEvent) => {
          const nearest = nearestRoutePoint(points, event.lngLat.lng, event.lngLat.lat);
          if (nearest) selectRef.current(nearest.streamIndex);
        };
        map.on("click", "activity-route-hit", handleRouteClick);
        map.on("mouseenter", "activity-route-hit", () => { map.getCanvas().style.cursor = "crosshair"; });
        map.on("mouseleave", "activity-route-hit", () => { map.getCanvas().style.cursor = ""; });

        const canvas = map.getCanvas();
        canvas.tabIndex = 0;
        canvas.setAttribute("role", "img");
        canvas.setAttribute("aria-label", `Activity route. ${selectedSummaryRef.current}. Use left and right arrow keys to inspect route points.`);
        canvas.addEventListener("keydown", (event) => {
          const nearest = routePointNearestStreamIndex(points, selectedIndexRef.current);
          const current = Math.max(0, points.findIndex((point) => point.streamIndex === nearest?.streamIndex));
          if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
            event.preventDefault();
            const delta = event.key === "ArrowLeft" ? -1 : 1;
            selectRef.current(points[Math.max(0, Math.min(points.length - 1, current + delta))].streamIndex);
          } else if (event.key === "Home") {
            event.preventDefault();
            selectRef.current(points[0].streamIndex);
          } else if (event.key === "End") {
            event.preventDefault();
            selectRef.current(points.at(-1)!.streamIndex);
          }
        });

        contrastQuery = window.matchMedia?.("(prefers-contrast: more)") ?? null;
        retheme = () => applyTheme(map, container, contrastQuery?.matches ?? false);
        retheme();
        contrastQuery?.addEventListener?.("change", retheme);
        themeObserver = new MutationObserver(retheme);
        themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

        fitRef.current = () => {
          fitRoute(map, points);
          setViewChanged(false);
        };
        map.once("idle", () => {
          if (!active || unavailableSent) return;
          initialMapReady = true;
          window.clearTimeout(loadTimeout);
          setReady(true);
        });
        fitRef.current();
      } catch {
        failClosed();
      }
    });

    return () => {
      active = false;
      window.clearTimeout(loadTimeout);
      if (retheme) contrastQuery?.removeEventListener?.("change", retheme);
      themeObserver?.disconnect();
      fitRef.current = () => undefined;
      selectedMarkerRef.current = null;
      selectedMarkerElementRef.current = null;
      mapRef.current = null;
      map.remove();
    };
  }, [points, styleURL]);

  useEffect(() => {
    if (!ready) return;
    const point = routePointNearestStreamIndex(points, selectedStreamIndex);
    if (!point) return;
    selectedMarkerRef.current?.setLngLat(point.coordinate);
    if (selectedMarkerElementRef.current) {
      selectedMarkerElementRef.current.setAttribute("aria-label", `Selected point, ${selectedSummary}`);
      selectedMarkerElementRef.current.title = `Selected point, ${selectedSummary}`;
    }
    const canvas = mapRef.current?.getCanvas();
    canvas?.setAttribute("aria-label", `Activity route. ${selectedSummary}. Use left and right arrow keys to inspect route points.`);
    const source = mapRef.current?.getSource("activity-route-progress") as GeoJSONSource | undefined;
    source?.setData(routeProgressFeature(points, selectedStreamIndex));
  }, [points, ready, selectedStreamIndex, selectedSummary]);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      mapRef.current?.resize();
      fitRef.current();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [expanded]);

  const mapDuration = reducedMotion() ? 0 : 150;
  return <figure className={`fitness-module__route-map activity-route-map activity-route-map--private${expanded ? " is-expanded" : ""}`}>
    <figcaption>
      <MapPinned aria-hidden="true" size={17} />
      <span>Activity route</span>
      <strong aria-live="polite">{selectedSummary}</strong>
    </figcaption>
    <div className="fitness-module__route-map-viewport" role="region" aria-label="Interactive activity route map" aria-busy={!ready}>
      <div className="fitness-module__route-map-canvas" ref={containerRef} />
      {!ready ? <svg className="activity-route-map__private-placeholder" viewBox="0 0 760 310" aria-hidden="true">
        <path d={fallbackPath} />
        {fallbackPoints[0] ? <circle className="is-start" cx={fallbackPoints[0].x} cy={fallbackPoints[0].y} r="8" /> : null}
        {fallbackPoints.at(-1) ? <circle className="is-finish" cx={fallbackPoints.at(-1)!.x} cy={fallbackPoints.at(-1)!.y} r="8" /> : null}
        {selectedFallback ? <circle className="is-selected" cx={selectedFallback.x} cy={selectedFallback.y} r="6" /> : null}
      </svg> : null}
      {!ready ? <div className="activity-route-map__loading-status" role="status"><span aria-hidden="true" />Loading map</div> : null}
      <div className="fitness-module__route-map-actions">
        <button type="button" aria-label="Reset route view" title="Reset route view" disabled={!ready || !viewChanged} onClick={() => fitRef.current()}><LocateFixed aria-hidden="true" size={18} /></button>
        <button type="button" aria-label="Zoom out route" title="Zoom out route" disabled={!ready} onClick={() => { setViewChanged(true); mapRef.current?.zoomOut({ duration: mapDuration }); }}><ZoomOut aria-hidden="true" size={18} /></button>
        <button type="button" aria-label="Zoom in route" title="Zoom in route" disabled={!ready} onClick={() => { setViewChanged(true); mapRef.current?.zoomIn({ duration: mapDuration }); }}><ZoomIn aria-hidden="true" size={18} /></button>
        <button type="button" aria-label={expanded ? "Reduce map" : "Expand map"} title={expanded ? "Reduce map" : "Expand map"} onClick={() => setExpanded((value) => !value)}>{expanded ? <Minimize2 aria-hidden="true" size={18} /> : <Maximize2 aria-hidden="true" size={18} />}</button>
      </div>
      <small className="activity-route-map__attribution"><a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">© OpenStreetMap contributors</a><span aria-hidden="true"> · </span><a href="https://protomaps.com" target="_blank" rel="noreferrer">Protomaps</a></small>
    </div>
  </figure>;
}
