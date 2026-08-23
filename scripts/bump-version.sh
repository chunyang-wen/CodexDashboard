#!/usr/bin/env bash

set -euo pipefail

discover_project_file() {
  shopt -s nullglob
  local candidates=( *.xcodeproj/project.pbxproj )
  if [[ "${#candidates[@]}" -ne 1 ]]; then
    echo "Set PROJECT_FILE when the repository does not contain exactly one .xcodeproj." >&2
    exit 1
  fi
  printf '%s' "${candidates[0]}"
}

PROJECT_FILE="${PROJECT_FILE:-$(discover_project_file)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${BRANCH_PREFIX:-chore}"
VERSION="${1:-}"
BUILD_NUMBER="${2:-$(date '+%Y%m%d%H%M%S')}"

if [[ ! "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: $0 <version> [YYYYMMDDHHMMSS]" >&2
  echo "Example: $0 0.1.4" >&2
  exit 2
fi
VERSION="${VERSION#v}"

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]{14}$ ]]; then
  echo "Build number must use YYYYMMDDHHMMSS format: $BUILD_NUMBER" >&2
  exit 2
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Project file not found: $PROJECT_FILE" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required to create the pull request." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before starting a version PR." >&2
  git status --short >&2
  exit 1
fi

BRANCH_NAME="${BRANCH_NAME:-${BRANCH_PREFIX}/bump-v${VERSION}}"
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" || \
   git ls-remote --exit-code --heads origin "$BRANCH_NAME" >/dev/null 2>&1; then
  echo "Branch already exists: $BRANCH_NAME" >&2
  exit 1
fi

git fetch origin "$BASE_BRANCH"
git switch -c "$BRANCH_NAME" "origin/$BASE_BRANCH"

version_count="$(rg -o 'MARKETING_VERSION = [^;]+;' "$PROJECT_FILE" | wc -l | tr -d ' ')"
build_count="$(rg -o 'CURRENT_PROJECT_VERSION = [^;]+;' "$PROJECT_FILE" | wc -l | tr -d ' ')"
if [[ "$version_count" -lt 1 || "$version_count" -ne "$build_count" ]]; then
  echo "Could not find matching MARKETING_VERSION and CURRENT_PROJECT_VERSION settings." >&2
  echo "Found MARKETING_VERSION=$version_count CURRENT_PROJECT_VERSION=$build_count." >&2
  exit 1
fi

APPCAST_PATH="${APPCAST_PATH:-}"
if [[ -z "$APPCAST_PATH" && -f docs/appcast.xml ]]; then
  APPCAST_PATH="docs/appcast.xml"
fi
if [[ -n "$APPCAST_PATH" && -f "$APPCAST_PATH" ]]; then
  previous_build="$(awk -F'[<>]' '/sparkle:version/{print $3}' "$APPCAST_PATH" | sort -n | tail -n 1)"
  if [[ -n "$previous_build" && "$BUILD_NUMBER" -le "$previous_build" ]]; then
    echo "Build number $BUILD_NUMBER is not newer than appcast build $previous_build." >&2
    echo "Check your system clock or pass an explicit YYYYMMDDHHMMSS value." >&2
    exit 1
  fi
fi

PROJECT_FILE="$PROJECT_FILE" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" perl -0pi -e \
  's/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $ENV{VERSION};/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $ENV{BUILD_NUMBER};/g' \
  "$PROJECT_FILE"

git add "$PROJECT_FILE"
git commit -m "chore: prepare v$VERSION"
git push --set-upstream origin "$BRANCH_NAME"

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
pr_body="$(printf '## Version bump\n\n- MARKETING_VERSION: %s\n- CURRENT_PROJECT_VERSION: %s\n\nThis PR prepares the next release.\n' "$VERSION" "$BUILD_NUMBER")"
pr_url="$(gh pr create \
  --repo "$repo" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH_NAME" \
  --title "chore: prepare v$VERSION" \
  --body "$pr_body")"

echo "Created version bump PR: $pr_url"
