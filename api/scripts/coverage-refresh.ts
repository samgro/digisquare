/**
 * Rolls ready cells to the configured OVERTURE_RELEASE now, instead of
 * waiting for the API's worker to get to them in the background.
 *
 *   npm run coverage:refresh
 *
 * Enqueues one refresh job per stale 1 degree tile and runs them here.
 */

import "../src/load-environment.js";
import { config } from "../src/config.js";
import { claimNextJob, runJob, scheduleRefreshJobs } from "../src/lib/coverage-worker.js";
import { s3Source } from "../src/lib/overture-remote.js";

async function main(): Promise<void> {
  const jobs = await scheduleRefreshJobs();
  console.log(`${jobs.length} refresh jobs for release ${config.OVERTURE_RELEASE}`);
  const source = s3Source(config.OVERTURE_RELEASE);
  for (;;) {
    const job = await claimNextJob();
    if (!job) {
      break;
    }
    console.log(`running ${job.kind} job ${job.id}`);
    await runJob(source, job);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
