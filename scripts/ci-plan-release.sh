#!/bin/bash
# CI: decides whether this push releases, and prints GitHub step outputs.
#
#   EVENT=push BEFORE=<sha> scripts/ci-plan-release.sh
#   EVENT=workflow_dispatch scripts/ci-plan-release.sh
#
# A push releases when it changes MARKETING_VERSION in project.yml and that
# version has no v<version> tag yet. A manual run always releases (or dry-runs,
# with DRY_RUN=1, even for a tagged version).
# The build number must be higher than the previous version's, because Sparkle
# and TestFlight both order by it.
set -euo pipefail
cd "$(dirname "$0")/.."

setting() { awk -v key="$1:" '$1 == key {gsub(/"/, "", $2); print $2; exit}'; }
version=$(setting MARKETING_VERSION < project.yml)
build=$(setting CURRENT_PROJECT_VERSION < project.yml)

release=false
case "${EVENT:?}" in
  workflow_dispatch) release=true ;;
  push)
    if [[ -n "${BEFORE:-}" ]] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
      before_version=$(git show "$BEFORE:project.yml" | setting MARKETING_VERSION)
      [[ "$before_version" != "$version" ]] && release=true
      echo "version $before_version → $version" >&2
    fi
    ;;
esac

# A dry run publishes nothing, so it may rebuild a version that is already out.
if [[ $release == true && -z "${DRY_RUN:-}" ]] && git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "v$version is already released; nothing to do" >&2
  release=false
fi

if [[ $release == true ]]; then
  read -r previous base previous_build <<< "$(python3 scripts/generate-release-notes.py --base)"
  if [[ -n "${previous_build:-}" ]] && (( build <= previous_build )); then
    echo "::error::CURRENT_PROJECT_VERSION is $build, not above $previous ($previous_build). Raise it in project.yml." >&2
    exit 1
  fi
  echo "releasing $version ($build); previous ${previous:-none} at ${base:-none}" >&2
fi

echo "release=$release"
echo "version=$version"
echo "build=$build"
