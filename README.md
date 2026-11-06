# ios-reinstall

無料の Apple ID(Personal Team)で iPhone に入れた自作アプリは、署名のプロファイルが **7日で切れて起動できなくなる**。
iPhone を Mac に USB でつなぐと、期限が近いアプリのプロファイルを作り直して入れ直す macOS 用の常駐ツール。

- iPhone を USB でつなぐと LaunchAgent が起動する(5分ごとに見に行くことはしない)
- 設定に書いたアプリのうち、iPhone に入っていて、期限まで残りが `threshold_days` 日(既定 6)を切ったものを入れ直す。
  毎日つなぐ習慣にすれば、1日1回、新しい7日に延びる
- 入れるのは手元の作業中のコードではなく、**最新のリリース(git のタグ)**
- 入れ直している間はターミナルのウインドウを開いて進み具合を出し、終わったら閉じる(ターミナルが起動していなかったら終了させる)
- iPhone がロック中なら、ロックを外すよう Mac の通知で知らせ、外れるまで最大10分待つ。終わったとき・失敗したときも通知する

## 必要なもの

- Xcode(Apple ID を追加して、対象のアプリを一度は実機に入れられる状態)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)(対象のアプリが `project.yml` から `.xcodeproj` を作る前提)
- Ruby
- Swift(Xcode に含まれる。`setup.rb` が、つないだ合図を受け取る `usb-trigger` をビルドする)

最初に入れ直すとき、ターミナルを操作してよいかを macOS が尋ねるので許可する。

対象のアプリは、署名の値(`PRODUCT_BUNDLE_IDENTIFIER` など)を git 管理外の `Config/Local.xcconfig` に置く構成を想定している。
違う場合は設定に `bundle_id` を書く。

## セットアップ

```sh
cp ios-reinstall.example.json ios-reinstall.json   # 対象のアプリを書く
./ios-reinstall.rb --dry-run                       # 期限と、入れ直す対象になるかを見る
./setup.rb --apply                                 # usb-trigger をビルドし、LaunchAgent に登録する
```

ログは `~/Library/Logs/ios-reinstall.log`。ビルドで警告かエラーが出たときは、そのビルドの出力全体を
このリポジトリの `error-log/<日時>-<アプリ>-<タグ>.log`(git 管理外)にも残し、通知とターミナルにその場所を出す
(依存パッケージの警告だけなら残さない)。外すときは `./setup.rb --uninstall --apply`。

## 設定(ios-reinstall.json)

| キー | 意味 |
|---|---|
| `threshold_days` | 期限まで残りがこの日数を切っていたら入れ直す(既定 6) |
| `apps[].name` | 表示用の名前(通知・ログ) |
| `apps[].project_dir` | アプリの git リポジトリ |
| `apps[].scheme` | Xcode のスキーム名(`.xcodeproj` の名前も同じ前提) |
| `apps[].bundle_id` | 省略時は `Config/Local.xcconfig` の `PRODUCT_BUNDLE_IDENTIFIER` |

期限に関係なく今すぐ入れ直すには `./ios-reinstall.rb --force <name>`。
