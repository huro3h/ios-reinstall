#!/usr/bin/env ruby
# frozen_string_literal: true

# ios-reinstall
#   無料の Apple ID(Personal Team)で入れた自作 iOS アプリは、署名のプロファイルが7日で切れると起動できなくなる。
#   iPhone が USB でつながっていて、期限が近いアプリがあれば、プロファイルを作り直して入れ直す。
#   既定では残りが6日を切っていれば入れ直すので、毎日つなぐ習慣にすれば期限を気にしなくてよくなる。
#   LaunchAgent から5分ごとに起動される(setup.rb)。手で実行してもよい。
#
#   入れるのは手元の作業中のコードではなく、最新のリリース(タグ)。キャッシュに clone した別の作業ツリーで作る。
#
#   exit 0 = 何もしなかった・すべて成功 / 1 = 失敗したアプリがある / 2 = エラー

require 'optparse'
require 'json'
require 'open3'
require 'tempfile'
require 'fileutils'
require 'time'

# launchd 配下では LANG が渡らず default_external が US-ASCII になり、日本語の出力で例外になるため固定する
Encoding.default_external = Encoding::UTF_8
$stdout.sync = true

# リリース時はこことタグ(注釈付き・v なしの数字のみ)と CHANGELOG.md を揃える
VERSION = '1.0.0'

TOOL_ROOT    = File.expand_path(__dir__)
CONFIG       = File.join(TOOL_ROOT, 'ios-reinstall.json')
CACHE        = File.join(Dir.home, 'Library', 'Caches', 'ios-reinstall')
STATE        = File.join(CACHE, 'state.json')
PROFILES_DIR = File.join(Dir.home, 'Library', 'Developer', 'Xcode', 'UserData', 'Provisioning Profiles')
# xcode-select が CommandLineTools を向いていても Xcode の xcodebuild / devicectl を使う
ENV['DEVELOPER_DIR'] ||= '/Applications/Xcode.app/Contents/Developer'

# 失敗したアプリ・ロック中の知らせは、5分ごとに繰り返さないよう間を空ける
RETRY_AFTER  = 60 * 60
DAY          = 24 * 60 * 60

def log(message) = puts("#{Time.now.strftime('%F %T')} #{message}")
def die(message) = (warn "error: #{message}"; exit 2)

def notify(message)
  script = "display notification #{message.to_json} with title \"ios-reinstall\""
  Open3.capture2e('osascript', '-e', script)
end

# コマンドを実行し、失敗したら出力の末尾を付けて例外にする
def run!(*command, chdir: Dir.pwd)
  output, status = Open3.capture2e(*command, chdir: chdir)
  return output if status.success?

  raise "#{command.first(3).join(' ')} に失敗しました:\n#{output.lines.last(30).join}"
end

# devicectl の結果は JSON ファイルに書き出させて読むのが正式な使い方(標準出力の書式は保証されない)
def devicectl(*args)
  Tempfile.create(['devicectl', '.json']) do |file|
    run!('xcrun', 'devicectl', *args, '--quiet', '--json-output', file.path)
    JSON.parse(File.read(file.path))['result']
  end
end

# .mobileprovision は署名(CMS)で包まれているが、中の plist は平文のまま入っている。
# 日付やバイナリ(証明書)を含むので JSON には変換できない。必要な値だけ plutil -extract で取り出す
def read_profile(path)
  data = File.binread(path)
  start = data.index('<?xml')
  finish = data.index('</plist>', start || 0)
  return nil unless start && finish

  xml = data[start...(finish + '</plist>'.length)]
  extract = lambda do |key|
    output, status = Open3.capture2('plutil', '-extract', key, 'raw', '-o', '-', '-', stdin_data: xml)
    status.success? ? output.strip : nil
  end
  application_identifier = extract.call('Entitlements.application-identifier')
  expiration = extract.call('ExpirationDate')
  return nil unless application_identifier && expiration

  # 値は UTC で入っているので、通知やログに出すために手元の時刻にする
  { application_identifier: application_identifier, expires_at: Time.parse(expiration).localtime }
