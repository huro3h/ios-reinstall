---
name: ios-reinstall
description: ios-reinstall(USB でつないだ iPhone に、Personal Team の署名の期限が近い自作 iOS アプリを入れ直す macOS 常駐ツール)を改修するときに使う。期限の読み方、プロファイルを作り直す仕組み、devicectl の使い方とハマりどころをまとめている。
---

# ios-reinstall

## 何をしているか

`ios-reinstall.rb` を LaunchAgent(`local.ios-reinstall`、`StartInterval` 300 秒)が起動する。

1. `devicectl list devices` で、`transportType == "wired"` かつ `pairingState == "paired"` の iPhone を探す。なければ終わる。
   Wi-Fi 経由(transportType が wired 以外)は遅く途中で切れやすいので使わない。
2. 設定のアプリごとに、Mac の `~/Library/Developer/Xcode/UserData/Provisioning Profiles` からそのアプリのプロファイルを探し、
   いちばん新しい期限を「いま iPhone に入っているアプリの期限」とみなす(**iPhone 側の期限は devicectl では取れない**)。
3. 期限まで `threshold_days`(既定 6)を切っていて、`devicectl device info apps --bundle-id` でアプリが入っていれば入れ直す
   (入っていないアプリを勝手に入れない)。
4. 入れ直し: キャッシュ(`~/Library/Caches/ios-reinstall/<name>`)に clone した作業ツリーで最新のタグを checkout し、
   `Config/Local.xcconfig` を写して `xcodegen generate` → **手元のプロファイルを消して** `xcodebuild -allowProvisioningUpdates`
   → `devicectl device install app`。起動はしない(使っている最中のアプリを勝手に前に出さない)。

## なぜこうしたか

- **既定 6 日**: ユーザーの希望で「つなぐたびに作り直す」(2026-11-03)。毎回にすると同じ日に何度もつなぎ直したときに無駄なので、
  「残り6日未満」= 実質1日1回にした。日々つなぐ習慣にすれば、アプリ内の期限表示を見る機会も減らせる。
- **プロファイルを消してから作る**: 期限内のプロファイルが手元にあると、入れ直してもそれがそのまま使われ、期限は延びない。
  消してからビルドすると、Xcode がその時点から7日のプロファイルを新しく作る(2026-11-03 に pixwash で確認)。
- **タグから作る**: 手元の作業ツリーは作業中のことがあるので、リリースした版を入れる。手元のリポジトリに worktree を足さず clone にしたのは、
  元のリポジトリの .git を触らないため。`build/` は `git clean -e build` で残して、次のビルドを速くする。
- 失敗したら1時間は試し直さない・ロック中の通知も1時間に1回(`state.json`)。5分ごとに通知が出続けないようにするため。
- 二重起動は `flock` で防ぐ(LaunchAgent と手での実行が重なることがある)。

## ハマりどころ

- `.mobileprovision` は CMS で署名されているが、中の plist は平文。`<?xml`〜`</plist>` を切り出して読む。
  **`plutil -convert json` は使えない**(日付・バイナリ(証明書)を含むので変換に失敗する)。`plutil -extract <key> raw` で必要な値だけ取る。
  日付は UTC で出てくるので `localtime` にしてから表示する(最初は通知に UTC の時刻が出ていた)。
- devicectl の結果は `--json-output` でファイルに書かせて読む(標準出力の書式は保証されないと help にある)。
  ロック中かどうかは `device info lockState` の `passcodeRequired`。
- launchd からは PATH に Homebrew がなく、`xcode-select` が CommandLineTools を向いていることもあるので、
  plist で `PATH`(`/opt/homebrew/bin` を含む)と `DEVELOPER_DIR` を渡す。LANG がないと osascript に渡す日本語が化ける。
- rbenv の shim は launchd から解決できないので、`setup.rb` が実体の ruby のパスを plist に埋める(app-respawn と同じ)。

## 対象のアプリ側

aozora・pixwash はヘッダーの真ん中に署名の期限(「期限 11/10・あと6日」)を出している(`Support/ProvisioningExpiry.swift`、両方に同じファイル)。
アプリ内の `embedded.mobileprovision` を読んでいる。
