#!/usr/bin/env bash
# Computes the next release version from existing tags.
#
#   git tag --list 'v*' | .github/scripts/next-version.sh pubspec.yaml
#
# The major number comes from pubspec.yaml (`version: 1.0.0+1` -> 1). The
# minor number is one more than the highest existing `v<major>.<minor>` tag,
# so every run gets a new, never-reused version: v1.0, v1.1, v1.2, ...
# Bump the major in pubspec.yaml to start a new series (v2.0, v2.1, ...).
#
# Prints GitHub Actions output lines: tag, name (x.y.0 for --build-name) and title.
set -euo pipefail

pubspec="${1:-pubspec.yaml}"
app_name="${APP_NAME:-Rhytmaniac}"

major="$(sed -nE 's/^version:[[:space:]]*([0-9]+)\..*/\1/p' "$pubspec" | head -n 1)"
if [[ -z "$major" ]]; then
  echo "Could not read the major version from $pubspec" >&2
  exit 1
fi

last="$( (grep -E "^v${major}\.[0-9]+$" || true) | sed -E "s/^v${major}\.//" | sort -n | tail -n 1)"
if [[ -z "$last" ]]; then
  minor=0
else
  minor=$((last + 1))
fi

echo "tag=v${major}.${minor}"
echo "name=${major}.${minor}.0"
echo "title=${app_name} v${major}.${minor}"
