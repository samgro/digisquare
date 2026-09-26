import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import type { ParsedExtent } from "./overture-extents.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { attachExtents, EXTENT_CHUNK_SIZE } = await import("./extent-matching.js");

const dialect = new PgDialect();

function extent(overtureId: string, name: string, family: ParsedExtent["family"] = "park"): ParsedExtent {
  return {
    overtureId,
    name,
    family,
    polygons: [[[[-122.51, 37.76], [-122.45, 37.76], [-122.45, 37.77], [-122.51, 37.77], [-122.51, 37.76]]]],
  };
}

function candidate(extentIndex: number, id: string, name: string, centroidDistanceMeters: number) {
  return { extentIndex, id, name, centroidDistanceMeters, areaSquareMeters: 4_000_000 };
}

/** The JSON payload the n-th `execute` sent, parsed. */
function payloadOfExecute(callIndex: number): unknown[] {
  const statement = (database.execute as ReturnType<typeof vi.fn>).mock.calls[callIndex][0] as SQL;
  const [payload] = dialect.sqlToQuery(statement).params;
  return JSON.parse(payload as string) as unknown[];
}

beforeEach(() => {
  controls.reset();
  (database.execute as ReturnType<typeof vi.fn>).mockClear();
});

describe("attachExtents", () => {
  it("prefers the candidate whose name matches over a nearer one", async () => {
    controls.queue(
      { rows: [candidate(0, "polo-field", "Polo Field", 20), candidate(0, "ggp", "Golden Gate Park", 900)] },
      { rows: [{ id: "ggp", extentOvertureId: "park-1" }] },
    );

    const attached = await attachExtents([extent("park-1", "Golden Gate Park")]);

    expect(attached).toEqual([{ extent: extent("park-1", "Golden Gate Park"), placeId: "ggp", placeName: "Golden Gate Park" }]);
    expect(payloadOfExecute(1)).toEqual([
      expect.objectContaining({ place_id: "ggp", overture_id: "park-1", area_square_meters: 4_000_000 }),
    ]);
  });

  it("falls back to the nearest candidate when no name matches", async () => {
    controls.queue(
      { rows: [candidate(0, "nearest", "Rose Garden", 15), candidate(0, "farther", "Botanical Garden", 300)] },
      { rows: [{ id: "nearest", extentOvertureId: "park-2" }] },
    );

    const attached = await attachExtents([extent("park-2", "Some Unnamed Green")]);

    expect(attached.map((attachment) => attachment.placeId)).toEqual(["nearest"]);
  });

  it("sends the family's categories with each polygon and skips the update when nothing matched", async () => {
    controls.queue({ rows: [] });

    const attached = await attachExtents([extent("apt-1", "SFO", "airport")]);

    expect(attached).toEqual([]);
    expect(controls.operations).toEqual(["execute"]);
    expect(payloadOfExecute(0)).toEqual([
      expect.objectContaining({
        index: 0,
        categories: ["airport", "airport_terminal", "major_airports", "domestic_airports"],
        suffixes: ["_airports"],
      }),
    ]);
  });

  it("only reports polygons the update actually wrote", async () => {
    // Two polygons chose the same place; the database kept the larger.
    controls.queue(
      { rows: [candidate(0, "ggp", "Golden Gate Park", 10), candidate(1, "ggp", "Golden Gate Park", 40)] },
      { rows: [{ id: "ggp", extentOvertureId: "park-big" }] },
    );

    const attached = await attachExtents([extent("park-big", "Golden Gate Park"), extent("park-small", "Golden Gate Park")]);

    expect(attached.map((attachment) => attachment.extent.overtureId)).toEqual(["park-big"]);
  });

  it("works in chunks and reports progress after each", async () => {
    const extents = Array.from({ length: EXTENT_CHUNK_SIZE + 1 }, (_, index) => extent(`park-${index}`, `Park ${index}`));
    controls.queue(
      { rows: [candidate(0, "place-0", "Park 0", 5)] },
      { rows: [{ id: "place-0", extentOvertureId: "park-0" }] },
      { rows: [] },
    );
    const progress: unknown[] = [];

    await attachExtents(extents, (update) => progress.push(update));

    expect(controls.operations).toEqual(["execute", "execute", "execute"]);
    expect(payloadOfExecute(0)).toHaveLength(EXTENT_CHUNK_SIZE);
    expect(payloadOfExecute(2)).toHaveLength(1);
    expect(progress).toEqual([
      { matched: EXTENT_CHUNK_SIZE, total: EXTENT_CHUNK_SIZE + 1, attached: 1 },
      { matched: EXTENT_CHUNK_SIZE + 1, total: EXTENT_CHUNK_SIZE + 1, attached: 1 },
    ]);
  });
});
