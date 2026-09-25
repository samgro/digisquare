import { serve } from "@hono/node-server";
import { app } from "./app.js";
import { config } from "./config.js";
import { CoverageWorker } from "./lib/coverage-worker.js";
import { s3Source } from "./lib/overture-remote.js";

serve({ fetch: app.fetch, port: config.PORT }, (info) => {
  console.log(`Server running at http://localhost:${info.port}`);
});

// Fetches Overture data for areas users search from that the database does
// not cover yet, and rolls covered areas to a newer release. Lives in the
// API process because there is no separate worker on Railway.
const coverageWorker = new CoverageWorker({ source: s3Source(config.OVERTURE_RELEASE) });
coverageWorker.start();

// A deploy sends SIGTERM while a job may be running; the worker hands it
// back to the queue before the process exits, within a bound in case the
// database is what went away.
const SHUTDOWN_TIMEOUT_MS = 5000;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    const exit = () => process.exit(0);
    setTimeout(exit, SHUTDOWN_TIMEOUT_MS).unref();
    coverageWorker.stop().then(exit, exit);
  });
}
