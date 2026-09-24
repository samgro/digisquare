/**
 * Puts failed coverage jobs (and their cells) back in the queue.
 *
 *   npm run coverage:retry
 */

import "../src/load-environment.js";
import { retryFailedJobs } from "../src/lib/coverage-worker.js";

retryFailedJobs()
  .then((count) => console.log(`${count} jobs re-queued`))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
