import { createServer, type Server } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { findOpenPort } from "./open-port.js";

const occupied: Server[] = [];

function occupy(port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen({ port, host: "0.0.0.0" }, () => {
      occupied.push(server);
      resolve();
    });
  });
}

afterEach(async () => {
  await Promise.all(occupied.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

describe("findOpenPort", () => {
  it("returns the preferred port when it is free", async () => {
    const preferred = await findOpenPort(43_100);
    expect(preferred).toBe(43_100);
  });

  it("steps past ports something else holds", async () => {
    await occupy(43_200);
    await occupy(43_201);
    expect(await findOpenPort(43_200)).toBe(43_202);
  });

  it("gives up after the allowed attempts", async () => {
    await occupy(43_300);
    await expect(findOpenPort(43_300, 1)).rejects.toThrow("No free port between 43300 and 43300");
  });
});
