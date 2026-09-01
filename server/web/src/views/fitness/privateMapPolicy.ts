import type { FitnessPrivateMapAvailability } from "../../fitness/contract";

const PRIVATE_STYLE_PATH = "/api/fitness/maps/style.json";
const PRIVATE_TILEJSON_PATH = "/api/fitness/maps/tilejson.json";
const PRIVATE_RESOURCE_PATHS = [
  /^\/api\/fitness\/maps\/style\.json$/,
  /^\/api\/fitness\/maps\/tilejson\.json$/,
  /^\/api\/fitness\/maps\/tiles\/(?:0|[1-9]\d?)\/(?:0|[1-9]\d*)\/(?:0|[1-9]\d*)\.(?:png|jpg|webp|pbf)$/,
  /^\/api\/fitness\/maps\/sprites\/sprite(?:@2x)?\.(?:json|png)$/,
  /^\/api\/fitness\/maps\/glyphs\/[^/]+\/(?:0|[1-9]\d*)-(?:0|[1-9]\d*)\.pbf$/,
] as const;

function applicationOrigin(origin?: string): string {
  return origin ?? window.location.origin;
}

function privateResourceURL(value: string, origin?: string): URL | null {
  if (!value || value.length > 2_000) return null;
  const expectedOrigin = applicationOrigin(origin);
  try {
    const url = new URL(value, expectedOrigin);
    if (
      url.origin !== expectedOrigin
      || url.username
      || url.password
      || !PRIVATE_RESOURCE_PATHS.some((pattern) => pattern.test(url.pathname))
    ) return null;
    return url;
  } catch {
    return null;
  }
}

export function privateMapRequest(
  value: string,
  origin?: string,
): { url: string; credentials: "same-origin" } {
  const url = privateResourceURL(value, origin);
  if (!url) throw new Error("Blocked non-private map resource.");
  return { url: url.href, credentials: "same-origin" };
}

export function parsePrivateMapAvailability(
  value: unknown,
  origin?: string,
): FitnessPrivateMapAvailability | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<FitnessPrivateMapAvailability>;
  if (candidate.available === false) return { available: false };
  if (
    candidate.available !== true
    || !["png", "jpg", "webp", "pbf"].includes(String(candidate.format))
    || !Number.isInteger(candidate.min_zoom)
    || !Number.isInteger(candidate.max_zoom)
    || Number(candidate.min_zoom) < 0
    || Number(candidate.max_zoom) > 22
    || Number(candidate.min_zoom) > Number(candidate.max_zoom)
    || !Array.isArray(candidate.bounds)
    || candidate.bounds.length !== 4
    || !candidate.bounds.every((item) => typeof item === "number" && Number.isFinite(item))
    || typeof candidate.style_url !== "string"
    || typeof candidate.tilejson_url !== "string"
  ) return null;
  const styleURL = privateResourceURL(candidate.style_url, origin);
  const tileJSONURL = privateResourceURL(candidate.tilejson_url, origin);
  if (styleURL?.pathname !== PRIVATE_STYLE_PATH || tileJSONURL?.pathname !== PRIVATE_TILEJSON_PATH) return null;
  const [west, south, east, north] = candidate.bounds as [number, number, number, number];
  if (!(west >= -180 && west < east && east <= 180 && south >= -90 && south < north && north <= 90)) return null;
  return {
    available: true,
    format: candidate.format as FitnessPrivateMapAvailability["format"],
    min_zoom: candidate.min_zoom,
    max_zoom: candidate.max_zoom,
    bounds: [west, south, east, north],
    style_url: styleURL.href,
    tilejson_url: tileJSONURL.href,
    has_sprites: candidate.has_sprites === true,
    has_glyphs: candidate.has_glyphs === true,
  };
}
