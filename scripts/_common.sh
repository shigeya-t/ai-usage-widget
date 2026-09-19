#!/bin/bash
# 各スクリプトから source して使う共通処理。単体では実行しない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/AIUsageWidget.xcodeproj"
SCHEME="AIUsageWidget"
APP_NAME="Cursor使用量.app"
BUNDLE_ID="jp.shigeya.AIUsageWidget"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "error: $*" >&2; exit 1; }

# Team ID は環境ごとに異なる個人情報なのでリポジトリには書かない。
# DEVELOPMENT_TEAM が指定されていればそれを使い、無ければ手元の
# 「Apple Development」証明書の OU から引く。
resolve_team_id() {
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "$DEVELOPMENT_TEAM"
    return
  fi

  local names
  names=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p')

  [[ -n "$names" ]] || die "Apple Development 証明書が見つかりません。Xcode でサインインしてください。"

  if [[ $(wc -l <<<"$names") -gt 1 ]]; then
    echo "複数の証明書が見つかりました。DEVELOPMENT_TEAM=<Team ID> を指定してください:" >&2
    echo "$names" >&2
    exit 1
  fi

  local team
  team=$(security find-certificate -c "$names" -p \
    | openssl x509 -noout -subject \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')

  [[ -n "$team" ]] || die "証明書から Team ID を取得できませんでした: $names"
  echo "$team"
}

write_team_xcconfig() {
  local team
  team=$(resolve_team_id)
  DEVELOPMENT_TEAM_RESOLVED="$team"
  mkdir -p "$REPO_ROOT/Config"
  cat > "$REPO_ROOT/Config/Team.xcconfig" <<EOF
// 自動生成。手元の証明書から Team ID を書いた。リポジトリには含めない。
DEVELOPMENT_TEAM = $team
EOF
}

# 配置用は Release（Debug の *.debug.dylib stub は Launch Services で欠けやすい）
CONFIGURATION="${CONFIGURATION:-Release}"

run_xcodebuild() {
  write_team_xcconfig
  local team="$DEVELOPMENT_TEAM_RESOLVED"
  xcodebuild "$@" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$team"
}

built_app_path() {
  local dir
  dir=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -1)
  [[ -n "$dir" && -d "$dir/$APP_NAME" ]] && echo "$dir/$APP_NAME"
}

copy_app_to_repo_build() {
  local src="$1"
  local dest="$REPO_ROOT/build/$APP_NAME"
  [[ -d "$src" ]] || die "コピー元がありません: $src"
  mkdir -p "$REPO_ROOT/build"
  rm -rf "$dest"
  ditto "$src" "$dest"
  echo "    $dest"
}
