#!/usr/bin/env bash
# Cut a release: verify, tag, push, then pin the Homebrew formula to the tarball.
#
#   scripts/release.sh 0.2.0
#
# Steps:
#   1. Check the working tree is clean and Version.swift matches.
#   2. swift build -c release && swift test.
#   3. git tag -a v<version> and push the tag (GitHub makes the archive tarball).
#   4. Download the tarball, compute its sha256, update Formula/pulseki.rb.
#   5. Print the copy command for the tap.
set -euo pipefail

version="${1:-}"
if [[ -z "$version" ]]; then
  echo "usage: $0 <version>   (e.g. 0.1.0)" >&2
  exit 2
fi

repo="looskis/pulseki"
tap_dir="${TAP_DIR:-$HOME/projects/homebrew-tap}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean" >&2
  exit 1
fi

if ! grep -q "static let string = \"$version\"" Sources/PulsekiCore/Version.swift; then
  echo "error: Sources/PulsekiCore/Version.swift does not say $version" >&2
  exit 1
fi

echo "==> building and testing"
swift build -c release
swift test

tag="v$version"
if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "==> tag $tag already exists, reusing it"
else
  git tag -a "$tag" -m "pulseki $version"
fi
git push origin "$tag"

url="https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "==> fetching $url"
for attempt in 1 2 3 4 5 6; do
  if curl -fsSL "$url" -o "$tmp/src.tar.gz"; then break; fi
  echo "    tarball not ready yet, retrying ($attempt)"
  sleep 5
done
sha="$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)"
echo "==> sha256 $sha"

sed -i '' \
  -e "s|^  url \".*\"|  url \"$url\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" \
  Formula/pulseki.rb

echo "==> Formula/pulseki.rb updated. Commit it, then publish to the tap:"
echo "    cp Formula/pulseki.rb $tap_dir/Formula/pulseki.rb"
echo "    (cd $tap_dir && git add Formula/pulseki.rb && git commit -m 'pulseki $version' && git push)"
