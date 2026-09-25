#!/usr/bin/env bash
# delete-worktree.sh — remove a worktree and delete its branch locally and on origin
#
# Usage: ./delete-worktree.sh [--force] <worktree-path>
#   e.g. ./delete-worktree.sh ../hackysack-make-friends
#
# git refuses to remove a worktree with uncommitted changes; pass --force to
# discard them. A worktree on a detached HEAD is removed without touching any
# branch. The main worktree and the default branch are never deleted.

set -euo pipefail

FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
  FORCE=true
  shift
fi

TARGET="${1:?Usage: $0 [--force] <worktree-path>}"

if [[ ! -d "$TARGET" ]]; then
  echo "error: $TARGET is not a directory" >&2
  exit 1
fi
WORKTREE_PATH="$(cd "$TARGET" && pwd -P)"

# Run every git command from the main worktree, so this works even when invoked
# from inside the worktree being deleted
MAIN_WORKTREE="$(git -C "$WORKTREE_PATH" worktree list --porcelain | awk '/^worktree/{print $2; exit}')"

if [[ "$WORKTREE_PATH" == "$MAIN_WORKTREE" ]]; then
  echo "error: $WORKTREE_PATH is the main worktree" >&2
  exit 1
fi

if ! git -C "$MAIN_WORKTREE" worktree list --porcelain | grep -qxF "worktree $WORKTREE_PATH"; then
  echo "error: $WORKTREE_PATH is not a worktree of $MAIN_WORKTREE" >&2
  exit 1
fi

# Find the branch checked out in this worktree (empty when HEAD is detached)
BRANCH="$(git -C "$MAIN_WORKTREE" worktree list --porcelain | awk -v path="$WORKTREE_PATH" '
  /^worktree / { current = substr($0, 10) }
  /^branch / && current == path { sub("^branch refs/heads/", ""); print; exit }
')"

DEFAULT_BRANCH="$(git -C "$MAIN_WORKTREE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
if [[ "$BRANCH" == "$DEFAULT_BRANCH" ]]; then
  echo "error: refusing to delete the default branch $DEFAULT_BRANCH" >&2
  exit 1
fi

# Leave the worktree before removing it, in case we were invoked from inside it
cd "$MAIN_WORKTREE"

if $FORCE; then
  git worktree remove --force "$WORKTREE_PATH"
else
  git worktree remove "$WORKTREE_PATH"
fi
echo "✓ Removed worktree $WORKTREE_PATH"

if [[ -z "$BRANCH" ]]; then
  echo "✓ Worktree was on a detached HEAD, no branch to delete"
  exit 0
fi

# -D rather than -d: PRs are squash merged, so merged branches never look merged
git branch -D "$BRANCH"
echo "✓ Deleted local branch $BRANCH"

if git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null; then
  git push origin --delete "$BRANCH"
  echo "✓ Deleted origin/$BRANCH"
else
  echo "✓ $BRANCH was not on origin, nothing to delete there"
fi