end

# Xcode が手元に持っているそのアプリのプロファイル。入れ直すたびに同じものが使われるので、
# いちばん新しいものの期限を、いま iPhone に入っているアプリの期限とみなす
def profiles_for(bundle_id)
  Dir.glob(File.join(PROFILES_DIR, '*.mobileprovision')).filter_map do |path|
    profile = read_profile(path)
    next unless profile && profile[:application_identifier].end_with?(".#{bundle_id}")

    profile.merge(path: path)
  end
end

def bundle_id_of(app)
  return app['bundle_id'] if app['bundle_id']

  # aozora・pixwash は署名の値を git 管理外の Config/Local.xcconfig に置いている
  local = File.join(app['project_dir'], 'Config', 'Local.xcconfig')
  File.exist?(local) && File.read(local)[/^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)/, 1]
end

def load_state = File.exist?(STATE) ? JSON.parse(File.read(STATE)) : {}

def save_state(state)
  FileUtils.mkdir_p(CACHE)
  File.write(STATE, JSON.pretty_generate(state))
end

def recently?(time) = time && Time.now - Time.parse(time) < RETRY_AFTER

def remaining_text(expires_at)
  return '期限切れ' unless expires_at && expires_at > Time.now

  days = (expires_at - Time.now) / DAY
  days >= 1 ? "あと#{days.floor}日" : "あと#{((expires_at - Time.now) / 3600).ceil}時間"
end

# USB でつながっていて、ペアリング済みの iPhone(Wi-Fi 経由は遅く途中で切れやすいので使わない)
def wired_devices
  devicectl('list', 'devices')['devices'].select do |device|
    connection = device['connectionProperties'] || {}
    connection['transportType'] == 'wired' && connection['pairingState'] == 'paired'
  end
end

def unlocked?(device)
  !devicectl('device', 'info', 'lockState', '--device', device['identifier'])['passcodeRequired']
end

def installed?(device, bundle_id)
  devicectl('device', 'info', 'apps', '--device', device['identifier'], '--bundle-id', bundle_id)['apps'].any?
end

# 最新のタグをキャッシュの作業ツリーに取り出し、署名の設定を写して .xcodeproj を作る
def prepare_source(app, name)
  source = File.join(CACHE, name)
  run!('git', 'clone', '--quiet', app['project_dir'], source) unless Dir.exist?(File.join(source, '.git'))
  run!('git', '-C', source, 'fetch', '--quiet', '--tags', '--force', 'origin')
  tag = run!('git', '-C', app['project_dir'], 'tag', '--sort=-v:refname').lines.first&.strip
  raise "#{name} にタグがありません" if tag.nil? || tag.empty?

  run!('git', '-C', source, 'checkout', '--quiet', '--detach', '--force', tag)
  # 前回のビルド結果(build/)は残して、次のビルドを速くする
  run!('git', '-C', source, 'clean', '-fdxq', '-e', 'build')
  FileUtils.cp(File.join(app['project_dir'], 'Config', 'Local.xcconfig'), File.join(source, 'Config'))
  run!('xcodegen', 'generate', '--quiet', chdir: source)
  [source, tag]
end

def reinstall(app, name, bundle_id, device)
  source, tag = prepare_source(app, name)
  scheme = app['scheme']
  # 手元のプロファイルが残っていると、それがそのまま使われて期限が延びない。消せば Xcode が新しく作る
  profiles_for(bundle_id).each { |profile| File.delete(profile[:path]) }
  run!('xcodebuild', '-quiet', '-project', "#{scheme}.xcodeproj", '-scheme', scheme,
       '-destination', "id=#{device.dig('hardwareProperties', 'udid')}",
       '-derivedDataPath', 'build/DerivedData',
       '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build', chdir: source)
  built = File.join(source, 'build', 'DerivedData', 'Build', 'Products', 'Debug-iphoneos', "#{scheme}.app")
  run!('xcrun', 'devicectl', 'device', 'install', 'app', '--device', device['identifier'], built)
  [tag, read_profile(File.join(built, 'embedded.mobileprovision'))&.dig(:expires_at)]
