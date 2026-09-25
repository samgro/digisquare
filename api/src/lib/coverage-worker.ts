/**
 * Runs coverage jobs one at a time: fetches an area's places and venue
 * grounds from the Overture release files, writes them, marks the cells
 * ready, and after a user's `fix` job grows the fetch to their whole city.
 * Also rolls ready cells to a newer release when `OVERTURE_RELEASE` changes.
 *
 * Runs inside the API process (Railway has no separate worker), claiming
 * jobs with a single atomic update so a second instance never runs the same
 * one. Priority order is what keeps a waiting user ahead of a city or a
 * seed.
 */

import { and, asc, eq, inArray, isNull, lt, ne, or, sql } from "drizzle-orm";
import { config } from "../config.js";
import { database } from "../db/index.js";
import { coverageCells, coverageJobs } from "../db/schema.js";
import {
  boundsOfCircle,
  cellCountInBounds,
  cellKey,
  cellsInBounds,
  groupCellsIntoTiles,
  type Bounds,
  type Cell,
} from "./coverage-cells.js";
import {
  COVERAGE_LIMITS,
  enqueueJob,
  notifyEnqueued,
  onJobEnqueued,
  planCityCells,
  type CoverageJob,
} from "./coverage.js";
import { attachExtents } from "./extent-matching.js";
import { parseOverturePlace, type OverturePlaceInsert } from "./overture.js";
import { parseOvertureExtent, type ParsedExtent } from "./overture-extents.js";
import {
  cellStatuses,
  markCells,
  retirePlacesMissingFrom,
  upsertOverturePlaces,
  UPSERT_BATCH_SIZE,
} from "./overture-import.js";
import {
  closeOvertureSource,
  fetchCityContaining,
  fetchExtentFeatures,
  fetchPlaceFeatures,
  type OvertureSource,
} from "./overture-remote.js";

const MAXIMUM_ATTEMPTS = 3;
const STALE_IMPORT_MINUTES = 30;
const RETRY_DELAY_MINUTES = 5;
const REFRESH_SCAN_INTERVAL_MS = 60 * 60 * 1000;

export interface JobOutcome {
  placeCount: number;
  changedCount: number;
  retiredCount: number;
  extentCount: number;
}

function boundsOf(job: CoverageJob): Bounds {
  return { west: job.west, south: job.south, east: job.east, north: job.north };
}

/**
 * Fetches and writes everything for `bounds`. Shared by the worker and the
 * seed and refresh scripts, which run jobs inline.
 */
export async function importBounds(
  source: OvertureSource,
  bounds: Bounds,
  log: (message: string) => void = () => {},
): Promise<JobOutcome> {
  let placeCount = 0;
  let changedCount = 0;
  const total = await fetchPlaceFeatures(
    source,
    bounds,
    async (features) => {
      const rows: OverturePlaceInsert[] = [];
      for (const feature of features) {
        const parsed = parseOverturePlace(feature);
        if (parsed.row) {
          rows.push(parsed.row);
        }
      }
      const outcome = await upsertOverturePlaces(rows, source.release);
      placeCount += outcome.seen;
      changedCount += outcome.changed;
      log(`${placeCount} places`);
    },
    UPSERT_BATCH_SIZE,
  );
  log(`${total} rows read, ${placeCount} places kept, ${changedCount} changed`);

  log("fetching venue grounds");
  const extents = (await fetchExtentFeatures(source, bounds))
    .map(parseOvertureExtent)
    .filter((extent): extent is ParsedExtent => extent !== null);
  log(`${extents.length} venue grounds to match`);
  const attached = await attachExtents(extents, ({ matched, total, attached: attachedSoFar }) => {
    if (matched < total) {
      log(`matched ${matched} of ${total} venue grounds, ${attachedSoFar} attached`);
    }
  });
  log(`${attached.length} of ${extents.length} venue grounds attached`);

  const retiredCount = await retirePlacesMissingFrom(bounds, source.release);
  if (retiredCount > 0) {
    log(`${retiredCount} places retired`);
  }
  return { placeCount, changedCount, retiredCount, extentCount: attached.length };
}

/**
 * Claims the oldest pending job of the highest priority, skipping jobs that
 * failed within the last few minutes so a persistent failure does not spin.
 */
