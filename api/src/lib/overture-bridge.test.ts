import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";

const { database, controls } = createDatabaseStub();
vi.mock("../db/index.js", () => ({ database }));

const { writeProviderCounts, writeVenueMatches } = await import("./overture-bridge.js");

beforeEach(() => {
  controls.reset();
});

describe("writeProviderCounts", () => {
  it("writes nothing when there is nothing to write", async () => {
    expect(await writeProviderCounts(new Map())).toBe(0);
    expect(controls.operations).toEqual([]);
  });

  it("updates in batches of a thousand and adds up the rows that changed", async () => {
    const counts = new Map<string, number>();
    for (let index = 0; index < 1500; index += 1) {
      counts.set(`place-${index}`, 1 + (index % 4));
    }
    controls.queue({ rowCount: 700 }, { rowCount: 120 });

    expect(await writeProviderCounts(counts)).toBe(820);
    expect(controls.operations).toEqual(["execute", "execute"]);
  });
});

describe("writeVenueMatches", () => {
  it("points each venue at its Overture place", async () => {
    controls.queue({ rowCount: 1 });

    expect(await writeVenueMatches(new Map([["4b8c1a2bf964a52056af32e3", "gers-1"]]))).toBe(1);
    expect(controls.operations).toEqual(["execute"]);
  });
});
