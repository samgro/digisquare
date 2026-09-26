import { serve } from "@hono/node-server";
import { app } from "./app.js";
import { config, swarmImportConfig } from "./config.js";
import { CoverageWorker } from "./lib/coverage-worker.js";
import { findOpenPort } from "./lib/open-port.js";
import { s3Source } from "./lib/overture-remote.js";
import { resumeRunningImports } from "./lib/swarm-import.js";

// Locally, several checkouts run their own API at once. The user's own
// server is the one on PORT (3000 in their .env; Bruno points there), used
// as is so a clash fails loudly instead of drifting, on Railway too. Every
// other checkout takes the first free port from 3001, and the simulator app
// finds its server by branch. A Claude Code session has
// HACKYSACK_AUTOMATIC_PORT set (see .claude/settings.json), which ignores
// PORT altogether, so a server it starts can never land on the user's.
const FIRST_AUTOMATIC_PORT = 3001;
const automaticPort = process.env.HACKYSACK_AUTOMATIC_PORT === "1" || !process.env.PORT;
const port = automaticPort ? await findOpenPort(FIRST_AUTOMATIC_PORT) : config.PORT;

serve({ fetch: app.fetch, port }, (info) => {
  const note = !automaticPort
    ? ""
    : info.port === FIRST_AUTOMATIC_PORT
      ? " (3000 is the user's own server)"
      : ` (${FIRST_AUTOMATIC_PORT} was busy)`;
  console.log(`Server running at http://localhost:${info.port}${note}`);
});

// Fetches Overture data for areas users search from that the database does
// not cover yet, and rolls covered areas to a newer release. Lives in the
// API process because there is no separate worker on Railway.
const coverageWorker = new CoverageWorker({ source: s3Source(config.OVERTURE_RELEASE) });
coverageWorker.start();

// Swarm imports run in-process too, so a deploy interrupts them; each saves
// its place after every page, and this picks them back up from there.
if (swarmImportConfig()) {
  resumeRunningImports().catch((error: unknown) => {
    console.error("Failed to resume Swarm imports", error);
  });
}

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