export async function claimNextJob(): Promise<CoverageJob | null> {
  const retryBefore = new Date(Date.now() - RETRY_DELAY_MINUTES * 60 * 1000);
  const [job] = await database
    .update(coverageJobs)
    .set({ status: "importing", startedAt: new Date(), attempts: sql`${coverageJobs.attempts} + 1` })
    .where(
      and(
        eq(coverageJobs.status, "pending"),
        eq(
          coverageJobs.id,
          sql`(select id from ${coverageJobs}
               where ${coverageJobs.status} = 'pending'
                 and (${coverageJobs.attempts} = 0 or ${coverageJobs.startedAt} is null or ${coverageJobs.startedAt} < ${retryBefore})
               order by ${coverageJobs.priority}, ${coverageJobs.requestedAt}
               limit 1 for update skip locked)`,
        ),
      ),
    )
    .returning();
  return job ?? null;
}

async function finishJob(job: CoverageJob, outcome: JobOutcome): Promise<void> {
  const cells = cellsInBounds(boundsOf(job));
  await markCells(cells, "ready", job.overtureRelease, job.id);
  await database
    .update(coverageJobs)
    .set({
      status: "ready",
      completedAt: new Date(),
      placeCount: outcome.placeCount,
      extentCount: outcome.extentCount,
      lastError: null,
    })
    .where(eq(coverageJobs.id, job.id));
}

async function failJob(job: CoverageJob, error: unknown): Promise<void> {
  const message = error instanceof Error ? error.message : String(error);
  const exhausted = job.attempts >= MAXIMUM_ATTEMPTS;
  await database
    .update(coverageJobs)
    .set({ status: exhausted ? "failed" : "pending", lastError: message.slice(0, 2000) })
    .where(eq(coverageJobs.id, job.id));
  if (exhausted) {
    await markCells(cellsInBounds(boundsOf(job)), "failed", null, job.id);
  }
}

/**
 * After a fix job, the city around it. Overture's division areas give the
 * city polygon; its bounding box is fetched whole when it is at most 60
 * cells, else trimmed to the cells nearest the fix. With no city found, a
 * 15 km square around the fix stands in.
 */
export async function enqueueCityAround(source: OvertureSource, fixJob: CoverageJob): Promise<CoverageJob | null> {
  const center = {
    latitude: (fixJob.south + fixJob.north) / 2,
    longitude: (fixJob.west + fixJob.east) / 2,
  };
  let cityBounds: Bounds | null = null;
  try {
    cityBounds = (await fetchCityContaining(source, center))?.bounds ?? null;
  } catch (error) {
    console.error("Could not look up the city around a fix; using a square instead", error);
  }
  if (cityBounds === null || cellCountInBounds(cityBounds) > COVERAGE_LIMITS.maximumCityCells) {
    cityBounds = boundsOfCircle(center.latitude, center.longitude, COVERAGE_LIMITS.fallbackCityRadiusMeters);
  }
  const cells = await planCityCells(cellsInBounds(cityBounds), center);
  if (cells.length === 0) {
    return null;
  }
  return enqueueJob({ kind: "city", cells, requestedByUserId: fixJob.requestedByUserId, parentJobId: fixJob.id });
}

/** Runs one claimed job to completion, whatever the outcome. */
export async function runJob(source: OvertureSource, job: CoverageJob): Promise<void> {
  const label = `${job.kind} job ${job.id}`;
  try {
    const outcome = await importBounds(source, boundsOf(job), (message) => console.log(`[coverage] ${label}: ${message}`));
    await finishJob(job, outcome);
    if (job.kind === "fix") {
      const city = await enqueueCityAround(source, job);
      if (city) {
        console.log(`[coverage] ${label}: enqueued city job ${city.id}`);
      }
    }
  } catch (error) {
    console.error(`[coverage] ${label} failed`, error);
    await failJob(job, error);
  }
}

/**
 * Fetches the cells here and now rather than through the queue, for scripts
 * that want to watch the load finish. Cells already ready at the current
 * release are skipped; returns false when there was nothing to fetch.
 */
