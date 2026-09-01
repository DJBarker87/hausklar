import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { ActivityRouteMap, LocalActivityRouteMap } from "../views/fitness/ActivityRouteMap";
import componentSource from "../views/fitness/ActivityRouteMap.tsx?raw";
import privateComponentSource from "../views/fitness/PrivateActivityRouteMap.tsx?raw";
import { parsePrivateMapAvailability, privateMapRequest } from "../views/fitness/privateMapPolicy";

vi.mock("../api", () => ({ api: vi.fn() }));
vi.mock("../views/fitness/PrivateActivityRouteMap", () => ({
  PrivateActivityRouteMap: ({ onSelectStreamIndex, styleURL }: { onSelectStreamIndex: (index: number) => void; styleURL: string }) => <div data-testid="private-activity-map" data-style-url={styleURL}><button type="button" onClick={() => onSelectStreamIndex(2)}>Select private route point</button></div>,
}));

const apiMock = vi.mocked(api);
const points = [
  { coordinate: [0.0005, 0.0005] as [number, number], streamIndex: 0 },
  { coordinate: [0.0003, 0.0003] as [number, number], streamIndex: 1 },
  { coordinate: [0.0002, 0.0002] as [number, number], streamIndex: 2 },
];
const privateAvailability = {
  available: true,
  format: "png",
  min_zoom: 0,
  max_zoom: 14,
  bounds: [-1, -1, 1, 1],
  style_url: "/api/fitness/maps/style.json",
  tilejson_url: "/api/fitness/maps/tilejson.json",
  has_sprites: false,
  has_glyphs: false,
};

beforeEach(() => apiMock.mockReset());
afterEach(() => vi.unstubAllGlobals());

