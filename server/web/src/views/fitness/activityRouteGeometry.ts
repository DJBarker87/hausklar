export type ActivityRouteCoordinate = [longitude: number, latitude: number];

export type ActivityRoutePoint = {
  coordinate: ActivityRouteCoordinate;
  streamIndex: number;
};

export type ProjectedActivityRoutePoint = {
  x: number;
  y: number;
  streamIndex: number;
};

export type ActivityRouteFeature = {
  type: "Feature";
  properties: Record<string, never>;
  geometry: {
    type: "LineString";
    coordinates: ActivityRouteCoordinate[];
  };
};

export function routePointsFromStreams(
  latitudes: Array<number | null | undefined>,
  longitudes: Array<number | null | undefined>,
): ActivityRoutePoint[] {
  return latitudes.flatMap((latitude, streamIndex) => {
    const longitude = longitudes[streamIndex];
    if (
      latitude == null
      || longitude == null
      || !Number.isFinite(latitude)
      || !Number.isFinite(longitude)
      || Math.abs(latitude) > 90
      || Math.abs(longitude) > 180
    ) return [];
    return [{ coordinate: [longitude, latitude], streamIndex } satisfies ActivityRoutePoint];
  });
}

export function routeFeature(points: ActivityRoutePoint[]): ActivityRouteFeature {
  const coordinates = points.map((point) => point.coordinate);
  return {
    type: "Feature",
    properties: {},
    geometry: {
      type: "LineString",
      coordinates: coordinates.length === 1 ? [coordinates[0], coordinates[0]] : coordinates,
    },
  };
}

export function routeProgressFeature(
  points: ActivityRoutePoint[],
  selectedStreamIndex: number,
): ActivityRouteFeature {
  const progress = points.filter((point) => point.streamIndex <= selectedStreamIndex);
  return routeFeature(progress.length ? progress : points.slice(0, 1));
}

export function routePointNearestStreamIndex(
  points: ActivityRoutePoint[],
  selectedStreamIndex: number,
): ActivityRoutePoint | null {
  if (!points.length) return null;
  return points.reduce((nearest, point) => (
    Math.abs(point.streamIndex - selectedStreamIndex) < Math.abs(nearest.streamIndex - selectedStreamIndex)
      ? point
      : nearest
  ));
}

export function nearestRoutePoint(
  points: ActivityRoutePoint[],
  longitude: number,
  latitude: number,
): ActivityRoutePoint | null {
  if (!points.length) return null;
  const longitudeScale = Math.max(0.01, Math.cos(latitude * Math.PI / 180));
  return points.reduce((nearest, point) => {
    const nearestLongitude = (nearest.coordinate[0] - longitude) * longitudeScale;
    const nearestLatitude = nearest.coordinate[1] - latitude;
    const pointLongitude = (point.coordinate[0] - longitude) * longitudeScale;
    const pointLatitude = point.coordinate[1] - latitude;
    return pointLongitude * pointLongitude + pointLatitude * pointLatitude
      < nearestLongitude * nearestLongitude + nearestLatitude * nearestLatitude
      ? point
      : nearest;
  });
}

/**
 * Fits a GPS route into a local drawing surface while preserving its geographic
 * aspect ratio. Longitude is corrected for latitude so a route keeps its real
 * shape instead of stretching east-west at UK latitudes.
 */
export function projectRoutePoints(
  points: ActivityRoutePoint[],
  width: number,
  height: number,
  requestedPadding = 40,
): ProjectedActivityRoutePoint[] {
  if (!points.length) return [];

  const safeWidth = Math.max(1, width);
  const safeHeight = Math.max(1, height);
  const padding = Math.max(0, Math.min(
    requestedPadding,
    safeWidth / 2 - 1,
    safeHeight / 2 - 1,
  ));
  const averageLatitude = points.reduce((total, point) => total + point.coordinate[1], 0) / points.length;
  const longitudeScale = Math.max(0.01, Math.cos(averageLatitude * Math.PI / 180));
  const geographicPoints = points.map((point) => ({
    x: point.coordinate[0] * longitudeScale,
    y: point.coordinate[1],
    streamIndex: point.streamIndex,
  }));
  const xs = geographicPoints.map((point) => point.x);
  const ys = geographicPoints.map((point) => point.y);
  const minimumX = Math.min(...xs);
  const maximumX = Math.max(...xs);
  const minimumY = Math.min(...ys);
  const maximumY = Math.max(...ys);
  const spanX = maximumX - minimumX;
  const spanY = maximumY - minimumY;
  const availableWidth = Math.max(1, safeWidth - padding * 2);
  const availableHeight = Math.max(1, safeHeight - padding * 2);
  const scaleX = spanX > Number.EPSILON ? availableWidth / spanX : Number.POSITIVE_INFINITY;
  const scaleY = spanY > Number.EPSILON ? availableHeight / spanY : Number.POSITIVE_INFINITY;
  const scale = Number.isFinite(Math.min(scaleX, scaleY)) ? Math.min(scaleX, scaleY) : 1;
  const centreX = (minimumX + maximumX) / 2;
  const centreY = (minimumY + maximumY) / 2;

  return geographicPoints.map((point) => ({
    x: safeWidth / 2 + (point.x - centreX) * scale,
    y: safeHeight / 2 - (point.y - centreY) * scale,
    streamIndex: point.streamIndex,
  }));
}

export function projectedRoutePath(points: ProjectedActivityRoutePoint[]): string {
  return points.map((point, index) => (
    `${index ? "L" : "M"}${point.x.toFixed(2)},${point.y.toFixed(2)}`
  )).join(" ");
}

export function nearestProjectedRoutePoint(
  points: ProjectedActivityRoutePoint[],
  x: number,
  y: number,
): ProjectedActivityRoutePoint | null {
  if (!points.length) return null;
  return points.reduce((nearest, point) => {
    const nearestDistance = (nearest.x - x) ** 2 + (nearest.y - y) ** 2;
    const pointDistance = (point.x - x) ** 2 + (point.y - y) ** 2;
    return pointDistance < nearestDistance ? point : nearest;
  });
}
