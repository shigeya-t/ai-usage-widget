# AI使用量ウィジェット

[English](README.en.md)

Cursor / Claude / ChatGPT（Codex）のプランと使用量を、macOS のメニューバーと
WidgetKit ウィジェットでいつでも確認できるアプリです。

[東京地下鉄ウィジェット](https://github.com/shigeya-t/subway-widget) と同じく、
**メニューバー常駐アプリが取得し、ウィジェットは表示だけ** という構成です。

<p align="center">
  <img src="docs/screenshots/widget-ja.png" alt="ウィジェット（日本語）" width="220" />
  &nbsp;
  <img src="docs/screenshots/menu-ja.png" alt="メニューバー（日本語）" width="280" />
</p>

## 作った動機

Cursor のダッシュボードには Plan & Usage がありますが、残りクレジットが減っても
目立つ通知は出ないようです。気づいたときには枠を使い切っていて、オンデマンド課金に
かなりはみ出していた、ということがありました。

設定ページを毎回開かなくても、メニューバーやデスクトップのウィジェットを一目見れば
プラン枠と従量が分かるようにしたくて作りました。Claude と ChatGPT（Codex）も同じ
置き場所から見られるようにしています。

## できること

- サービス切り替え（Cursor / Claude / ChatGPT）
- Plan & Usage 相当の表示（プラン名・リセット日・パーセント棒・従量）
- メニューバー常駐（Dock には出ません）とウィジェット（小・中・大）
- 日本語 / English の切り替え（アプリとウィジェットで共有）
- 一時停止と今すぐ更新（アプリ・ウィジェットの両方）
- 手動トークン／Cookie の保存・上書き・削除（サービスごと）

## 必要なもの

- macOS 14 以降
- Xcode 15 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- 見たいサービスへのローカルログイン（推奨）:
  - Cursor: Cursor.app
  - Claude: Claude Code
  - ChatGPT（Codex）: Codex CLI

## ビルドと導入

```sh
brew install xcodegen
cp Config/Team.xcconfig.example Config/Team.xcconfig
./scripts/sync-team.sh
xcodegen generate
./scripts/test.sh
swift scripts/generate-app-icon.swift
./scripts/deploy-local.sh                 # ~/Applications と build/ へ配置
```

`deploy-local.sh` は Team 付きで署名してから配置します。アドホック署名では
AppIntents が解決できず、ウィジェットがプレースホルダのまま止まります。
証明書が複数あるときは `DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-local.sh` です。

配置後、「ウィジェットを編集」から **AI使用量** を追加してください
（英語のシステム言語では **AI Usage**）。
常時使う場合は、システム設定 →「一般」→「ログイン項目」に登録しておくと便利です。

以前の **Cursor使用量.app** が残っている場合、`deploy-local.sh` が配置先から削除します。

## 認証

個人のプラン使用量は公式 Admin API では取れません。このアプリは各サービスの
非公式エンドポイントを、**ローカルアプリが保存したセッションを読んで** 呼び出します。
OAuth の refresh はしません（単回利用の refresh token を潰さないため）。期限切れなら
元アプリを一度起動してください。

セッション Cookie / JWT / access token はログに出しません。ウィジェットへ渡すのは
使用量のスナップショットだけです。

### Cursor

エンドポイント: `GET https://cursor.com/api/usage-summary`

1. メニューバーに保存した Cookie（Keychain）※あれば優先
2. Cursor.app の `state.vscdb`（`cursorAuth/accessToken`）

自動取得に失敗したときだけ、Cookie を手動で入れてください:

1. https://cursor.com/dashboard?tab=usage を開く
2. DevTools → Application → Cookies → `WorkosCursorSessionToken` の **Value** をコピー
3. メニューバーの入力欄に値だけ貼り付けて保存

### Claude

エンドポイント: `GET https://api.anthropic.com/api/oauth/usage`

1. メニューバーに保存した access token（Keychain）※あれば優先
2. Claude Code の Keychain（`Claude Code-credentials`）
3. `~/.claude/.credentials.json`（`CLAUDE_CONFIG_DIR` があればそちら）

Claude Code にログインしているのが前提です。API キー運用ではプラン使用量は取れません。
期限切れのときは Claude Code を一度起動してください（こちらから refresh しません）。

### ChatGPT（Codex）

エンドポイント: `GET https://chatgpt.com/backend-api/wham/usage`
（404 のときは `.../codex/usage`）

1. メニューバーに保存した access token（Keychain）※あれば優先
2. Codex CLI の `~/.codex/auth.json`（`CODEX_HOME` があればそちら）

Codex に ChatGPT アカウントでログインしているのが前提です。API キー運用では
プラン使用量は取れません。期限切れのときは Codex を一度起動してください。

### 権限まわり

- **ホスト（メニューバー）**: App Sandbox なし。Cursor / Claude Code / Codex のローカル資格情報を読むためです
- **ウィジェット拡張**: サンドボックスあり。通信せず App Group のスナップショットだけ表示します
- 個人の私的利用向けです。配布用にサンドボックスを必須にする場合は、手動トークン運用や
  ファイル選択（security-scoped bookmark）など別設計が必要です

## 更新のしくみ

メニューバーに常駐しているあいだだけ、ウィジェットはほぼ最新のまま保たれます。

- 取得はメニューバーアプリに一本化（ウィジェット拡張は通信しません）
- 既定は 5 分ごと。App Group 経由でウィジェットへ渡します
- メニューで選んでいるサービスに加え、配置済みウィジェットのサービスもまとめて取ります
- 「一時停止」で自動取得を止め、「今すぐ更新」は停止中でも取り直します

## 他の AI サービスを足すには

`UsageProvider` を実装し、`UsageProviderRegistry.all` に登録します。
UI は `UsageSnapshot`（プラン・パーセント棒・従量）だけを描画します。

## 構成

```
project.yml                  XcodeGen のプロジェクト定義
Shared/                      モデル・各プロバイダ・L10n・App Intents
App/                         メニューバー常駐アプリ
WidgetExtension/             ウィジェット本体（通信しない）
Tests/                       単体テストと JSON フィクスチャ
docs/screenshots/            README 用スクリーンショット
scripts/                     sync-team / test / deploy-local / アイコン生成
```

`Info.plist` と `*.entitlements` は `project.yml` から生成されるため、リポジトリには含めていません。

バンドル ID は `jp.shigeya.AIUsageWidget` です。フォーク時は次も合わせて書き換えてください。

- `project.yml` の `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER`
- `Shared/AppSettings.swift` の `Notification.Name` と `groupSuffix`
- `Shared/CursorSession.swift` / `ClaudeSession.swift` / `ChatGPTSession.swift` の Keychain service 名
- `scripts/_common.sh` の `BUNDLE_ID`

App Group は `$(DEVELOPMENT_TEAM).jp.shigeya.AIUsageWidget` です。

`.app` のファイル名は濁点なし日本語の **AI使用量.app** です。英語表示名は `en.lproj` 側です。
`WRAPPER_NAME` を英語にしないでください。

## 注意

- 使用量 API は非公式で、予告なく変わる可能性があります
- 個人の私的利用を想定しています
- Cursor / Anthropic / OpenAI サポートへこのアプリの不具合を問い合わせないでください

## ライセンス

[MIT License](LICENSE)
