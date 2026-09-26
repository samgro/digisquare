/**
 * Which git branch and commit this server is running from, for the dev build
 * gate: a Debug simulator build sends the branch and commit it was built
 * from, and a server from another checkout refuses it, so several worktrees
 * taking turns on localhost:3000 can never mix sessions or databases.
 *
 * Read from git on every request (cached for two seconds) rather than once
 * at boot, because a commit does not restart `tsx watch` and the identity
 * must follow HEAD. On Railway there is no .git; the identity then comes
 * from Railway's variables for reporting only and is never enforced.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface BuildIdentity {
  branch: string;
  commit: string;
}

export interface ServerBuild extends BuildIdentity {
  /** `git` identities are enforced; `railway` ones are only reported. */
  source: "git" | "railway";
}

export type BuildComparison = "match" | "commit" | "branch";

const CACHE_MILLISECONDS = 2000;
const GIT_TIMEOUT_MILLISECONDS = 2000;

let cached: { at: number; value: ServerBuild | null } | null = null;

export async function currentBuildIdentity(): Promise<ServerBuild | null> {
  if (cached && Date.now() - cached.at < CACHE_MILLISECONDS) {
    return cached.value;
  }
  const value = (await fromGit()) ?? fromRailway();
  cached = { at: Date.now(), value };
  return value;
}

async function git(...args: string[]): Promise<string> {
  const { stdout } = await run("git", args, { timeout: GIT_TIMEOUT_MILLISECONDS });
  return stdout.trim();
}

async function fromGit(): Promise<ServerBuild | null> {
  try {
    const [branch, commit] = await Promise.all([git("rev-parse", "--abbrev-ref", "HEAD"), git("rev-parse", "--short", "HEAD")]);
    return branch && commit ? { branch, commit, source: "git" } : null;
  } catch {
    return null;
  }
}

function fromRailway(): ServerBuild | null {
  const branch = process.env.RAILWAY_GIT_BRANCH;
  const sha = process.env.RAILWAY_GIT_COMMIT_SHA;
  return branch && sha ? { branch, commit: sha.slice(0, 7), source: "railway" } : null;
}

/** `branch@commit`. Split on the last `@`: a branch name may contain one. */
export function formatBuildIdentity(identity: BuildIdentity): string {
  return `${identity.branch}@${identity.commit}`;
}

export function parseBuildIdentity(value: string): BuildIdentity | null {
  const separator = value.lastIndexOf("@");
  if (separator <= 0 || separator === value.length - 1) {
    return null;
  }
  return { branch: value.slice(0, separator), commit: value.slice(separator + 1) };
}

export function compareBuilds(server: BuildIdentity, client: BuildIdentity): BuildComparison {
  if (server.branch !== client.branch) {
    return "branch";
  }
  return server.commit === client.commit ? "match" : "commit";
}