end

opts = { config: CONFIG }
OptionParser.new do |o|
  o.banner = "Usage: ios-reinstall.rb [options]\n\n" \
             "  USB でつながった iPhone に、署名の期限が近い自作アプリを入れ直す。\n\n"
  o.on('--dry-run', '期限を見るだけで、入れ直さない') { opts[:dry_run] = true }
  o.on('--force NAME', '期限に関係なく、このアプリを入れ直す') { |name| opts[:force] = name }
  o.on('--config PATH', "設定ファイル(既定: #{CONFIG})") { |path| opts[:config] = path }
  o.on('-v', '--version') { puts VERSION; exit 0 }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!(ARGV)

die("設定ファイルがありません: #{opts[:config]}(ios-reinstall.example.json を写して作る)") unless File.exist?(opts[:config])
config = JSON.parse(File.read(opts[:config]))
# 期限まで残りがこの日数を切っていたら入れ直す。既定の 6 は「毎日つなげば1日1回、新しい7日に延びる」
threshold = (config['threshold_days'] || 6) * DAY

# LaunchAgent の起動と手での実行が重ならないようにする
FileUtils.mkdir_p(CACHE)
lock = File.open(File.join(CACHE, 'lock'), File::RDWR | File::CREAT)
exit 0 unless lock.flock(File::LOCK_EX | File::LOCK_NB)

devices = wired_devices
exit 0 if devices.empty?

state = load_state
failed = false
devices.each do |device|
  device_name = device.dig('deviceProperties', 'name')
  config['apps'].each do |app|
    app = app.merge('project_dir' => File.expand_path(app['project_dir']))
    name = app['name'] || File.basename(app['project_dir'])
    bundle_id = bundle_id_of(app)
    unless bundle_id
      log "#{name}: bundle id が分かりません(設定の bundle_id か Config/Local.xcconfig を確かめる)"
      next
    end

    expires_at = profiles_for(bundle_id).map { |profile| profile[:expires_at] }.max
    due = expires_at.nil? || expires_at - Time.now < threshold
    next unless due || opts[:force] == name
    next unless installed?(device, bundle_id)

    key = "#{device['identifier']}/#{name}"
    if opts[:dry_run]
      log "#{name}: #{remaining_text(expires_at)} → 入れ直す対象(--dry-run なので入れ直さない)"
      next
    end
    # 失敗したら1時間は試し直さない(5分ごとに失敗の通知が出続けないように)
    next if !opts[:force] && recently?(state.dig(key, 'failed_at'))

    unless unlocked?(device)
      unless recently?(state.dig(key, 'locked_notified_at'))
        notify("#{device_name} のロックを外すと、#{name} を入れ直します(#{remaining_text(expires_at)})")
        state[key] = (state[key] || {}).merge('locked_notified_at' => Time.now.iso8601)
        save_state(state)
      end
      next
    end

    reason = due ? remaining_text(expires_at) : '--force の指定'
    log "#{name}: #{reason}なので #{device_name} に入れ直します"
    begin
      tag, new_expires_at = reinstall(app, name, bundle_id, device)
      log "#{name}: #{tag} を入れ直しました(期限 #{new_expires_at&.strftime('%m/%d %H:%M')})"
      notify("#{name} #{tag} を入れ直しました。次の期限は #{new_expires_at&.strftime('%m/%d %H:%M')}")
      state.delete(key)
    rescue StandardError => e
      failed = true
      log "#{name}: #{e.message}"
      notify("#{name} の入れ直しに失敗しました。ログ: ~/Library/Logs/ios-reinstall.log")
      state[key] = { 'failed_at' => Time.now.iso8601 }
    end
    save_state(state)
  end
end

exit(failed ? 1 : 0)