export async function seedCellsNow(source: OvertureSource, cells: Cell[], bounds?: Bounds): Promise<boolean> {
  const statuses = await cellStatuses(cells);
  const done = cells.every((cell) => {
    const status = statuses.get(cellKey(cell));
    return status?.status === "ready" && status.overtureRelease === config.OVERTURE_RELEASE;
  });
  if (done) {
    return false;
  }
  const job = await enqueueJob({ kind: "seed", cells, bounds, claimed: true });
  await runJob(source, job);
  return true;
}

/** Jobs left `importing` by a crashed instance go back to the queue. */
export async function recoverStaleJobs(): Promise<number> {
  const cutoff = new Date(Date.now() - STALE_IMPORT_MINUTES * 60 * 1000);
  const recovered = await database
    .update(coverageJobs)
    .set({ status: "pending" })
    .where(and(eq(coverageJobs.status, "importing"), or(isNull(coverageJobs.startedAt), lt(coverageJobs.startedAt, cutoff))))
    .returning({ id: coverageJobs.id });
  return recovered.length;
}

/**
 * Ready cells recorded under an older release than the configured one,
 * grouped into 1 degree tiles, one refresh job each. Cells already in a
 * pending job are left to it.
 */
export async function scheduleRefreshJobs(): Promise<CoverageJob[]> {
  const stale = await database
    .select({ cellX: coverageCells.cellX, cellY: coverageCells.cellY })
    .from(coverageCells)
    .where(
      and(
        eq(coverageCells.status, "ready"),
        or(isNull(coverageCells.overtureRelease), ne(coverageCells.overtureRelease, config.OVERTURE_RELEASE)),
      ),
    )
    .orderBy(asc(coverageCells.readyAt));
  const jobs: CoverageJob[] = [];
  for (const tile of groupCellsIntoTiles(stale)) {
    jobs.push(await enqueueJob({ kind: "refresh", cells: tile.cells, bounds: tile.bounds }));
  }
  if (jobs.length > 0) {
    notifyEnqueued();
  }
  return jobs;
}

export interface CoverageWorkerOptions {
  source: OvertureSource;
  pollIntervalMs?: number;
}

/**
 * The loop: claim a job, run it, repeat; when the queue is empty, wait for
 * an enqueue in this process or the poll interval, whichever comes first.
 */
export class CoverageWorker {
  private running = false;
  private wake: (() => void) | null = null;
  private unsubscribe: (() => void) | null = null;
  private refreshTimer: NodeJS.Timeout | null = null;

  constructor(private readonly options: CoverageWorkerOptions) {}

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.unsubscribe = onJobEnqueued(() => this.wake?.());
    this.refreshTimer = setInterval(() => {
      scheduleRefreshJobs().catch((error) => console.error("[coverage] refresh scan failed", error));
    }, REFRESH_SCAN_INTERVAL_MS);
    void this.loop();
  }

  stop(): void {
    this.running = false;
    this.unsubscribe?.();
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer);
    }
    this.wake?.();
    void closeOvertureSource(this.options.source);
  }

  private async loop(): Promise<void> {
    try {
      const recovered = await recoverStaleJobs();
      if (recovered > 0) {
        console.log(`[coverage] re-queued ${recovered} interrupted jobs`);
      }
      await scheduleRefreshJobs();
    } catch (error) {
      console.error("[coverage] startup housekeeping failed", error);
    }
    while (this.running) {
      let job: CoverageJob | null = null;
      try {
        job = await claimNextJob();
      } catch (error) {
        console.error("[coverage] could not claim a job", error);
      }
      if (job) {
        await runJob(this.options.source, job);
        continue;
      }
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, this.options.pollIntervalMs ?? 15_000);
        this.wake = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      this.wake = null;
    }
  }
}

/** Cells and jobs marked failed go back to the queue. */
export async function retryFailedJobs(): Promise<number> {
  const retried = await database
    .update(coverageJobs)
    .set({ status: "pending", attempts: 0, lastError: null })
    .where(eq(coverageJobs.status, "failed"))
    .returning({ id: coverageJobs.id });
  if (retried.length > 0) {
    await database
      .update(coverageCells)
      .set({ status: "pending" })
      .where(inArray(coverageCells.jobId, retried.map((job) => job.id)));
  }
  return retried.length;
}
