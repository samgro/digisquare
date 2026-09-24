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

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    coverageWorker.stop();
    process.exit(0);
  });
}
