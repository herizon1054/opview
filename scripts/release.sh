#!/usr/bin/env bash
#
# release.sh — bump version, tag, and push (CI builds + publishes)
#
# Usage:
#   ./scripts/release.sh              # bump patch (2.0.0 → 2.0.1)
#   ./scripts/release.sh minor        # bump minor (0.1.0 → 0.2.0)
#   ./scripts/release.sh major        # bump major (0.1.0 → 1.0.0)
#   ./scripts/release.sh 0.3.0        # set explicit version
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}==>${NC} ${BOLD}$*${NC}"; }
die() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

# ── preflight ───────────────────────────────────────────────────

command -v git >/dev/null || die "git not found on PATH"

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash first"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "detached HEAD — checkout a branch first"
# main 的標籤為 vX.Y.Z；其他分支加上分支名（opview-stopcar → vX.Y.Z-stopcar），同一個 repo 的多個分支不會撞標籤
suffix=""
if [[ "$branch" != "main" ]]; then
  suffix="-$(echo "${branch#opview-}" | tr -c 'A-Za-z0-9.\n-' '-')"
fi

# ── version bump ────────────────────────────────────────────────

full_version=$(grep '^version:' pubspec.yaml | sed 's/version: //')
current_version="${full_version%%+*}"     # 2.0.0+200 → 2.0.0
build_number=0
[[ "$full_version" == *+* ]] && build_number="${full_version#*+}"
new_build=$((build_number + 1))           # Android versionCode：每次發布 +1，才能覆蓋安裝
IFS='.' read -r major minor patch <<< "$current_version"

arg="${1:-patch}"
case "$arg" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
  [0-9]*.*)
    IFS='.' read -r major minor patch <<< "$arg"
    ;;
  *) die "usage: release.sh [patch|minor|major|X.Y.Z]" ;;
esac

new_version="${major}.${minor}.${patch}"
# 標籤與 App 顯示一致：結尾 .0 省略（2.0.0 → v2.0、2.1.0 → v2.1；2.0.1 照原樣）
display_version="$new_version"
[[ "$patch" == "0" ]] && display_version="${major}.${minor}"
tag="v${display_version}${suffix}"

git tag -l "$tag" | grep -q . && die "tag $tag already exists"

log "Version: $full_version → ${new_version}+${new_build} ($tag)"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── commit + tag + push ────────────────────────────────────────

sed -i "s/^version: .*/version: ${new_version}+${new_build}/" pubspec.yaml

git add pubspec.yaml
git commit -m "release ${tag}"
git tag -a "$tag" -m "release ${tag}"
git push origin "$branch"
git push origin "$tag"

log "Pushed $tag — CI will build and publish the release"
remote_url="$(git remote get-url origin 2>/dev/null || true)"
repo="$(echo "$remote_url" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
if [[ -n "$repo" ]]; then echo "    https://github.com/${repo}/actions"; fi
