import { createServer } from "node:net";

/**
 * The first free TCP port at or after `preferred`, for local development
 * where several checkouts run their own API at once: each takes the next
 * port up, and the simulator app finds its own server by branch (see the
 * app's DevServerLocator). Throws when none of `attempts` ports is free.
 */
export async function findOpenPort(preferred: number, attempts = 10): Promise<number> {
  for (let port = preferred; port < preferred + attempts; port += 1) {
    if (await isFree(port)) {
      return port;
    }
  }
  throw new Error(`No free port between ${preferred} and ${preferred + attempts - 1}`);
}

function isFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = createServer();
    probe.once("error", () => resolve(false));
    // The same interface the server binds, so a port another process holds
    // on all interfaces reads as taken.
    probe.listen({ port, host: "0.0.0.0" }, () => {
      probe.close(() => resolve(true));
    });
  });
}
