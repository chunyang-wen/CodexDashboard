#!/usr/bin/env bash

set -euo pipefail

discover_project() {
  shopt -s nullglob
  local candidates=( *.xcodeproj )
  if [[ "${#candidates[@]}" -ne 1 ]]; then
    echo "Set PROJECT when the repository does not contain exactly one .xcodeproj." >&2
    exit 1
  fi
  printf '%s' "${candidates[0]}"
}

PROJECT="${PROJECT:-$(discover_project)}"
APP_NAME="${APP_NAME:-$(basename "$PROJECT" .xcodeproj)}"
SCHEME="${SCHEME:-$APP_NAME}"
APPCAST_DIR="${APPCAST_DIR:-docs}"
APPCAST_PATH="${APPCAST_PATH:-$APPCAST_DIR/appcast.xml}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${BRANCH_PREFIX:-chore}"
TAG_PREFIX="${TAG_PREFIX:-v}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/.developer/SparkleBin/bin}"

if [[ "$(git branch --show-current)" != "$BASE_BRANCH" ]]; then
  echo "Release must run from the $BASE_BRANCH branch." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before releasing." >&2
  git status --short >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required." >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Sparkle tools not found. Set SPARKLE_BIN or install them under ~/.developer/SparkleBin/bin." >&2
  exit 1
fi

git fetch origin "$BASE_BRANCH"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BASE_BRANCH")" ]]; then
  echo "Local $BASE_BRANCH is not at origin/$BASE_BRANCH. Pull the merged version PR first." >&2
  exit 1
fi

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$repo/releases/download}"

settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings)"
version="$(awk '/MARKETING_VERSION =/{print $3; exit}' <<< "$settings")"
build_number="$(awk '/CURRENT_PROJECT_VERSION =/{print $3; exit}' <<< "$settings")"
tag="${TAG_PREFIX}${version}"
zip_path="build/$APP_NAME-$version.zip"

if [[ -z "$version" || -z "$build_number" ]]; then
  echo "Could not determine MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
  exit 1
fi
if [[ ! "$build_number" =~ ^[0-9]{14}$ ]]; then
  echo "CURRENT_PROJECT_VERSION must use YYYYMMDDHHMMSS format: $build_number" >&2
  exit 1
fi

previous_build="$(awk -F'[<>]' '/sparkle:version/{print $3}' "$APPCAST_PATH" 2>/dev/null | sort -n | tail -n 1)"
previous_build="${previous_build:-0}"
if [[ "$build_number" -le "$previous_build" ]]; then
  echo "Build number $build_number must be greater than appcast build $previous_build." >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$tag" || \
   git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  echo "Tag already exists: $tag" >&2
  exit 1
fi

RELEASE_BRANCH="${RELEASE_BRANCH:-${BRANCH_PREFIX}/appcast-v${version}}"
if git show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH" || \
   git ls-remote --exit-code --heads origin "$RELEASE_BRANCH" >/dev/null 2>&1; then
  echo "Branch already exists: $RELEASE_BRANCH" >&2
  exit 1
fi

base_commit="$(git rev-parse HEAD)"
git switch -c "$RELEASE_BRANCH" "origin/$BASE_BRANCH"

echo "Building $APP_NAME $version (build $build_number)..."
make release \
  PROJECT="$PROJECT" \
  SCHEME="$SCHEME" \
  APP_NAME="$APP_NAME" \
  APPCAST_DIR="$APPCAST_DIR" \
  DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX" \
  SPARKLE_BIN="$SPARKLE_BIN"

if [[ ! -f "$zip_path" || ! -f "$APPCAST_PATH" ]]; then
  echo "Release artifacts were not generated." >&2
  exit 1
fi

# The tag points to the merged version commit, not to the later appcast PR.
git tag -a "$tag" "$base_commit" -m "$tag"
git push origin "$tag"

release_args=("$tag" "$zip_path" --repo "$repo" --title "$tag")
if [[ -n "$RELEASE_NOTES_FILE" ]]; then
  release_args+=(--notes-file "$RELEASE_NOTES_FILE")
else
  release_args+=(--generate-notes)
fi
gh release create "${release_args[@]}"
gh release upload "$tag" "$APPCAST_PATH" --repo "$repo" --clobber

git add "$APPCAST_PATH"
git commit -m "chore: publish appcast for $tag"
git push --set-upstream origin "$RELEASE_BRANCH"

pr_body="$(printf '## Appcast update\n\nThis PR publishes the generated appcast for [%s](https://github.com/%s/releases/tag/%s).\n\nThe release and ZIP are already published. Merge this PR to make the update visible through the Sparkle feed.\n' "$tag" "$repo" "$tag")"
pr_url="$(gh pr create \
  --repo "$repo" \
  --base "$BASE_BRANCH" \
  --head "$RELEASE_BRANCH" \
  --title "chore: publish appcast for $tag" \
  --body "$pr_body")"

echo "Created appcast PR: $pr_url"
echo "Published release: $tag"
echo "ZIP: $zip_path"
