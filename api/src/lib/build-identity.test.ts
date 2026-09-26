import { describe, expect, it } from "vitest";
import { compareBuilds, currentBuildIdentity, formatBuildIdentity, parseBuildIdentity } from "./build-identity.js";

describe("build identity", () => {
  it("round-trips through the wire format, splitting on the last @", () => {
    const identity = { branch: "sam@work/gate", commit: "7e1389e" };
    expect(formatBuildIdentity(identity)).toBe("sam@work/gate@7e1389e");
    expect(parseBuildIdentity("sam@work/gate@7e1389e")).toEqual(identity);
  });

  it("rejects values without both parts", () => {
    expect(parseBuildIdentity("no-separator")).toBeNull();
    expect(parseBuildIdentity("@7e1389e")).toBeNull();
    expect(parseBuildIdentity("branch@")).toBeNull();
  });

  it("tells a branch difference from a commit difference", () => {
    const server = { branch: "main", commit: "1111111" };
    expect(compareBuilds(server, { branch: "main", commit: "1111111" })).toBe("match");
    expect(compareBuilds(server, { branch: "main", commit: "2222222" })).toBe("commit");
    expect(compareBuilds(server, { branch: "feature", commit: "1111111" })).toBe("branch");
  });

  it("reads this checkout's branch and commit from git", async () => {
    const identity = await currentBuildIdentity();
    expect(identity?.source).toBe("git");
    expect(identity?.commit).toMatch(/^[0-9a-f]{7,}$/);
    expect(identity?.branch.length).toBeGreaterThan(0);
  });
});
