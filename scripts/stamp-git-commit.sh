#!/bin/bash
# ホストアプリの Info.plist に、このビルドの git ハッシュを書く。
# preBuild で実行し、その後の Info.plist 処理と署名に載せる。

set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLIST="${INFOPLIST_FILE:-$ROOT/App/Info.plist}"

if [[ ! -f "$PLIST" ]]; then
  echo "stamp-git-commit: Info.plist が無いのでスキップします: $PLIST" >&2
  exit 0
fi

HASH=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)
if [[ -z "$HASH" ]]; then
  HASH=unknown
elif [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null || true)" ]]; then
  HASH="${HASH}-dirty"
fi

if [[ ! "$HASH" =~ ^([0-9a-f]{7,40}(-dirty)?|unknown)$ ]]; then
  HASH=unknown
fi

/usr/libexec/PlistBuddy -c "Delete :GitCommitHash" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string ${HASH}" "$PLIST"
echo "stamp-git-commit: ${HASH}"
