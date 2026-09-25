/**
 * Whether the database holds Overture data around a fix, and the bookkeeping
 * for fetching it when it does not: enqueueing jobs, the limits that keep one
 * user from making us download the world, and the estimate the app shows.
 */

import { and, asc, desc, eq, gte, inArray, isNotNull, sql } from "drizzle-orm";
import { config } from "../config.js";
import { database } from "../db/index.js";
import { coverageJobs } from "../db/schema.js";
import {
  cellKey,
  cellsAround,
  nearestCells,
  unionBounds,
  type Bounds,
  type Cell,
} from "./coverage-cells.js";
import { cellStatuses, markCells } from "./overture-import.js";
import { consumeRateLimit, type RateLimitRule } from "./rate-limit.js";

export type JobKind = "fix" | "city" | "seed" | "refresh";

export const JOB_PRIORITY: Record<JobKind, number> = { fix: 1, city: 2, seed: 3, refresh: 4 };

/** How far around a fix a nearby search reaches: the large-venue radius. */
export const COVERAGE_RADIUS_METERS = 2000;

export const COVERAGE_LIMITS = {
  /** `fix` jobs one user may trigger per day. City jobs are not charged to them. */
  fixJobsPerUser: { windowSeconds: 24 * 60 * 60, maxAttempts: 4 } satisfies RateLimitRule,
  /** `fix` jobs allowed pending or importing at once, across everyone. */
  maximumQueuedFixJobs: 10,
  /** Cells all on-demand jobs (`fix` and `city`) together may fetch per day. */
  cellsPerDay: 300,
  /** A city fetched whole; larger ones are trimmed to the cells nearest the fix. */
  maximumCityCells: 60,
  /** When a city cannot be found, this square around the fix is fetched instead. */
  fallbackCityRadiusMeters: 15_000,
} as const;

/** Used until enough fix jobs have run to average. */
export const DEFAULT_FIX_JOB_SECONDS = 120;
const MINIMUM_ESTIMATE_SECONDS = 60;
const RECENT_JOBS_FOR_ESTIMATE = 10;

export type CoverageStatus = "ready" | "importing" | "missing" | "failed";

export interface CoverageReport {
  status: CoverageStatus;
  /** Present while importing: when the data should be there. */
  estimatedSecondsRemaining?: number;
  /** Present when a limit stopped a fetch: when asking again may work. */
  retryAfterSeconds?: number;
}

export type CoverageJob = typeof coverageJobs.$inferSelect;

interface EnqueueOptions {
  kind: JobKind;
  cells: Cell[];
  bounds?: Bounds;
  requestedByUserId?: string | null;
  parentJobId?: string | null;
  /**
   * For a caller that runs the job itself, like the seed script: the job is
   * inserted already `importing`, so no worker can claim it between the
   * insert and a separate claiming update and run it a second time.
   */
  claimed?: boolean;
}

/**
 * Creates the job and marks its cells pending. The worker picks it up,
 * unless the job was created `claimed`.
 */
export async function enqueueJob(options: EnqueueOptions): Promise<CoverageJob> {
  const bounds = options.bounds ?? unionBounds(options.cells);
  const [job] = await database
    .insert(coverageJobs)
    .values({
      kind: options.kind,
      priority: JOB_PRIORITY[options.kind],
      west: bounds.west,
      south: bounds.south,
      east: bounds.east,
      north: bounds.north,
      requestedByUserId: options.requestedByUserId ?? null,
      parentJobId: options.parentJobId ?? null,
      overtureRelease: config.OVERTURE_RELEASE,
      ...(options.claimed ? { status: "importing", startedAt: new Date(), attempts: 1 } : {}),
    })
    .returning();
  await markCells(options.cells, "pending", null, job.id);
  return job;
}

/** Cells fetched by on-demand jobs requested in the last day. */
async function cellsFetchedToday(): Promise<number> {
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const [row] = await database
    .select({
      cells: sql<number>`coalesce(sum(
        ceil((${coverageJobs.east} - ${coverageJobs.west}) / 0.1 - 1e-9)
        * ceil((${coverageJobs.north} - ${coverageJobs.south}) / 0.1 - 1e-9)
      ), 0)::int`,
    })
    .from(coverageJobs)
    .where(and(inArray(coverageJobs.kind, ["fix", "city"]), gte(coverageJobs.requestedAt, since)));
  return row?.cells ?? 0;
}

/** How many cells the daily budget still allows. */
export async function remainingDailyCellBudget(): Promise<number> {
  return Math.max(0, COVERAGE_LIMITS.cellsPerDay - (await cellsFetchedToday()));
}

async function queuedFixJobCount(): Promise<number> {
  const [row] = await database
    .select({ count: sql<number>`count(*)::int` })
    .from(coverageJobs)
    .where(and(eq(coverageJobs.kind, "fix"), inArray(coverageJobs.status, ["pending", "importing"])));
  return row?.count ?? 0;
}

/**
 * Seconds until a fix job enqueued now would be done: the average of the
 * last few fix jobs, times the fix jobs ahead in the queue, less the time
 * the running one has already had. Never promises less than a minute.
 */
