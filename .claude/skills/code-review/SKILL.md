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
   - **Readability**: clear naming, simple structure, and consistency with the surrounding code and CLAUDE.md conventions.
3. Fix any issues you find. If something is ambiguous, prompt for input. Follow standard build commands for whichever of ios or api has changes.
