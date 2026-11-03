# ios-reinstall

無料の Apple ID(Personal Team)で iPhone に入れた自作アプリは、署名のプロファイルが **7日で切れて起動できなくなる**。
iPhone を Mac に USB でつなぐと、期限が近いアプリのプロファイルを作り直して入れ直す macOS 用の常駐ツール。

- 5分ごとに LaunchAgent が起動し、USB でつながった iPhone があるか見る(なければすぐ終わる)
- 設定に書いたアプリのうち、iPhone に入っていて、期限まで残りが `threshold_days` 日(既定 6)を切ったものを入れ直す。
  毎日つなぐ習慣にすれば、1日1回、新しい7日に延びる
- 入れるのは手元の作業中のコードではなく、**最新のリリース(git のタグ)**
- iPhone がロック中なら、ロックを外すよう Mac の通知で知らせる。終わったとき・失敗したときも通知する

## 必要なもの

- Xcode(Apple ID を追加して、対象のアプリを一度は実機に入れられる状態)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)(対象のアプリが `project.yml` から `.xcodeproj` を作る前提)
- Ruby

対象のアプリは、署名の値(`PRODUCT_BUNDLE_IDENTIFIER` など)を git 管理外の `Config/Local.xcconfig` に置く構成を想定している。
違う場合は設定に `bundle_id` を書く。

## セットアップ

```sh
cp ios-reinstall.example.json ios-reinstall.json   # 対象のアプリを書く
./ios-reinstall.rb --dry-run                       # 期限と、入れ直す対象になるかを見る
./setup.rb --apply                                 # LaunchAgent に登録する
```

ログは `~/Library/Logs/ios-reinstall.log`。外すときは `./setup.rb --uninstall --apply`。

## 設定(ios-reinstall.json)

| キー | 意味 |
|---|---|
| `threshold_days` | 期限まで残りがこの日数を切っていたら入れ直す(既定 6) |
| `apps[].name` | 表示用の名前(通知・ログ) |
| `apps[].project_dir` | アプリの git リポジトリ |
| `apps[].scheme` | Xcode のスキーム名(`.xcodeproj` の名前も同じ前提) |
| `apps[].bundle_id` | 省略時は `Config/Local.xcconfig` の `PRODUCT_BUNDLE_IDENTIFIER` |

期限に関係なく今すぐ入れ直すには `./ios-reinstall.rb --force <name>`。
