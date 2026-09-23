#!/usr/bin/env bash
# new-worktree.sh — create a worktree and symlink api/.env into it
#
# Usage: ./new-worktree.sh <branch-name> [path]
#   e.g. ./new-worktree.sh claude/make-friends
#          → ../hackysack-make-friends (or ../hackysack-make-friends2, 3, … if taken)
#        ./new-worktree.sh claude/make-friends ../somewhere-else
#
# If the branch exists on origin, it's fetched and checked out as a local
# tracking branch. A leading "origin/" is stripped, so tab-completing a remote
# branch works too.

set -euo pipefail

BRANCH="${1:?Usage: $0 <branch-name> [path]}"
BRANCH="${BRANCH#origin/}"

if [[ -n "${2:-}" ]]; then
  WORKTREE_PATH="$2"
else
  REPO_PARENT="$(dirname "$(git rev-parse --show-toplevel)")"
  BASE_PATH="$REPO_PARENT/hackysack-${BRANCH##*/}"
  WORKTREE_PATH="$BASE_PATH"
  SUFFIX=2
  while [[ -e "$WORKTREE_PATH" ]]; do
    WORKTREE_PATH="$BASE_PATH$SUFFIX"
    SUFFIX=$((SUFFIX + 1))
  done
fi

# Locate the canonical api/.env from the main worktree of the monorepo
MAIN_WORKTREE="$(git worktree list --porcelain | awk '/^worktree/{print $2; exit}')"
SOURCE_ENV="$MAIN_WORKTREE/api/.env"

if [[ ! -f "$SOURCE_ENV" ]]; then
  echo "error: no .env found at $SOURCE_ENV" >&2
  exit 1
fi

# Create the worktree: check out an existing local branch, otherwise track the
# branch from origin if it exists there, otherwise start a new branch from HEAD
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$WORKTREE_PATH" "$BRANCH"
elif git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null; then
  git fetch origin "$BRANCH"
  git worktree add --track -b "$BRANCH" "$WORKTREE_PATH" "origin/$BRANCH"
else
  git worktree add -b "$BRANCH" "$WORKTREE_PATH"
fi

# Symlink api/.env (absolute path so it survives being moved/renamed)
ln -sf "$(cd "$(dirname "$SOURCE_ENV")" && pwd)/.env" "$WORKTREE_PATH/api/.env"

echo "✓ Worktree created at $WORKTREE_PATH"
echo "✓ api/.env symlinked from $SOURCE_ENV"

(cd "$WORKTREE_PATH/api" && npm install)

echo "✓ npm install finished in $WORKTREE_PATH/api"
