#!/bin/bash
#
# 単体テストを実行する。
#
#   ./scripts/test.sh                                  # 結果のみ表示
#   ./scripts/test.sh -v                               # xcodebuild の出力をそのまま流す
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/test.sh
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [[ "${1:-}" == "-v" ]]; then
  run_xcodebuild test
  exit $?
fi

set +e
OUTPUT=$(run_xcodebuild test 2>&1)
STATUS=$?
set -e

echo "$OUTPUT" | grep -E "error:|warning:|failed|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" | sort -u || true

if [[ $STATUS -ne 0 ]]; then
  echo
  echo "テストが失敗しました。全文を見るには: ./scripts/test.sh -v" >&2
fi
exit $STATUS
