import { afterEach, describe, expect, it } from "vitest";
import { stubFetch, type StubbedFetch } from "../../test/helpers/stub-fetch.js";
import { describeDatabaseTarget, formatDatabaseTarget, lookupNeonBranch } from "./database-target.js";

describe("describeDatabaseTarget", () => {
  it("names the Neon endpoint without the pooler suffix and never the password", () => {
    const target = describeDatabaseTarget(
      "postgres://neondb_owner:hunter2@ep-red-resonance-arexi4zu-pooler.c-2.us-east-1.aws.neon.tech/neondb?sslmode=require",
    );
    expect(target).toMatchObject({
      host: "ep-red-resonance-arexi4zu-pooler.c-2.us-east-1.aws.neon.tech",
      database: "neondb",
      neonEndpoint: "ep-red-resonance-arexi4zu",
    });
    expect(formatDatabaseTarget(target)).not.toContain("hunter2");
    expect(formatDatabaseTarget(target)).toContain("ep-red-resonance-arexi4zu");
  });

  it("falls back to the host for a database that is not on Neon", () => {
    const target = describeDatabaseTarget("postgres://user:password@localhost:5432/hackysack_test");
    expect(target?.neonEndpoint).toBeNull();
    expect(formatDatabaseTarget(target)).toContain("localhost, hackysack_test");
  });

  it("says so when nothing is set or the value is not a url", () => {
    expect(describeDatabaseTarget("")).toBeNull();
    expect(describeDatabaseTarget("not a url")).toBeNull();
    expect(formatDatabaseTarget(null)).toBe("Database: DATABASE_URL is not set");
  });
});

describe("lookupNeonBranch", () => {
  const API_KEY = "neon-key";

  let fetchStub: StubbedFetch | undefined;

  afterEach(() => {
    fetchStub?.restore();
    fetchStub = undefined;
  });

  it("follows the endpoint to its branch across the key's projects", async () => {
    fetchStub = stubFetch([
      { match: "/users/me/organizations", json: { organizations: [{ id: "org-personal" }, { id: "org-work" }] } },
      { match: "/projects?org_id=org-personal", json: { projects: [{ id: "other", name: "Other" }] } },
      { match: "/projects?org_id=org-work", json: { projects: [{ id: "hacky", name: "hackysack" }] } },
      { match: "/projects/other/endpoints", json: { endpoints: [{ id: "ep-elsewhere", branch_id: "br-x" }] } },
      { match: "/projects/hacky/endpoints", json: { endpoints: [{ id: "ep-patient-firefly-arsdf60v", branch_id: "br-1" }] } },
      { match: "/projects/hacky/branches/br-1", json: { branch: { name: "foursquare", default: false } } },
      // Neon refuses the bare list for an account whose projects are all in organizations.
      { match: "/projects", status: 400, json: { message: "org_id is required" } },
    ]);

    const branch = await lookupNeonBranch("ep-patient-firefly-arsdf60v", API_KEY);

    expect(branch).toEqual({ projectName: "hackysack", branchName: "foursquare", isDefault: false });
    expect(fetchStub.calls[0]!.headers.authorization).toBe(`Bearer ${API_KEY}`);
    const target = describeDatabaseTarget("postgres://u:p@ep-patient-firefly-arsdf60v-pooler.aws.neon.tech/neondb");
    expect(formatDatabaseTarget(target, branch)).toContain('Neon branch "foursquare" of project hackysack');
  });

  it("skips listing projects when one is given, and flags the default branch", async () => {
    fetchStub = stubFetch([
      { match: "/projects/hacky/endpoints", json: { endpoints: [{ id: "ep-silent-feather-arkmdvxb", branch_id: "br-main" }] } },
      { match: "/projects/hacky/branches/br-main", json: { branch: { name: "main", default: true } } },
    ]);

    const branch = await lookupNeonBranch("ep-silent-feather-arkmdvxb", API_KEY, "hacky");

    expect(branch?.isDefault).toBe(true);
    expect(fetchStub.calls.map((call) => new URL(call.url).pathname)).toEqual([
      "/api/v2/projects/hacky/endpoints",
      "/api/v2/projects/hacky/branches/br-main",
    ]);
  });

  it("is null when no project has the endpoint", async () => {
    fetchStub = stubFetch([
      { match: "/users/me/organizations", json: { organizations: [] } },
      { match: "/projects/hacky/endpoints", json: { endpoints: [] } },
      // An older account with personal projects outside any organization.
      { match: "/projects", json: { projects: [{ id: "hacky", name: "hackysack" }] } },
    ]);

    expect(await lookupNeonBranch("ep-unknown", API_KEY)).toBeNull();
  });

  it("passes Neon's explanation along when a call fails", async () => {
    fetchStub = stubFetch([
      { match: "/users/me/organizations", status: 401, json: { message: "authentication failed" } },
    ]);

    await expect(lookupNeonBranch("ep-unknown", API_KEY)).rejects.toThrow(
      "Neon API /users/me/organizations answered 401: authentication failed",
    );
  });
});
