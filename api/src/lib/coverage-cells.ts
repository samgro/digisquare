/**
 * The world is cut into fixed 0.1 degree cells (about 11 km north to south
 * and 8 to 9 km east to west at mid latitudes). A cell is the unit of "do we
 * have Overture data here"; fetch jobs cover a bounding box of one or more
 * cells. Pure, so it is unit-tested without a database.
 */

export const CELL_SIZE_DEGREES = 0.1;

export interface Cell {
  cellX: number;
  cellY: number;
}

export interface Bounds {
  west: number;
  south: number;
  east: number;
  north: number;
}

const METERS_PER_DEGREE_LATITUDE = 111_320;

export function cellForPoint(latitude: number, longitude: number): Cell {
  return {
    cellX: Math.floor(longitude / CELL_SIZE_DEGREES),
    cellY: Math.floor(latitude / CELL_SIZE_DEGREES),
  };
}

export function cellBounds(cell: Cell): Bounds {
  // Rounded to avoid 0.30000000000000004 leaking into stored bounds.
  const round = (value: number) => Math.round(value * 1e6) / 1e6;
  return {
    west: round(cell.cellX * CELL_SIZE_DEGREES),
    south: round(cell.cellY * CELL_SIZE_DEGREES),
    east: round((cell.cellX + 1) * CELL_SIZE_DEGREES),
    north: round((cell.cellY + 1) * CELL_SIZE_DEGREES),
  };
}

export function cellKey(cell: Cell): string {
  return `${cell.cellX}:${cell.cellY}`;
}

/** The bounding box of a circle, clamped to the world. */
export function boundsOfCircle(latitude: number, longitude: number, radiusMeters: number): Bounds {
  const latitudeDelta = radiusMeters / METERS_PER_DEGREE_LATITUDE;
  const metersPerDegreeLongitude =
    METERS_PER_DEGREE_LATITUDE * Math.max(Math.cos((latitude * Math.PI) / 180), 0.01);
  const longitudeDelta = radiusMeters / metersPerDegreeLongitude;
  return {
    west: Math.max(-180, longitude - longitudeDelta),
    south: Math.max(-90, latitude - latitudeDelta),
    east: Math.min(180, longitude + longitudeDelta),
    north: Math.min(90, latitude + latitudeDelta),
  };
}

/** Every cell that intersects the bounds, west to east then south to north. */
export function cellsInBounds(bounds: Bounds): Cell[] {
  const first = cellForPoint(bounds.south, bounds.west);
  // A box whose edge lands exactly on a cell boundary does not include the
  // next cell over, hence the tiny nudge inwards.
  const last = cellForPoint(bounds.north - 1e-9, bounds.east - 1e-9);
  const cells: Cell[] = [];
  for (let cellY = first.cellY; cellY <= Math.max(first.cellY, last.cellY); cellY += 1) {
    for (let cellX = first.cellX; cellX <= Math.max(first.cellX, last.cellX); cellX += 1) {
      cells.push({ cellX, cellY });
    }
  }
  return cells;
}

/** The cells a nearby search around a fix touches. */
export function cellsAround(latitude: number, longitude: number, radiusMeters: number): Cell[] {
  return cellsInBounds(boundsOfCircle(latitude, longitude, radiusMeters));
}

export function unionBounds(cells: Cell[]): Bounds {
  if (cells.length === 0) {
    throw new Error("Cannot take the bounds of no cells");
  }
  const all = cells.map(cellBounds);
  return {
    west: Math.min(...all.map((bounds) => bounds.west)),
    south: Math.min(...all.map((bounds) => bounds.south)),
    east: Math.max(...all.map((bounds) => bounds.east)),
    north: Math.max(...all.map((bounds) => bounds.north)),
  };
}

export function boundsIntersect(first: Bounds, second: Bounds): boolean {
  return (
    first.west < second.east &&
    first.east > second.west &&
    first.south < second.north &&
    first.north > second.south
  );
}

/** Rough area, for deciding whether a city is too big to fetch whole. */
export function cellCountInBounds(bounds: Bounds): number {
  return cellsInBounds(bounds).length;
}

/**
 * Groups cells into 1 degree tiles (10 x 10 cells), the unit a seed or a
 * refresh fetches in one query. Returns the tiles in row order with the
 * cells each one holds.
 */
export function groupCellsIntoTiles(cells: Cell[]): { bounds: Bounds; cells: Cell[] }[] {
  const tiles = new Map<string, Cell[]>();
  for (const cell of cells) {
    const tileX = Math.floor(cell.cellX / 10);
    const tileY = Math.floor(cell.cellY / 10);
    const key = `${tileX}:${tileY}`;
    tiles.set(key, [...(tiles.get(key) ?? []), cell]);
  }
  return [...tiles.values()].map((tileCells) => ({ bounds: unionBounds(tileCells), cells: tileCells }));
}

/**
 * The `count` cells nearest a point, for trimming a city that would exceed
 * the daily budget to the part around where the user actually is.
 */
export function nearestCells(cells: Cell[], latitude: number, longitude: number, count: number): Cell[] {
  const origin = cellForPoint(latitude, longitude);
  return [...cells]
    .sort((first, second) => {
      const firstDistance = (first.cellX - origin.cellX) ** 2 + (first.cellY - origin.cellY) ** 2;
      const secondDistance = (second.cellX - origin.cellX) ** 2 + (second.cellY - origin.cellY) ** 2;
      return firstDistance - secondDistance;
    })
    .slice(0, count);
}
