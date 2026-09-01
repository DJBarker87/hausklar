import { LocateFixed, MapPinned, Maximize2, Minimize2, ZoomIn, ZoomOut } from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useId, useMemo, useRef, useState } from "react";

import { api } from "../../api";
import type { FitnessPrivateMapAvailability } from "../../fitness/contract";
import {
  nearestProjectedRoutePoint,
  projectedRoutePath,
  projectRoutePoints,
  routePointNearestStreamIndex,
  type ActivityRoutePoint,
} from "./activityRouteGeometry";
import { parsePrivateMapAvailability } from "./privateMapPolicy";
import "./activity-route-map.css";

const PrivateActivityRouteMap = lazy(() => import("./PrivateActivityRouteMap").then((module) => ({ default: module.PrivateActivityRouteMap })));

const DEFAULT_WIDTH = 760;
const DEFAULT_HEIGHT = 310;
const ZOOM_LEVELS = [1, 1.4, 1.85, 2.4] as const;

type SurfaceSize = {
  width: number;
  height: number;
};

type ActivityRouteMapProps = {
  points: ActivityRoutePoint[];
  selectedStreamIndex: number;
  selectedSummary: string;
  onSelectStreamIndex: (index: number) => void;
};

type LocalActivityRouteMapProps = ActivityRouteMapProps & {
  basemapState?: "route-only" | "error" | null;
  onRetryBasemap?: () => void;
};

function routeIsInsideBounds(points: ActivityRoutePoint[], bounds: [number, number, number, number]): boolean {
  const [west, south, east, north] = bounds;
  return points.every(({ coordinate: [longitude, latitude] }) => (
    longitude >= west && longitude <= east && latitude >= south && latitude <= north
  ));
}

