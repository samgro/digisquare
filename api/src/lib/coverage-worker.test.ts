import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import type { OvertureSource } from "./overture-remote.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const remote = vi.hoisted(() => ({
  fetchPlaceFeatures: vi.fn(),
  fetchExtentFeatures: vi.fn(),
  fetchCityContaining: vi.fn(),
  closeOvertureSource: vi.fn(async () => {}),
}));
vi.mock("./overture-remote.js", () => remote);

const matching = vi.hoisted(() => ({ attachExtents: vi.fn(async () => []) }));
vi.mock("./extent-matching.js", () => matching);

const { claimNextJob, CoverageWorker, enqueueCityAround, importBounds, WORKER_LANES } = await import("./coverage-worker.js");

const dialect = new PgDialect();
const source: OvertureSource = { release: "2026-09-23.0", remote: false, parquetGlob: () => "" };
const SOMA = { west: -122.5, south: 37.7, east: -122.4, north: 37.8 };

/** The SQL of the n-th chained call named `method`. */
function sqlOf(method: string, index = 0): string {
  const call = controls.chainedCalls.filter((entry) => entry.method === method)[index];
  return dialect.sqlToQuery(call.arguments[0] as SQL).sql;
}

beforeEach(() => {
  controls.reset();
  remote.fetchPlaceFeatures.mockReset().mockResolvedValue(0);
  remote.fetchExtentFeatures.mockReset().mockResolvedValue([]);
  remote.fetchCityContaining.mockReset().mockResolvedValue(null);
});

describe("importBounds", () => {
  it("reports the places ready before it fetches the venue grounds", async () => {
    const order: string[] = [];
    remote.fetchExtentFeatures.mockImplementation(async () => {
      order.push("extents");
      return [];
    });
    controls.queue([]); // retire

    await importBounds(source, SOMA, () => {}, async () => {
      order.push("ready");
    });

    expect(order).toEqual(["ready", "extents"]);
  });
});

describe("claimNextJob", () => {
  it("claims any pending job by default", async () => {
    controls.queue([]);
    await claimNextJob();
    expect(sqlOf("where")).not.toContain('"kind" in');
  });

  it("can be limited to a lane's kinds", async () => {
    controls.queue([]);
    await claimNextJob(["fix"]);
    expect(sqlOf("where")).toMatch(/"coverage_jobs"\."kind" in \(\$\d+\)/);
  });
});

describe("CoverageWorker", () => {
  it("runs a lane for fix jobs and a lane for everything else", async () => {
    // housekeeping: stale jobs, refresh scan; then one claim per lane
    controls.queue([], [], [], []);
    const worker = new CoverageWorker({ source, pollIntervalMs: 5 });

    worker.start();
    await vi.waitFor(() => expect(controls.chainedCalls.filter((call) => call.method === "where").length).toBeGreaterThanOrEqual(3));
    worker.stop();

    const claims = controls.chainedCalls
      .filter((call) => call.method === "where")
      .map((call) => dialect.sqlToQuery(call.arguments[0] as SQL))
      .filter((query) => query.sql.includes("for update skip locked"));
    const lanes = new Set(
      claims.map((query) =>
        JSON.stringify(query.params.filter((param) => typeof param === "string" && WORKER_LANES.flat().includes(param as never))),
      ),
    );
    expect([...lanes].sort()).toEqual(WORKER_LANES.map((kinds) => JSON.stringify(kinds)).sort());
  });
});

describe("enqueueCityAround", () => {
  const fixJob = {
    id: "fix-1",
    kind: "fix",
    west: -122.5,
    south: 37.7,
    east: -122.4,
    north: 37.8,
    requestedByUserId: "user-1",
  } as Parameters<typeof enqueueCityAround>[1];

  it("enqueues one small job per tile, the tile around the fix first", async () => {
    remote.fetchCityContaining.mockResolvedValue({
      name: "San Francisco",
      subtype: "county",
      bounds: { west: -122.7, south: 37.6, east: -122.3, north: 37.9 },
    });
    // planCityCells: cell statuses (the fix cell is ready), then the budget;
    // then one batch (job + cells) per tile.
    controls.queue([{ cellX: -1225, cellY: 377, status: "ready" }], [{ cells: 0 }]);
    for (let index = 0; index < 8; index += 1) {
      controls.queue([{ id: `city-${index}` }], []);
    }

    const jobs = await enqueueCityAround(source, fixJob);

    expect(jobs.length).toBeGreaterThan(1);
    const inserted = controls.chainedCalls
      .filter((call) => call.method === "values")
      .map((call) => call.arguments[0] as { kind?: string; west?: number; east?: number; south?: number; north?: number } | unknown[])
      .filter((value): value is { kind: string; west: number; east: number; south: number; north: number } => !Array.isArray(value) && value.kind === "city");
    expect(inserted.length).toBe(jobs.length);
    // No tile is bigger than 2 x 2 cells.
    expect(inserted.every((job) => job.east - job.west <= 0.2 + 1e-9 && job.north - job.south <= 0.2 + 1e-9)).toBe(true);
    // The first tile is the one the fix's own cell (-122.45, 37.75) sits in.
    expect(inserted[0].west).toBeLessThanOrEqual(-122.45);
    expect(inserted[0].east).toBeGreaterThanOrEqual(-122.45);
    expect(inserted[0].south).toBeLessThanOrEqual(37.75);
    expect(inserted[0].north).toBeGreaterThanOrEqual(37.75);
  });
});
