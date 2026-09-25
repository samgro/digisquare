import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { COVERAGE_LIMITS, describeCoverage, enqueueJob, estimateSecondsRemaining, onJobEnqueued, planCityCells } =
  await import("./coverage.js");

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const JOB_ID = "990e8400-e29b-41d4-a716-446655440000";
// Mid-cell, so a 2 km circle touches exactly one cell.
const FIX = { latitude: 37.75, longitude: -122.45 };

function cellRow(status: "pending" | "ready" | "failed", jobId: string | null = null) {
  return { cellX: -1225, cellY: 377, status, jobId, overtureRelease: "2026-09-23.0", readyAt: null, updatedAt: new Date() };
}

beforeEach(() => {
  controls.reset();
});

describe("describeCoverage", () => {
  it("is ready when every cell the search touches is ready", async () => {
    controls.queue([cellRow("ready")]);
    expect(await describeCoverage({ ...FIX, viewerUserId: null })).toEqual({ status: "ready" });
    expect(controls.operations).toEqual(["select"]);
  });

  it("is missing for an anonymous caller and enqueues nothing", async () => {
    controls.queue([]);
    expect(await describeCoverage({ ...FIX, viewerUserId: null })).toEqual({ status: "missing" });
    expect(controls.operations).toEqual(["select"]);
  });

  it("reports an import already under way with an estimate", async () => {
    controls.queue(
      [cellRow("pending", JOB_ID)],
      // estimate: recent fix durations, then the queue
      [{ seconds: 100 }, { seconds: 140 }],
      [{ id: JOB_ID, status: "importing", startedAt: new Date(Date.now() - 30_000) }],
    );
    const report = await describeCoverage({ ...FIX, viewerUserId: USER_ID });
    expect(report.status).toBe("importing");
    // one job ahead (itself) x 120 s average, minus the 30 s already run
    expect(report.estimatedSecondsRemaining).toBe(90);
  });

  it("is failed when the fetch gave up", async () => {
    controls.queue([cellRow("failed")]);
    expect(await describeCoverage({ ...FIX, viewerUserId: USER_ID })).toEqual({ status: "failed" });
  });

  it("enqueues a fix job for a signed-in caller within the limits and wakes the worker", async () => {
    const woken = vi.fn();
    const unsubscribe = onJobEnqueued(woken);
    controls.queue(
      [], // cell statuses: nothing known
      [{ attemptCount: 1 }], // per-user rate limit
      [{ count: 0 }], // queued fix jobs
      [{ cells: 0 }], // cells fetched today
      [{ id: JOB_ID, kind: "fix" }], // inserted job (first statement of the batch)
      [], // markCells upsert (second statement of the batch)
      [{ seconds: 120 }], // estimate: recent durations
      [{ id: JOB_ID, status: "pending", startedAt: null }], // queue
    );

    const report = await describeCoverage({ ...FIX, viewerUserId: USER_ID });
    unsubscribe();

    expect(report).toEqual({ status: "importing", estimatedSecondsRemaining: 120 });
    expect(controls.operations).toEqual(["select", "insert", "select", "select", "insert", "insert", "batch", "select", "select"]);
    expect(woken).toHaveBeenCalledTimes(1);
  });

  it("refuses a caller over their daily allowance with a retry-after", async () => {
    controls.queue([], [{ attemptCount: COVERAGE_LIMITS.fixJobsPerUser.maxAttempts + 1 }]);
    const report = await describeCoverage({ ...FIX, viewerUserId: USER_ID });
    expect(report.status).toBe("missing");
    expect(report.retryAfterSeconds).toBeGreaterThan(0);
    expect(controls.operations).toEqual(["select", "insert"]);
  });

  it("refuses when the fix queue is full", async () => {
    controls.queue([], [{ attemptCount: 1 }], [{ count: COVERAGE_LIMITS.maximumQueuedFixJobs }]);
    const report = await describeCoverage({ ...FIX, viewerUserId: USER_ID });
    expect(report).toMatchObject({ status: "missing" });
    expect(controls.operations).toEqual(["select", "insert", "select"]);
  });

  it("refuses when the daily cell budget is spent", async () => {
    controls.queue([], [{ attemptCount: 1 }], [{ count: 0 }], [{ cells: COVERAGE_LIMITS.cellsPerDay }]);
    const report = await describeCoverage({ ...FIX, viewerUserId: USER_ID });
    expect(report).toEqual({ status: "missing", retryAfterSeconds: 3600 });
  });
});

