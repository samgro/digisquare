import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import { z } from "zod";

/**
 * Where DATABASE_URL points and which file said so, for printing before a
 * migration or seed runs. Worktrees share `api/.env` with the main checkout
 * (production) and override it with `api/.env.branch`, so the one thing
 * worth knowing before writing to Postgres is which of the two won.
 */
export interface DatabaseTarget {
  host: string;
  database: string;
  /** Neon's endpoint id from the host, e.g. `ep-red-resonance-arexi4zu`, or null elsewhere. */
  neonEndpoint: string | null;
  /** `.env.branch`, `.env`, or `shell` when neither file set it. */
  source: ".env.branch" | ".env" | "shell";
}

const ENVIRONMENT_PATH = fileURLToPath(new URL("../../.env", import.meta.url));
const BRANCH_ENVIRONMENT_PATH = fileURLToPath(new URL("../../.env.branch", import.meta.url));

function databaseUrlIn(path: string): string | undefined {
  if (!existsSync(path)) {
    return undefined;
  }
  return dotenv.parse(readFileSync(path)).DATABASE_URL;
}

/** Null when DATABASE_URL is unset or not a URL. */
export function describeDatabaseTarget(databaseUrl = process.env.DATABASE_URL): DatabaseTarget | null {
  if (!databaseUrl) {
    return null;
  }
  let url: URL;
  try {
    url = new URL(databaseUrl);
  } catch {
    return null;
  }

  // load-environment.ts applies .env.branch over .env, so whichever file holds
  // the value that won is the source.
  let source: DatabaseTarget["source"] = "shell";
  if (databaseUrlIn(BRANCH_ENVIRONMENT_PATH) === databaseUrl) {
    source = ".env.branch";
  } else if (databaseUrlIn(ENVIRONMENT_PATH) === databaseUrl) {
    source = ".env";
  }

  const endpointMatch = /^(ep-[a-z0-9-]+?)(-pooler)?\./.exec(url.hostname);
  return {
    host: url.hostname,
    database: url.pathname.replace(/^\//, "") || "(default)",
    neonEndpoint: endpointMatch?.[1] ?? null,
    source,
  };
}

/** One line for a terminal, never including credentials. */
export function formatDatabaseTarget(target: DatabaseTarget | null, branch?: NeonBranch | null): string {
  if (!target) {
    return "Database: DATABASE_URL is not set";
  }
  let where = target.neonEndpoint ? `Neon endpoint ${target.neonEndpoint}` : target.host;
  if (branch) {
    const role = branch.isDefault ? ", the default branch" : "";
    where = `Neon branch "${branch.branchName}"${role} of project ${branch.projectName} (${target.neonEndpoint})`;
  }
  const from =
    target.source === ".env"
      ? "from api/.env — in a worktree that is the main checkout's database"
      : `from ${target.source}`;
  return `Database: ${where}, ${target.database} (${from})`;
}

export interface NeonBranch {
  projectName: string;
  branchName: string;
  /** The project's default (production) branch, as opposed to a throwaway. */
  isDefault: boolean;
}

const NEON_API_BASE_URL = "https://console.neon.tech/api/v2";

const projectsSchema = z.object({ projects: z.array(z.object({ id: z.string(), name: z.string() })) });
const endpointsSchema = z.object({
  endpoints: z.array(z.object({ id: z.string(), branch_id: z.string() })),
});
const branchSchema = z.object({
  branch: z.object({ name: z.string(), default: z.boolean().optional() }),
});

async function neonApi<Shape>(path: string, apiKey: string, schema: z.ZodType<Shape>): Promise<Shape> {
  const response = await fetch(`${NEON_API_BASE_URL}${path}`, {
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error(`Neon API ${path} answered ${response.status}`);
  }
  return schema.parse(await response.json());
}

/**
 * The branch behind a Neon endpoint, by name, from Neon's API. The name is
 * not in the connection string, so this needs an API key (Account settings
 * → API keys in the Neon console). Searches every project the key can see
 * unless `projectId` narrows it. Null when no project has the endpoint.
 */
export async function lookupNeonBranch(
  endpointId: string,
  apiKey: string,
  projectId?: string,
): Promise<NeonBranch | null> {
  const projects = projectId
    ? [{ id: projectId, name: projectId }]
    : (await neonApi("/projects", apiKey, projectsSchema)).projects;

  for (const project of projects) {
    const { endpoints } = await neonApi(`/projects/${project.id}/endpoints`, apiKey, endpointsSchema);
    const endpoint = endpoints.find((candidate) => candidate.id === endpointId);
    if (!endpoint) {
      continue;
    }
    const { branch } = await neonApi(
      `/projects/${project.id}/branches/${endpoint.branch_id}`,
      apiKey,
      branchSchema,
    );
    return { projectName: project.name, branchName: branch.name, isDefault: branch.default ?? false };
  }
  return null;
}
