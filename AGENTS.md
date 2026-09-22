# エージェント向けメモ

利用者向けの説明は [README.md](README.md) / [README.en.md](README.en.md) を参照。
ここにはビルド・署名・データ取得まわりの注意だけ書く。

## 新規クローン直後のセットアップ

`AIUsageWidget.xcodeproj` / `Info.plist` / `*.entitlements` は `project.yml` から生成され、
`.gitignore` によりリポジトリに含まれていない。**クローン直後や `project.yml` を編集した後は
`xcodegen generate` が必要**（`brew install xcodegen`）。

```sh
cp Config/Team.xcconfig.example Config/Team.xcconfig
./scripts/sync-team.sh
xcodegen generate
swift scripts/generate-app-icon.swift
./scripts/test.sh
./scripts/deploy-local.sh
```

`xcodegen generate` の前に **必ず `Config/Team.xcconfig` を用意して `./scripts/sync-team.sh`** する。
証明書から Team ID を書き、`DEVELOPMENT_TEAM` をビルドに乗せる。
これを忘れると App Group が `.jp.shigeya.AIUsageWidget` になり、App Intents の
エラーとウィジェット設定の不具合が同時に出る。

## ビルドについて（重要）

### 1. 必ず署名付きでビルドすること

AppIntents は Team ID 付き署名が必要。無署名や adhoc だとウィジェットがプレースホルダのまま止まる。
`.app` のファイル名は `AI使用量.app`（濁点なし）。実行ファイル名は ASCII の `AIUsageWidget` のまま。
濁点付き日本語の `.app` 名は拡張が起動しない。英語OS向けの表示名は `en.lproj/InfoPlist.strings` と
ウィジェットの `Localizable.strings`。`WRAPPER_NAME` を英語に変えないこと（Finder のローカライズ条件と
ギャラリーが見出しにファイル名を使う場合の日本語表示が壊れる）。

### 2. `CONFIGURATION_BUILD_DIR` を独自パスに上書きしないこと

標準の DerivedData にビルドし、配置は `scripts/deploy-local.sh` に任せる。同スクリプトは
完成した `.app` を `build/AI使用量.app` にもコピーする（`build/` は gitignore）。

Team ID は手元の「Apple Development」証明書の OU から引く。複数あるときは
`DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/deploy-local.sh`。

## テスト

`AIUsageWidgetTests` はホストアプリを立てない単体テスト。通信せず、原則 UserDefaults /
Keychain も本番経路では触らない（Cookie 正規化と JSON マッピングの純関数を検証する）。

- `CursorProviderMappingTests` — `Tests/Fixtures/` の usage-summary JSON
- `ClaudeProviderMappingTests` / `ChatGPTProviderMappingTests` — OAuth usage JSON
- `CursorSessionTests` / `ClaudeSessionTests` / `ChatGPTSessionTests` — Cookie / token の正規化
- `L10nTests` — 日本語 / English キー

## データソース

取得はホストの各 `*Provider.swift` に集約する。ウィジェット拡張は通信しない。
公式の使用量 API がある資格情報ではそちらを優先する。

- Cursor: 個人向け公式 API はない。`GET https://cursor.com/api/usage-summary`（非公式）。認証は `WorkosCursorSessionToken` Cookie。
- Claude サブスク: `GET https://api.anthropic.com/api/oauth/usage`。Claude Code の OAuth access token（refresh しない）。
- Claude API: 公式 `GET https://api.anthropic.com/v1/organizations/cost_report`（Admin / API キー）。
- Codex サブスク: `GET https://chatgpt.com/backend-api/wham/usage`（404 時は `.../codex/usage`）。Codex の access token（refresh しない）。
- OpenAI API: 公式 `GET https://api.openai.com/v1/organization/costs`（Admin / API キー）。

ホストはメニューバー常駐（サンドボックスなし。Cursor の `state.vscdb` や Claude / Codex のローカル資格情報を読むため）。
サンドボックスを外した結果、このプロセスは3社のローカル資格情報を読み、Claude Code では `/usr/bin/security` を起動し、読んだトークンを各使用量エンドポイントへ送る。
ウィジェット拡張はサンドボックスありで、`network.client` は付けない。App Group は Team ID 付き。

ウィジェット拡張の `Provider.buildEntry()` から通信してはいけない。スナップショットは
App が App Group に書いたものを読むだけ。

## 開発中に踏まないこと（subway-widget と同じ）

- `.app` 名に濁点付き日本語を入れない（拡張が起動せず空枠になる）
- アプリ終了は bundle ID（`tell application id "jp.shigeya.AIUsageWidget"`）
- `MenuBarExtra(.window)` は `NSApp.activate` しないと TextField が入力を受け取れない
- Cookie / JWT をログに出さない
- 通信は `UsageHTTP.session`（ephemeral / Cookie ストアもキャッシュも持たない）を使う。
  `URLSession.shared` は応答の `Set-Cookie` をディスクへ永続化するので使わない
- App Group から読んだ値を検証せずに使わない。同一ユーザーの任意プロセスが書ける。
  ダッシュボードの URL は `AppSettings.isAllowedDashboardURL` を通したものだけを開く
- 資格情報の入力欄は `SecureField`（`TextField` にしない）
- Keychain の再試行は `ClaudeSession.retryKeychainAccess` のレート制限を外さない
  （外部から更新要求を連投されてもダイアログを繰り返し出さないため）。
  期限切れのキャッシュだけは「更新」で捨てる。有効なキャッシュを捨てるとダイアログが再び出る
- 期限切れ（`tokenExpired`）を「ログインが無い」と同じ文言にまとめない。
  `error.tokenExpired.<provider id>` で「元アプリを開き直して更新」と案内する

## ログ

```sh
log stream --predicate 'subsystem beginswith "jp.shigeya.AIUsageWidget"' --level debug
```
