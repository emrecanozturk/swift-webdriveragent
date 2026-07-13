#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO_SLUG="${REPO_SLUG:-emrecanozturk/swift-webdriveragent}"
WIKI_SOURCE="$ROOT/docs/wiki"
WORK_DIR="$ROOT/wiki-worktree"
REMOTE_URL="https://github.com/${REPO_SLUG}.wiki.git"

if [ ! -d "$WIKI_SOURCE" ]; then
  echo "Wiki source not found: $WIKI_SOURCE" >&2
  exit 1
fi

if ! git ls-remote "$REMOTE_URL" HEAD refs/heads/master refs/heads/main >/dev/null 2>&1; then
  cat >&2 <<MSG
GitHub wiki remote is not initialized yet: $REMOTE_URL

Open https://github.com/${REPO_SLUG}/wiki, create the first Home page once,
then rerun this script. GitHub enables the Wiki tab separately from creating
the backing .wiki.git repository.
MSG
  exit 2
fi

if [ ! -d "$WORK_DIR/.git" ]; then
  rm -rf "$WORK_DIR"
  git clone "$REMOTE_URL" "$WORK_DIR"
fi

rsync -a --delete --exclude ".git/" "$WIKI_SOURCE/" "$WORK_DIR/"

cd "$WORK_DIR"
git add .
if git diff --cached --quiet; then
  echo "Wiki already up to date."
  exit 0
fi

git commit -m "Update SwiftWDA wiki"
git push origin HEAD