describe("enqueueJob", () => {
  const CELL = { cellX: -1225, cellY: 377 };

  function insertedJob() {
    return controls.chainedCalls.find((call) => call.method === "values")?.arguments[0];
  }

  it("leaves a job pending for the worker by default", async () => {
    controls.queue([{ id: JOB_ID }], []);
    await enqueueJob({ kind: "fix", cells: [CELL] });
    expect(insertedJob()).not.toHaveProperty("status");
  });

  it("writes the job and its pending cells in one batch, under an id made here", async () => {
    controls.queue([{ id: JOB_ID }], []);
    const job = await enqueueJob({ kind: "fix", cells: [CELL] });
    expect(job).toEqual({ id: JOB_ID });
    expect(controls.operations).toEqual(["insert", "insert", "batch"]);
    const jobRow = insertedJob() as { id: string };
    expect(jobRow.id).toMatch(/^[0-9a-f-]{36}$/);
    const cellRows = controls.chainedCalls.filter((call) => call.method === "values")[1].arguments[0] as { jobId: string }[];
    expect(cellRows[0].jobId).toBe(jobRow.id);
  });

  it("inserts an already-claimed job as importing, so no worker can claim it too", async () => {
    controls.queue([{ id: JOB_ID }], []);
    await enqueueJob({ kind: "seed", cells: [CELL], claimed: true });
    expect(insertedJob()).toMatchObject({ status: "importing", attempts: 1, startedAt: expect.any(Date) });
    // One insert: there is no separate claiming update for a worker to race.
    expect(controls.operations.filter((operation) => operation === "update")).toEqual([]);
  });
});

describe("estimateSecondsRemaining", () => {
  it("uses the default duration before any fix job has finished and never promises under a minute", async () => {
    controls.queue([], []);
    expect(await estimateSecondsRemaining(null)).toBe(120);
    controls.queue([{ seconds: 10 }], []);
    expect(await estimateSecondsRemaining(null)).toBe(60);
  });

  it("multiplies by the jobs ahead in the queue", async () => {
    controls.queue(
      [{ seconds: 100 }],
      [
        { id: "a", status: "pending", startedAt: null },
        { id: "b", status: "pending", startedAt: null },
        { id: JOB_ID, status: "pending", startedAt: null },
      ],
    );
    expect(await estimateSecondsRemaining(JOB_ID)).toBe(300);
  });
});

describe("planCityCells", () => {
  const cells = Array.from({ length: 100 }, (_, index) => ({ cellX: -1230 + (index % 10), cellY: 370 + Math.floor(index / 10) }));

  it("drops covered cells, caps at the city maximum and keeps the nearest", async () => {
    controls.queue([cellRow("ready")], [{ cells: 0 }]);
    const planned = await planCityCells(cells, FIX);
    expect(planned).toHaveLength(COVERAGE_LIMITS.maximumCityCells);
    expect(planned).not.toContainEqual({ cellX: -1225, cellY: 377 });
    // Every neighbour is one cell away; the first in grid order wins the tie.
    expect(planned[0]).toEqual({ cellX: -1225, cellY: 376 });
  });

  it("is limited by what is left of the daily budget", async () => {
    controls.queue([], [{ cells: COVERAGE_LIMITS.cellsPerDay - 5 }]);
    expect(await planCityCells(cells, FIX)).toHaveLength(5);
    controls.queue([], [{ cells: COVERAGE_LIMITS.cellsPerDay }]);
    expect(await planCityCells(cells, FIX)).toEqual([]);
  });
});
