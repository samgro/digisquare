import { describe, expect, it } from "vitest";
import {
  boundsOfCircle,
  cellBounds,
  cellForPoint,
  cellsAround,
  cellsInBounds,
  groupCellsIntoTiles,
  nearestCells,
  unionBounds,
} from "./coverage-cells.js";

describe("coverage cells", () => {
  it("maps a point to its cell and back to bounds that contain it", () => {
    const cell = cellForPoint(37.7863, -122.4003);
    expect(cell).toEqual({ cellX: -1225, cellY: 377 });
    expect(cellBounds(cell)).toEqual({ west: -122.5, south: 37.7, east: -122.4, north: 37.8 });
  });

  it("handles negative coordinates without rounding towards zero", () => {
    expect(cellForPoint(-0.05, -0.05)).toEqual({ cellX: -1, cellY: -1 });
  });

  it("touches one cell for a small circle in the middle of a cell", () => {
    expect(cellsAround(37.75, -122.45, 1500)).toEqual([{ cellX: -1225, cellY: 377 }]);
  });

  it("touches the neighbours when the circle crosses a cell edge, at most four", () => {
    const cells = cellsAround(37.799, -122.401, 2000);
    expect(cells).toHaveLength(4);
    expect(cells).toContainEqual({ cellX: -1225, cellY: 377 });
    expect(cells).toContainEqual({ cellX: -1224, cellY: 378 });
  });

  it("does not include the next cell when the box ends exactly on a boundary", () => {
    expect(cellsInBounds({ west: -122.5, south: 37.7, east: -122.4, north: 37.8 })).toHaveLength(1);
  });

  it("clamps a circle's bounds to the world", () => {
    const bounds = boundsOfCircle(89.99, 179.99, 50_000);
    expect(bounds.north).toBe(90);
    expect(bounds.east).toBe(180);
  });

  it("unions cell bounds and groups cells into 1 degree tiles", () => {
    const cells = cellsInBounds({ west: -122.55, south: 37.65, east: -121.95, north: 37.95 });
    expect(unionBounds(cells)).toEqual({ west: -122.6, south: 37.6, east: -121.9, north: 38 });
    const tiles = groupCellsIntoTiles(cells);
    expect(tiles.map((tile) => tile.cells.length).reduce((total, count) => total + count, 0)).toBe(cells.length);
    // -122.6..-121.9 spans the -123..-122 and -122..-121 tiles.
    expect(tiles).toHaveLength(2);
  });

  it("keeps the cells nearest a point", () => {
    const cells = cellsInBounds({ west: -123, south: 37, east: -122, north: 38 });
    const nearest = nearestCells(cells, 37.75, -122.45, 4);
    expect(nearest).toHaveLength(4);
    expect(nearest[0]).toEqual({ cellX: -1225, cellY: 377 });
  });
});
