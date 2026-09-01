import { describe, expect, it } from "vitest";

import {
  nearestProjectedRoutePoint,
  nearestRoutePoint,
  projectedRoutePath,
  projectRoutePoints,
  routeFeature,
  routePointNearestStreamIndex,
  routePointsFromStreams,
  routeProgressFeature,
} from "../views/fitness/activityRouteGeometry";
import { streamIndexNearestOffset } from "../views/fitness/ActivityVisualiser";

describe("Garmin activity route geometry", () => {
  const points = routePointsFromStreams(
    [51.5, null, 51.502, 95, 51.504],
    [-0.1, -0.099, -0.098, -0.097, -0.096],
  );

  it("keeps valid Garmin positions and preserves their stream indices", () => {
    expect(points).toEqual([
      { coordinate: [-0.1, 51.5], streamIndex: 0 },
      { coordinate: [-0.098, 51.502], streamIndex: 2 },
      { coordinate: [-0.096, 51.504], streamIndex: 4 },
    ]);
    expect(routeFeature(points).geometry.coordinates).toEqual(points.map((point) => point.coordinate));
  });

  it("builds progress geometry and resolves selections against sparse GPS samples", () => {
    expect(routeProgressFeature(points, 2).geometry.coordinates).toEqual([
      [-0.1, 51.5],
      [-0.098, 51.502],
    ]);
    expect(routePointNearestStreamIndex(points, 3)?.streamIndex).toBe(2);
    expect(nearestRoutePoint(points, -0.0961, 51.5039)?.streamIndex).toBe(4);
  });

  it("aligns a full-resolution route point with the nearest chart sample", () => {
    expect(streamIndexNearestOffset([0, 10_000, 20_000, 30_000], 18_900)).toBe(2);
  });

  it("fits the route to a private local surface without distorting its geographic aspect", () => {
    const projected = projectRoutePoints(points, 760, 310, 40);
    expect(projected).toHaveLength(3);
    expect(projected.every((point) => point.x >= 40 && point.x <= 720)).toBe(true);
    expect(projected.every((point) => point.y >= 39.99 && point.y <= 270.01)).toBe(true);
    expect(projected[0].x).toBeLessThan(projected.at(-1)!.x);
    expect(projected[0].y).toBeGreaterThan(projected.at(-1)!.y);
    expect(projectedRoutePath(projected)).toMatch(/^M\d+\.\d{2},\d+\.\d{2} L/);
    expect(nearestProjectedRoutePoint(projected, projected[1].x + 1, projected[1].y + 1)?.streamIndex).toBe(2);
  });

  it("centres a stationary route safely", () => {
    const projected = projectRoutePoints([
      { coordinate: [-0.1, 51.5], streamIndex: 0 },
      { coordinate: [-0.1, 51.5], streamIndex: 1 },
    ], 300, 200);
    expect(projected).toEqual([
      { x: 150, y: 100, streamIndex: 0 },
      { x: 150, y: 100, streamIndex: 1 },
    ]);
  });
});