export function LocalActivityRouteMap({
  points,
  selectedStreamIndex,
  selectedSummary,
  onSelectStreamIndex,
  basemapState = null,
  onRetryBasemap,
}: LocalActivityRouteMapProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const routeRef = useRef<SVGSVGElement>(null);
  const patternID = `activity-route-grid-${useId().replaceAll(":", "")}`;
  const [surfaceSize, setSurfaceSize] = useState<SurfaceSize>({ width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT });
  const [zoomIndex, setZoomIndex] = useState(0);
  const [expanded, setExpanded] = useState(false);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    const updateSize = () => {
      const bounds = viewport.getBoundingClientRect();
      if (bounds.width < 1 || bounds.height < 1) return;
      const next = { width: Math.round(bounds.width), height: Math.round(bounds.height) };
      setSurfaceSize((current) => (
        current.width === next.width && current.height === next.height ? current : next
      ));
    };
    updateSize();
    const observer = new ResizeObserver(updateSize);
    observer.observe(viewport);
    return () => observer.disconnect();
  }, []);

  const projectedPoints = useMemo(() => projectRoutePoints(
    points,
    surfaceSize.width,
    surfaceSize.height,
    Math.min(48, surfaceSize.width / 9, surfaceSize.height / 7),
  ), [points, surfaceSize]);
  const routePath = useMemo(() => projectedRoutePath(projectedPoints), [projectedPoints]);
  const progressPath = useMemo(() => {
    const progress = projectedPoints.filter((point) => point.streamIndex <= selectedStreamIndex);
    return projectedRoutePath(progress.length ? progress : projectedPoints.slice(0, 1));
  }, [projectedPoints, selectedStreamIndex]);
  const selectedRoutePoint = routePointNearestStreamIndex(points, selectedStreamIndex);
  const selectedPoint = projectedPoints.find((point) => point.streamIndex === selectedRoutePoint?.streamIndex)
    ?? projectedPoints[0];
  const startPoint = projectedPoints[0];
  const finishPoint = projectedPoints.at(-1);
  const zoom = ZOOM_LEVELS[zoomIndex];
  const viewWidth = surfaceSize.width / zoom;
  const viewHeight = surfaceSize.height / zoom;
  const viewCentreX = selectedPoint?.x ?? surfaceSize.width / 2;
  const viewCentreY = selectedPoint?.y ?? surfaceSize.height / 2;
  const viewX = Math.max(0, Math.min(surfaceSize.width - viewWidth, viewCentreX - viewWidth / 2));
  const viewY = Math.max(0, Math.min(surfaceSize.height - viewHeight, viewCentreY - viewHeight / 2));
  const viewBox = `${viewX} ${viewY} ${viewWidth} ${viewHeight}`;

  const selectPointAt = useCallback((clientX: number, clientY: number) => {
    const svg = routeRef.current;
    if (!svg) return;
    const bounds = svg.getBoundingClientRect();
    if (bounds.width < 1 || bounds.height < 1) return;
    const x = viewX + (clientX - bounds.left) / bounds.width * viewWidth;
    const y = viewY + (clientY - bounds.top) / bounds.height * viewHeight;
    const nearest = nearestProjectedRoutePoint(projectedPoints, x, y);
    if (nearest) onSelectStreamIndex(nearest.streamIndex);
  }, [onSelectStreamIndex, projectedPoints, viewHeight, viewWidth, viewX, viewY]);

  const moveSelection = useCallback((direction: -1 | 1) => {
    if (!points.length) return;
    const nearest = routePointNearestStreamIndex(points, selectedStreamIndex);
    const currentIndex = Math.max(0, points.findIndex((point) => point.streamIndex === nearest?.streamIndex));
    const nextIndex = Math.max(0, Math.min(points.length - 1, currentIndex + direction));
    onSelectStreamIndex(points[nextIndex].streamIndex);
  }, [onSelectStreamIndex, points, selectedStreamIndex]);

  return <figure className={`fitness-module__route-map activity-route-map${expanded ? " is-expanded" : ""}`}>
    <figcaption>
      <MapPinned aria-hidden="true" size={17} />
      <span>Activity route</span>
      {basemapState ? <span className="activity-route-map__mode" role="status">Route only</span> : null}
      {basemapState === "error" ? <button type="button" className="activity-route-map__retry" onClick={onRetryBasemap}>Retry map</button> : null}
      <strong aria-live="polite">{selectedSummary}</strong>
    </figcaption>
    <div
      className="fitness-module__route-map-viewport"
      ref={viewportRef}
      role="region"
      aria-label="Interactive activity route map"
      aria-busy="false"
    >
      <svg
        className="fitness-module__route-map-canvas activity-route-map__surface"
        ref={routeRef}
        viewBox={viewBox}
        preserveAspectRatio="none"
        role="img"
        tabIndex={0}
        aria-label={`Activity route. ${selectedSummary}. Use left and right arrow keys to inspect route points.`}
        onPointerDown={(event) => {
          event.currentTarget.focus();
          selectPointAt(event.clientX, event.clientY);
        }}
        onKeyDown={(event) => {
          if (event.key === "ArrowLeft") { event.preventDefault(); moveSelection(-1); }
          if (event.key === "ArrowRight") { event.preventDefault(); moveSelection(1); }
          if (event.key === "Home" && points[0]) { event.preventDefault(); onSelectStreamIndex(points[0].streamIndex); }
          if (event.key === "End" && points.at(-1)) { event.preventDefault(); onSelectStreamIndex(points.at(-1)!.streamIndex); }
        }}
      >
        <defs>
          <pattern id={patternID} width="32" height="32" patternUnits="userSpaceOnUse">
            <path className="activity-route-map__grid-minor" d="M 32 0 L 0 0 0 32" />
          </pattern>
        </defs>
        <rect className="activity-route-map__backdrop" x={viewX} y={viewY} width={viewWidth} height={viewHeight} />
        <rect className="activity-route-map__grid" x={viewX} y={viewY} width={viewWidth} height={viewHeight} fill={`url(#${patternID})`} />
        <g className="activity-route-map__contours" aria-hidden="true">
          <path d={`M ${-surfaceSize.width * 0.08} ${surfaceSize.height * 0.3} C ${surfaceSize.width * 0.18} ${surfaceSize.height * 0.08}, ${surfaceSize.width * 0.32} ${surfaceSize.height * 0.56}, ${surfaceSize.width * 0.58} ${surfaceSize.height * 0.24} S ${surfaceSize.width * 0.96} ${surfaceSize.height * 0.24}, ${surfaceSize.width * 1.1} ${surfaceSize.height * 0.08}`} />
          <path d={`M ${-surfaceSize.width * 0.08} ${surfaceSize.height * 0.42} C ${surfaceSize.width * 0.2} ${surfaceSize.height * 0.2}, ${surfaceSize.width * 0.34} ${surfaceSize.height * 0.67}, ${surfaceSize.width * 0.62} ${surfaceSize.height * 0.34} S ${surfaceSize.width * 0.98} ${surfaceSize.height * 0.36}, ${surfaceSize.width * 1.1} ${surfaceSize.height * 0.2}`} />
          <path d={`M ${-surfaceSize.width * 0.08} ${surfaceSize.height * 0.8} C ${surfaceSize.width * 0.22} ${surfaceSize.height * 0.56}, ${surfaceSize.width * 0.4} ${surfaceSize.height * 1.04}, ${surfaceSize.width * 0.72} ${surfaceSize.height * 0.68} S ${surfaceSize.width * 0.98} ${surfaceSize.height * 0.62}, ${surfaceSize.width * 1.1} ${surfaceSize.height * 0.54}`} />
        </g>
        <path className="activity-route-map__route-casing" d={routePath} aria-hidden="true" />
        <path className="activity-route-map__route-base" d={routePath} aria-hidden="true" />
        <path className="activity-route-map__route-progress" d={progressPath} aria-hidden="true" />
        <path className="activity-route-map__route-hit" d={routePath} aria-hidden="true" />
        {startPoint ? <g className="activity-route-map__marker is-start" role="img" aria-label="Activity start" transform={`translate(${startPoint.x} ${startPoint.y})`}>
          <circle r="12" />
          <text y="0.5">S</text>
        </g> : null}
        {finishPoint ? <g className="activity-route-map__marker is-finish" role="img" aria-label="Activity finish" transform={`translate(${finishPoint.x} ${finishPoint.y})`}>
          <circle r="12" />
          <text y="0.5">F</text>
        </g> : null}
        {selectedPoint ? <g className="activity-route-map__marker is-selected" role="img" aria-label={`Selected point, ${selectedSummary}`} transform={`translate(${selectedPoint.x} ${selectedPoint.y})`}>
          <circle className="activity-route-map__selected-halo" r="11" />
          <circle className="activity-route-map__selected-point" r="5" />
        </g> : null}
      </svg>
      <div className="fitness-module__route-map-actions">
        <button type="button" aria-label="Reset route view" title="Reset route view" disabled={zoomIndex === 0} onClick={() => setZoomIndex(0)}><LocateFixed aria-hidden="true" size={18} /></button>
        <button type="button" aria-label="Zoom out route" title="Zoom out route" disabled={zoomIndex === 0} onClick={() => setZoomIndex((value) => Math.max(0, value - 1))}><ZoomOut aria-hidden="true" size={18} /></button>
        <button type="button" aria-label="Zoom in route" title="Zoom in route" disabled={zoomIndex === ZOOM_LEVELS.length - 1} onClick={() => setZoomIndex((value) => Math.min(ZOOM_LEVELS.length - 1, value + 1))}><ZoomIn aria-hidden="true" size={18} /></button>
        <button type="button" aria-label={expanded ? "Reduce map" : "Expand map"} title={expanded ? "Reduce map" : "Expand map"} onClick={() => setExpanded((value) => !value)}>{expanded ? <Minimize2 aria-hidden="true" size={18} /> : <Maximize2 aria-hidden="true" size={18} />}</button>
      </div>
    </div>
  </figure>;
}

