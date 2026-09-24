---
name: code-review
description: Review the current branch's changes for readability, bugs, and whether they meet the original spec or prompt. Use when asked to review a branch, given a spec path or a description of the intended change.
---

# Code review

The arguments are either a path to a spec file or prompt text describing the intended change. If the text is a file path, read the file. That is the spec.

1. Get the diff with `git diff main...HEAD`, plus `git diff HEAD` for any uncommitted changes. Read the changed files for surrounding context.
2. Review the changes for:
   - **Spec**: Does the change do everything the spec asks? Flag anything missing, only partly done, or beyond what the spec asks for.
   - **Bugs**: logic errors, unhandled edge cases, crashes, race conditions and security issues.
   - **Checkin privacy**: No one may see a checkin by someone they aren't friends with. All checkin queries belong in `api/src/lib/checkin-queries.ts`. Check that:
     - nothing outside that file imports the checkins table or casts to `VisibleCheckin`. Run `git diff main...HEAD -- api/src | grep -nE "checkinsTable|VisibleCheckin|query\.checkins"`, and the same on `git diff HEAD`.
     - every new or changed function in `checkin-queries.ts` that reads checkins, directly or through a join, is scoped with `isVisibleCheckin(viewerId)`, or only touches the caller's own rows
     - a stranger's checkin comes back as the same 404 or empty list as a missing one, never a 403
     - nothing leaks through side channels such as counts, place names or timestamps. The public checkin count in `GET /users/:id` is intentional.
     - any new endpoint that returns checkins has a case in `api/src/routes/checkin-privacy.test.ts`, which runs against real Postgres

     Treat a miss as a bug and fix it.
   - **Readability**: clear naming, simple structure, and consistency with the surrounding code and CLAUDE.md conventions.
3. Fix any issues you find. Checkin privacy findings are always bugs, never style choices to skip. If something is ambiguous, prompt for input. Follow standard build commands for whichever of ios or api has changes.