export async function estimateSecondsRemaining(jobId: string | null): Promise<number> {
  const recent = await database
    .select({
      seconds: sql<number>`extract(epoch from (${coverageJobs.completedAt} - ${coverageJobs.startedAt}))`,
    })
    .from(coverageJobs)
    .where(and(eq(coverageJobs.kind, "fix"), eq(coverageJobs.status, "ready"), isNotNull(coverageJobs.startedAt)))
    .orderBy(desc(coverageJobs.completedAt))
    .limit(RECENT_JOBS_FOR_ESTIMATE);
  const averageSeconds =
    recent.length > 0
      ? recent.reduce((total, row) => total + Number(row.seconds), 0) / recent.length
      : DEFAULT_FIX_JOB_SECONDS;

  const queue = await database
    .select({ id: coverageJobs.id, status: coverageJobs.status, startedAt: coverageJobs.startedAt })
    .from(coverageJobs)
    .where(and(eq(coverageJobs.kind, "fix"), inArray(coverageJobs.status, ["pending", "importing"])))
    .orderBy(asc(coverageJobs.priority), asc(coverageJobs.requestedAt));
  const position = jobId ? queue.findIndex((job) => job.id === jobId) : -1;
  const jobsAhead = position === -1 ? queue.length : position + 1;
  const running = queue.find((job) => job.status === "importing");
  const alreadySpent = running?.startedAt ? (Date.now() - running.startedAt.getTime()) / 1000 : 0;
  return Math.max(MINIMUM_ESTIMATE_SECONDS, Math.round(Math.max(jobsAhead, 1) * averageSeconds - alreadySpent));
}

interface DescribeCoverageParams {
  latitude: number;
  longitude: number;
  viewerUserId: string | null;
}

/**
 * Reports whether the cells a nearby search touches are loaded and, for a
 * signed-in viewer, enqueues a `fix` job for the ones that are not, within
 * the limits. Anonymous callers never trigger a download.
 */
export async function describeCoverage({
  latitude,
  longitude,
  viewerUserId,
}: DescribeCoverageParams): Promise<CoverageReport> {
  const cells = cellsAround(latitude, longitude, COVERAGE_RADIUS_METERS);
  const statuses = await cellStatuses(cells);
  const missing = cells.filter((cell) => statuses.get(cellKey(cell))?.status !== "ready");
  if (missing.length === 0) {
    return { status: "ready" };
  }

  const pending = missing.filter((cell) => statuses.get(cellKey(cell))?.status === "pending");
  if (pending.length === missing.length) {
    // Already on its way. A cell only a city or seed job is fetching still
    // reports its job; the estimate is for the fix queue, which runs first.
    const jobId = statuses.get(cellKey(pending[0]))?.jobId ?? null;
    return { status: "importing", estimatedSecondsRemaining: await estimateSecondsRemaining(jobId) };
  }

  const failed = missing.filter((cell) => statuses.get(cellKey(cell))?.status === "failed");
  if (failed.length > 0 && failed.length + pending.length === missing.length) {
    return { status: "failed" };
  }

  if (viewerUserId === null) {
    return { status: "missing" };
  }

  const toFetch = missing.filter((cell) => {
    const status = statuses.get(cellKey(cell))?.status;
    return status !== "pending" && status !== "failed";
  });

  const perUser = await consumeRateLimit("coverage-fix", viewerUserId, COVERAGE_LIMITS.fixJobsPerUser);
  if (!perUser.allowed) {
    return { status: "missing", retryAfterSeconds: perUser.retryAfterSeconds };
  }
  if ((await queuedFixJobCount()) >= COVERAGE_LIMITS.maximumQueuedFixJobs) {
    return { status: "missing", retryAfterSeconds: DEFAULT_FIX_JOB_SECONDS };
  }
  const budget = await remainingDailyCellBudget();
  if (budget < toFetch.length) {
    return { status: "missing", retryAfterSeconds: 60 * 60 };
  }

  const job = await enqueueJob({ kind: "fix", cells: toFetch, requestedByUserId: viewerUserId });
  notifyEnqueued();
  return { status: "importing", estimatedSecondsRemaining: await estimateSecondsRemaining(job.id) };
}

/**
 * The cells of a city job that may still be fetched today, nearest the fix
 * first; empty when the budget is spent or every cell is already covered.
 */
export async function planCityCells(
  candidateCells: Cell[],
  fix: { latitude: number; longitude: number },
): Promise<Cell[]> {
  const statuses = await cellStatuses(candidateCells);
  const uncovered = candidateCells.filter((cell) => {
    const status = statuses.get(cellKey(cell))?.status;
    return status !== "ready" && status !== "pending";
  });
  const budget = await remainingDailyCellBudget();
  const allowed = Math.min(uncovered.length, COVERAGE_LIMITS.maximumCityCells, budget);
  return allowed > 0 ? nearestCells(uncovered, fix.latitude, fix.longitude, allowed) : [];
}

type EnqueueListener = () => void;
const enqueueListeners = new Set<EnqueueListener>();

/** The worker in this process wakes up as soon as a job is enqueued here. */
export function onJobEnqueued(listener: EnqueueListener): () => void {
  enqueueListeners.add(listener);
  return () => enqueueListeners.delete(listener);
}

export function notifyEnqueued(): void {
  for (const listener of enqueueListeners) {
    listener();
  }
}