describe("private activity route map", () => {
  it("allows only authenticated same-origin private map resources", () => {
    const origin = "https://hausklar.example";
    for (const path of [
      "/api/fitness/maps/style.json",
      "/api/fitness/maps/tilejson.json?v=one",
      "/api/fitness/maps/tiles/12/2047/1363.pbf?v=one",
      "/api/fitness/maps/sprites/sprite.png",
      "/api/fitness/maps/glyphs/Noto%20Sans%20Regular/0-255.pbf",
    ]) {
      expect(privateMapRequest(path, origin)).toEqual({ url: new URL(path, origin).href, credentials: "same-origin" });
    }
    for (const path of [
      "https://tiles.example/12/1/2.png",
      "//tiles.example/private.png",
      "/api/fitness/maps/other.json",
      "/api/fitness/maps/sprites/other.png",
      "/api/fitness/maps/tiles/12/1/2.svg",
    ]) expect(() => privateMapRequest(path, origin)).toThrow("Blocked non-private map resource");
  });

  it("rejects malformed or cross-origin availability before loading MapLibre", () => {
    const origin = "https://hausklar.example";
    expect(parsePrivateMapAvailability({ ...privateAvailability, style_url: "https://tiles.example/style.json" }, origin)).toBeNull();
    expect(parsePrivateMapAvailability({ ...privateAvailability, max_zoom: 23 }, origin)).toBeNull();
    expect(parsePrivateMapAvailability({ ...privateAvailability, bounds: [-1, 50, -2, 52] }, origin)).toBeNull();
    expect(parsePrivateMapAvailability(privateAvailability, origin)).toMatchObject({
      available: true,
      style_url: `${origin}/api/fitness/maps/style.json`,
      tilejson_url: `${origin}/api/fitness/maps/tilejson.json`,
    });
  });

  it("keeps the neutral interactive SVG when the private archive is unavailable", async () => {
    apiMock.mockResolvedValue({ available: false });
    const onSelectStreamIndex = vi.fn();
    const { container } = render(<ActivityRouteMap
      points={points}
      selectedStreamIndex={1}
      selectedSummary="2.00 km · 10:30"
      onSelectStreamIndex={onSelectStreamIndex}
    />);

    expect(screen.getByRole("region", { name: "Interactive activity route map" })).toHaveAttribute("aria-busy", "false");
    expect(screen.getByRole("img", { name: "Activity start" })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: "Activity finish" })).toBeInTheDocument();
    expect(await screen.findByText("Route only")).toBeInTheDocument();
    expect(container.querySelector("canvas")).not.toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/maps", {}, true, false));
    expect(screen.queryByTestId("private-activity-map")).not.toBeInTheDocument();
  });

  it("keeps the route visible and offers a retry when basemap discovery fails", async () => {
    apiMock.mockRejectedValueOnce(new Error("offline"));
    apiMock.mockResolvedValueOnce({ available: false });
    render(<ActivityRouteMap
      points={points}
      selectedStreamIndex={1}
      selectedSummary="2.00 km · 10:30"
      onSelectStreamIndex={vi.fn()}
    />);

    expect(await screen.findByText("Route only")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry map" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledTimes(2));
    expect(screen.queryByRole("button", { name: "Retry map" })).not.toBeInTheDocument();
    expect(screen.getByText("Route only")).toBeInTheDocument();
  });

  it("loads the private map chunk only after a valid availability response", async () => {
    apiMock.mockResolvedValue(privateAvailability);
    const onSelectStreamIndex = vi.fn();
    render(<ActivityRouteMap
      points={points}
      selectedStreamIndex={1}
      selectedSummary="2.00 km · 10:30"
      onSelectStreamIndex={onSelectStreamIndex}
    />);

    const privateMap = await screen.findByTestId("private-activity-map");
    expect(privateMap.dataset.styleUrl).toBe(`${window.location.origin}/api/fitness/maps/style.json`);
    fireEvent.click(screen.getByRole("button", { name: "Select private route point" }));
    expect(onSelectStreamIndex).toHaveBeenCalledWith(2);
  });

  it("uses the route-only view when an activity sits outside the private archive", async () => {
    apiMock.mockResolvedValue(privateAvailability);
    render(<ActivityRouteMap
      points={points.map((point) => ({ ...point, coordinate: [10 + point.coordinate[0], point.coordinate[1]] }))}
      selectedStreamIndex={1}
      selectedSummary="2.00 km · 10:30"
      onSelectStreamIndex={vi.fn()}
    />);

    expect(await screen.findByText("Route only")).toBeInTheDocument();
    expect(screen.queryByTestId("private-activity-map")).not.toBeInTheDocument();
  });

  it("synchronises the local fallback by pointer-independent keyboard controls", () => {
    const onSelectStreamIndex = vi.fn();
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    render(<LocalActivityRouteMap
      points={points}
      selectedStreamIndex={1}
      selectedSummary="2.00 km · 10:30"
      onSelectStreamIndex={onSelectStreamIndex}
    />);

    const surface = screen.getByRole("img", { name: /Use left and right arrow keys/ });
    fireEvent.keyDown(surface, { key: "ArrowRight" });
    expect(onSelectStreamIndex).toHaveBeenLastCalledWith(2);
    fireEvent.keyDown(surface, { key: "Home" });
    expect(onSelectStreamIndex).toHaveBeenLastCalledWith(0);
    fireEvent.click(screen.getByRole("button", { name: "Zoom in route" }));
    expect(screen.getByRole("button", { name: "Reset route view" })).toBeEnabled();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("ships no external map constant and preserves contrast, motion and touch rules", () => {
    expect(componentSource).not.toMatch(/https?:\/\//i);
    expect(privateComponentSource).toContain('href="https://www.openstreetmap.org/copyright"');
    expect(privateComponentSource).toContain('href="https://protomaps.com"');
    expect(componentSource).not.toMatch(/from\s+["']maplibre-gl/);
    expect(privateComponentSource).toMatch(/privateMapRequest/);
    expect(privateComponentSource).toMatch(/credentials:\s*"same-origin"|privateMapRequest\(url\)/);
    expect(privateComponentSource).toMatch(/\?worker&url/);
    expect(privateComponentSource).toMatch(/prefers-contrast:\s*more/);
    expect(privateComponentSource).toMatch(/prefers-reduced-motion:\s*reduce/);
    expect(privateComponentSource).toMatch(/map\.once\("idle"/);
    expect(privateComponentSource).toMatch(/"source-layer" in layer/);
    expect(privateComponentSource).toMatch(/MapFeatureKind = "water" \| "land" \| "building" \| "road" \| "other"/);
    expect(privateComponentSource).toMatch(/--fitness-map-dark-\$\{mapFeatureKind\(layer\)\}-fill/);
  });
});
