#!/bin/bash
#
# 署名付きでビルドし、配置済みのアプリを入れ替えて起動し直す。
# DerivedData の成果物はリポジトリの build/ にもコピーする。
#
#   ./scripts/deploy-local.sh                    # ~/Applications へ配置
#   ./scripts/deploy-local.sh /Applications      # 配置先を指定
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-local.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

DEST="${1:-$HOME/Applications}"
TARGET="$DEST/$APP_NAME"

echo "==> ビルド"
run_xcodebuild build >/dev/null || die "ビルドに失敗しました。詳細は xcodebuild を直接実行して確認してください。"

APP=$(built_app_path)
[[ -n "$APP" ]] || die "$APP_NAME が DerivedData に見つかりません。"
echo "    $APP"

echo "==> リポジトリの build/ へコピー"
copy_app_to_repo_build "$APP"

echo "==> 実行中のプロセスを終了"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
pkill -f "MacOS/AIUsageWidget$" 2>/dev/null || true
pkill -f "AIUsageWidgetExtension" 2>/dev/null || true
# 旧表示名の .app が残っていれば消す
rm -rf "$DEST/Cursor使用量.app" 2>/dev/null || true
# WidgetKit のプロセスが古い appex を掴んでいることがある
killall AIUsageWidgetExtension 2>/dev/null || true
killall chronod 2>/dev/null || true
sleep 1

echo "==> 配置: $TARGET"
mkdir -p "$DEST"
rm -rf "$TARGET"
cp -R "$APP" "$DEST/"

echo "==> Launch Services / アイコンキャッシュを更新"
while IFS= read -r path; do
  [[ -z "$path" || "$path" == "$TARGET" ]] && continue
  "$LSREGISTER" -u "$path" 2>/dev/null || true
done < <(mdfind 'kMDItemCFBundleIdentifier == "jp.shigeya.AIUsageWidget"' 2>/dev/null || true)
"$LSREGISTER" -f -R -trusted "$TARGET"
APPEX="$TARGET/Contents/PlugIns/AIUsageWidgetExtension.appex"
if [[ -d "$APPEX" ]]; then
  pluginkit -r "$APPEX" >/dev/null 2>&1 || true
  pluginkit -a "$APPEX" >/dev/null 2>&1 || true
fi
rm -rf "$HOME/Library/Caches/com.apple.iconservices" \
       "$HOME/Library/Caches/com.apple.IconServices" 2>/dev/null || true
killall iconservicesagent >/dev/null 2>&1 || true

echo "==> 署名の確認"
TEAM_LINE=$(codesign -dv "$TARGET/Contents/PlugIns/AIUsageWidgetExtension.appex" 2>&1 \
  | grep TeamIdentifier || true)
echo "    ${TEAM_LINE:-TeamIdentifier が読めません}"
if [[ "$TEAM_LINE" == *"not set"* ]]; then
  die "無署名のビルドが配置されました。ウィジェットは動きません。"
fi

open "$TARGET"
echo "==> 完了。ウィジェット未配置なら「ウィジェットを編集」から追加してください。"
