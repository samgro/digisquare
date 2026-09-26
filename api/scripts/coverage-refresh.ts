/**
 * Rolls ready cells to the configured OVERTURE_RELEASE now, instead of
 * waiting for the API's worker to get to them in the background.
 *
 *   npm run coverage:refresh            # cells on an older release
 *   npm run coverage:refresh -- --all   # every ready cell, whatever its release
 *
 * Enqueues one refresh job per 1 degree tile and runs them here. `--all` is
 * for when the import changed rather than the release: a new column on
 * `places` is only filled by fetching every row again.
 */

import "../src/load-environment.js";
import { config } from "../src/config.js";
import { claimNextJob, runJob, scheduleRefreshJobs } from "../src/lib/coverage-worker.js";
import { closeOvertureSource, s3Source } from "../src/lib/overture-remote.js";

async function main(): Promise<void> {
  const everyReadyCell = process.argv.includes("--all");
  const jobs = await scheduleRefreshJobs({ everyReadyCell });
  console.log(`${jobs.length} refresh jobs for release ${config.OVERTURE_RELEASE}${everyReadyCell ? " (every ready cell)" : ""}`);
  const source = s3Source(config.OVERTURE_RELEASE);
  for (;;) {
    const job = await claimNextJob();
    if (!job) {
      break;
    }
    console.log(`running ${job.kind} job ${job.id}`);
    await runJob(source, job);
  }
  await closeOvertureSource(source);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