export function ActivityRouteMap(props: ActivityRouteMapProps) {
  const [privateMap, setPrivateMap] = useState<{ status: "checking" | "available" | "route-only" | "error"; styleURL?: string }>({ status: "checking" });
  const [privateMapReady, setPrivateMapReady] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let active = true;
    setPrivateMap({ status: "checking" });
    void api<FitnessPrivateMapAvailability>("/fitness/maps", {}, true, false)
      .then((response) => {
        if (!active) return;
        const availability = parsePrivateMapAvailability(response);
        if (
          availability?.available
          && availability.style_url
          && availability.bounds
          && routeIsInsideBounds(props.points, availability.bounds)
        ) {
          setPrivateMap({ status: "available", styleURL: availability.style_url });
        } else {
          setPrivateMap({ status: "route-only" });
        }
      })
      .catch(() => {
        if (active) setPrivateMap({ status: "error" });
      });
    return () => { active = false; };
  }, [attempt, props.points]);

  useEffect(() => {
    if (privateMap.status !== "available") {
      setPrivateMapReady(false);
      return;
    }
    // The route-only SVG is complete and interactive. Let it paint before
    // downloading and evaluating the substantially larger private map engine.
    const windowWithIdle = window as Window & {
      requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number;
      cancelIdleCallback?: (handle: number) => void;
    };
    if (windowWithIdle.requestIdleCallback) {
      const handle = windowWithIdle.requestIdleCallback(() => setPrivateMapReady(true), { timeout: 1_000 });
      return () => windowWithIdle.cancelIdleCallback?.(handle);
    }
    const handle = window.setTimeout(() => setPrivateMapReady(true), 250);
    return () => window.clearTimeout(handle);
  }, [privateMap.status]);

  if (privateMap.status !== "available" || !privateMap.styleURL || !privateMapReady) return <LocalActivityRouteMap
    {...props}
    basemapState={privateMap.status === "route-only" ? "route-only" : privateMap.status === "error" ? "error" : null}
    onRetryBasemap={() => setAttempt((value) => value + 1)}
  />;
  return <Suspense fallback={<LocalActivityRouteMap {...props} />}>
    <PrivateActivityRouteMap
      {...props}
      styleURL={privateMap.styleURL}
      onUnavailable={() => setPrivateMap({ status: "error" })}
    />
  </Suspense>;
}
