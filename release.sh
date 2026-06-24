#!/bin/bash
# Cut a GitHub Release for Somnya: verify the version builds, then tag it and
# publish a release with auto-generated notes. No binary is attached. Somnya is
# sideloaded, so each user builds and signs their own with ./build.sh; the
# release just marks a version.
#
# The version is read from MARKETING_VERSION in project.yml (the single source
# of truth — the .xcodeproj is generated and gitignored), so the tag and the
# build can never disagree. To release a new version, bump MARKETING_VERSION in
# project.yml, commit, push, then run ./release.sh.
#
# Usage:
#   ./release.sh        # verify build, tag v<version>, create the GitHub release
#   ./release.sh -h     # show this help

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

cd "$(dirname "$0")"

APP_NAME=Somnya

# 1. Version from the single source of truth.
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/' | tr -d ' ')
if [ -z "$VERSION" ]; then
    echo "error: could not read MARKETING_VERSION from project.yml."
    echo "       Set MARKETING_VERSION under settings.base, then re-run."
    exit 1
fi
TAG="v$VERSION"

# 2. Refuse to release from a dirty or unpushed tree, so the tag always matches
#    what's on GitHub rather than uncommitted local code.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty. Commit or stash your changes first, then"
    echo "       re-run ./release.sh so the release matches what's committed."
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if ! git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
    echo "error: no upstream origin/$BRANCH. Push the branch first: git push -u origin $BRANCH"
    exit 1
fi
if [ -n "$(git log "origin/$BRANCH..HEAD" --oneline)" ]; then
    echo "error: you have local commits that aren't pushed. Run 'git push', then re-run"
    echo "       ./release.sh so the release tag matches the code on GitHub."
    exit 1
fi

# 3. Don't clobber an existing version. An existing tag means: bump the version.
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null \
    || gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: $TAG already exists. Bump MARKETING_VERSION in project.yml, commit,"
    echo "       push, then re-run ./release.sh."
    exit 1
fi

# 4. Confirm the version builds before tagging it, so a release never points at
#    code that doesn't compile. We don't attach the .app: Somnya is sideloaded,
#    so the build is signed with your own Apple Team and only installs on your
#    devices (free-account signatures also expire in ~7 days). Anyone using it
#    builds their own with ./build.sh, so the release marks a version rather than
#    shipping an installable binary.
echo "→ Building $APP_NAME $VERSION to verify it compiles"
./build.sh --no-install

# 5. Tag and publish the release with auto-generated notes (source only).
echo "→ Tagging $TAG and creating release"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" \
    --title "$APP_NAME $VERSION" \
    --generate-notes

echo "✓ Released $TAG → $(gh release view "$TAG" --json url -q .url)"
