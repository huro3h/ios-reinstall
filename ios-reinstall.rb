#!/usr/bin/env ruby
# frozen_string_literal: true

# ios-reinstall
#   無料の Apple ID(Personal Team)で入れた自作 iOS アプリは、署名のプロファイルが7日で切れると起動できなくなる。
#   iPhone が USB でつながっていて、期限が近いアプリがあれば、プロファイルを作り直して入れ直す。
#   既定では残りが6日を切っていれば入れ直すので、毎日つなぐ習慣にすれば期限を気にしなくてよくなる。
#   iPhone を USB でつなぐと、LaunchAgent から usb-trigger 経由で --on-connect 付きで起動される(setup.rb)。手で実行してもよい。
#
#   入れるのは手元の作業中のコードではなく、最新のリリース(タグ)。キャッシュに clone した別の作業ツリーで作る。
#   入れ直しを始めるとターミナルのウインドウを開いて進み具合を出し、終わったら閉じる。
#
#   exit 0 = 何もしなかった・すべて成功 / 1 = 失敗したアプリがある / 2 = エラー

require 'optparse'
require 'json'
require 'open3'
require 'tempfile'
require 'fileutils'
require 'time'
require 'rbconfig'

# launchd 配下では LANG が渡らず default_external が US-ASCII になり、日本語の出力で例外になるため固定する
Encoding.default_external = Encoding::UTF_8
$stdout.sync = true

# リリース時はこことタグ(注釈付き・v なしの数字のみ)と CHANGELOG.md を揃える
VERSION = '1.2.1'

TOOL_ROOT    = File.expand_path(__dir__)
CONFIG       = File.join(TOOL_ROOT, 'ios-reinstall.json')
CACHE        = File.join(Dir.home, 'Library', 'Caches', 'ios-reinstall')
PROGRESS     = File.join(CACHE, 'progress.log')
# 警告・エラーが出たビルドの出力を、ビルドごとに1ファイルで残す場所(git 管理外)
BUILD_LOGS   = File.join(TOOL_ROOT, 'error-log')
PROFILES_DIR = File.join(Dir.home, 'Library', 'Developer', 'Xcode', 'UserData', 'Provisioning Profiles')
# xcode-select が CommandLineTools を向いていても Xcode の xcodebuild / devicectl を使う
ENV['DEVELOPER_DIR'] ||= '/Applications/Xcode.app/Contents/Developer'

DAY          = 24 * 60 * 60
# --on-connect のとき、つないだ iPhone が devicectl から見えるまで・ロックが外れるまで待つ長さ
DEVICE_WAIT  = 30
UNLOCK_WAIT  = 10 * 60
# 進み具合のファイルの終わりの印。ターミナルで読んでいる側(--follow)はこの行で終わる
PROGRESS_END = '__ios-reinstall-end__'

$progress = nil # 入れ直している間だけ開いている、進み具合のファイル

def emit(line)
  puts line
  $progress&.puts(line)
end

def log(message) = emit("#{Time.now.strftime('%F %T')} #{message}")
def die(message) = (warn "error: #{message}"; exit 2)

def notify(message)
  script = "display notification #{message.to_json} with title \"ios-reinstall\""
  Open3.capture2e('osascript', '-e', script)
end

def applescript(script)
  output, = Open3.capture2e('osascript', '-e', script)
  output.strip
end

# 失敗したコマンドの出力を、あとからファイルに残せるように持たせておく
class CommandFailed < StandardError
  attr_reader :output

  def initialize(message, output)
    super(message)
    @output = output
  end
end

# コマンドを実行し、失敗したら出力の末尾を付けて例外にする。stream: true なら出力をそのままログと進み具合にも流す
def run!(*command, chdir: Dir.pwd, stream: false)
  output = +''
  status = Open3.popen2e(*command, chdir: chdir) do |_stdin, out, thread|
    out.each_line do |line|
      output << line
      emit("  #{line.chomp}") if stream
    end
    thread.value
  end
  return output if status.success?

  raise CommandFailed.new("#{command.first(3).join(' ')} に失敗しました:\n#{output.lines.last(30).join}", output)
end

# ビルドの出力に警告かエラーがあれば、出力全体をファイルに残してそのパスを返す。
# 依存パッケージ(SourcePackages の下)の警告は直す対象ではないので数えない(毎回ファイルができてしまう)
def save_build_log(name, tag, output)
  issues = output.lines.grep(/\b(warning|error):/).grep_v(%r{/SourcePackages/})
  return nil if issues.empty?

  FileUtils.mkdir_p(BUILD_LOGS)
  path = File.join(BUILD_LOGS, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{name}-#{tag}.log")
  File.write(path, output)
  { path: path, warnings: issues.grep(/\bwarning:/).size, errors: issues.grep(/\berror:/).size }
end

def build_log_text(build_log)
  counts = [("警告 #{build_log[:warnings]} 件" if build_log[:warnings].positive?),
            ("エラー #{build_log[:errors]} 件" if build_log[:errors].positive?)].compact.join('・')
  "#{counts}。ログ: #{build_log[:path].sub(Dir.home, '~')}"
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

# つないだ直後は devicectl からまだ見えないことがあるので、見えるまで少し待つ
def wait_for_devices
  deadline = Time.now + DEVICE_WAIT
  loop do
    devices = wired_devices
    return devices if devices.any? || Time.now > deadline

    sleep 3
  end
end

def unlocked?(device)
  !devicectl('device', 'info', 'lockState', '--device', device['identifier'])['passcodeRequired']
end

# 途中で外されると devicectl が失敗するので、そのときもあきらめる
def wait_for_unlock(device)
  deadline = Time.now + UNLOCK_WAIT
  sleep 5 until unlocked?(device) || Time.now > deadline
  unlocked?(device)
rescue StandardError
  false
end

# ターミナルで新しいウインドウを開き、進み具合のファイルを --follow で読ませる。
# 起動していなかったら起動して、最初に開くウインドウを使う(do script だけだと2枚開く)
def open_progress_window
  FileUtils.mkdir_p(CACHE)
  $progress = File.open(PROGRESS, 'w')
  $progress.sync = true
  command = [RbConfig.ruby, File.join(TOOL_ROOT, 'ios-reinstall.rb'), '--follow', PROGRESS]
            .map { |arg| "'#{arg}'" }.join(' ') + '; exit'
  was_running = applescript('application "Terminal" is running') == 'true'
  id = applescript(<<~SCRIPT)
    tell application "Terminal"
      if #{was_running} then
        do script #{command.to_json}
      else
        activate
        do script #{command.to_json} in window 1
      end if
      activate
      id of front window
    end tell
  SCRIPT
  { id: id.to_i, was_running: was_running }
end

# 読んでいる側が終わってから閉じる(動いているうちに閉じると、ターミナルが確認を出す)。
# ターミナルが起動していなかったなら、ターミナルごと終わらせる
def close_progress_window(window, success)
  emit(success ? 'すべて終わりました。このウインドウは閉じます' : '失敗しました。ログ: ~/Library/Logs/ios-reinstall.log')
  $progress.puts(PROGRESS_END)
  $progress.close
  $progress = nil
  sleep 3
  applescript(<<~SCRIPT)
    tell application "Terminal"
      close (every window whose id is #{window[:id]})
      if not #{window[:was_running]} and (count of windows) is 0 then quit
    end tell
  SCRIPT
end

# ターミナルのウインドウで、進み具合のファイルを終わりの印まで出し続ける
def follow(path)
  buffer = +''
  File.open(path) do |file|
    loop do
      chunk = file.read_nonblock(4096, exception: false)
      next sleep(0.2) if chunk.nil? || chunk == :wait_readable

      buffer << chunk.force_encoding(Encoding::UTF_8)
      while (newline = buffer.index("\n"))
        line = buffer.slice!(0..newline).chomp
        return if line == PROGRESS_END

        puts line
      end
    end
  end
end

def installed?(device, bundle_id)
  devicectl('device', 'info', 'apps', '--device', device['identifier'], '--bundle-id', bundle_id)['apps'].any?
end

# 最新のタグをキャッシュの作業ツリーに取り出し、署名の設定を写して .xcodeproj を作る
def prepare_source(app, name)
  source = File.join(CACHE, name)
  log "#{name}: 最新のタグを取り出しています"
  run!('git', 'clone', '--quiet', app['project_dir'], source) unless Dir.exist?(File.join(source, '.git'))
  run!('git', '-C', source, 'fetch', '--quiet', '--tags', '--force', 'origin')
  tag = run!('git', '-C', app['project_dir'], 'tag', '--sort=-v:refname').lines.first&.strip
  raise "#{name} にタグがありません" if tag.nil? || tag.empty?

  run!('git', '-C', source, 'checkout', '--quiet', '--detach', '--force', tag)
  # 前回のビルド結果(build/)は残して、次のビルドを速くする
  run!('git', '-C', source, 'clean', '-fdxq', '-e', 'build')
  FileUtils.cp(File.join(app['project_dir'], 'Config', 'Local.xcconfig'), File.join(source, 'Config'))
  run!('xcodegen', 'generate', '--quiet', chdir: source)
  log "#{name}: #{tag} を取り出しました"
  [source, tag]
end

def reinstall(app, name, bundle_id, device)
  source, tag = prepare_source(app, name)
  scheme = app['scheme']
  # 手元のプロファイルが残っていると、それがそのまま使われて期限が延びない。消せば Xcode が新しく作る
  profiles_for(bundle_id).each { |profile| File.delete(profile[:path]) }
  log "#{name}: ビルドしています(プロファイルも作り直します)"
  begin
    output = run!('xcodebuild', '-quiet', '-project', "#{scheme}.xcodeproj", '-scheme', scheme,
                  '-destination', "id=#{device.dig('hardwareProperties', 'udid')}",
                  '-derivedDataPath', 'build/DerivedData',
                  '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build', chdir: source, stream: true)
  rescue CommandFailed => e
    build_log = save_build_log(name, tag, e.output)
    raise build_log ? "ビルドに失敗しました(#{build_log_text(build_log)})" : e.message
  end
  build_log = save_build_log(name, tag, output)
  log "#{name}: ビルドで#{build_log_text(build_log)}" if build_log
  built = File.join(source, 'build', 'DerivedData', 'Build', 'Products', 'Debug-iphoneos', "#{scheme}.app")
  log "#{name}: iPhone に入れています"
  run!('xcrun', 'devicectl', 'device', 'install', 'app', '--device', device['identifier'], built, stream: true)
  [tag, read_profile(File.join(built, 'embedded.mobileprovision'))&.dig(:expires_at), build_log]
end

opts = { config: CONFIG }
OptionParser.new do |o|
  o.banner = "Usage: ios-reinstall.rb [options]\n\n" \
             "  USB でつながった iPhone に、署名の期限が近い自作アプリを入れ直す。\n\n"
  o.on('--dry-run', '期限を見るだけで、入れ直さない') { opts[:dry_run] = true }
  o.on('--force NAME', '期限に関係なく、このアプリを入れ直す') { |name| opts[:force] = name }
  o.on('--on-connect', 'iPhone をつないだときの起動(見えるまで・ロックが外れるまで待つ)') { opts[:on_connect] = true }
  o.on('--follow PATH', '進み具合のファイルを出し続ける(ターミナルのウインドウで使う)') { |path| follow(path); exit 0 }
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

devices = opts[:on_connect] ? wait_for_devices : wired_devices
exit 0 if devices.empty?

window = nil
failed = false
devices.each do |device|
  device_name = device.dig('deviceProperties', 'name')
  targets = config['apps'].filter_map do |app|
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

    reason = due ? remaining_text(expires_at) : '--force の指定'
    if opts[:dry_run]
      log "#{name}: #{reason} → 入れ直す対象(--dry-run なので入れ直さない)"
      next
    end
    { app: app, name: name, bundle_id: bundle_id, reason: reason }
  end
  next if targets.empty?

  unless unlocked?(device)
    names = targets.map { |target| "#{target[:name]}(#{target[:reason]})" }.join('・')
    notify("#{device_name} のロックを外すと、#{names} を入れ直します")
    # つないだときにしか起動しないので、ロックが外れるまでここで待つ
    unless opts[:on_connect] && wait_for_unlock(device)
      log "#{device_name}: ロックが外れなかったので入れ直しません"
      next
    end
  end

  window ||= open_progress_window
  targets.each do |target|
    name = target[:name]
    log "#{name}: #{target[:reason]}なので #{device_name} に入れ直します"
    begin
      tag, new_expires_at, build_log = reinstall(target[:app], name, target[:bundle_id], device)
      log "#{name}: #{tag} を入れ直しました(期限 #{new_expires_at&.strftime('%m/%d %H:%M')})"
      message = "#{name} #{tag} を入れ直しました。次の期限は #{new_expires_at&.strftime('%m/%d %H:%M')}"
      notify(build_log ? "#{message}。ビルドで#{build_log_text(build_log)}" : message)
    rescue StandardError => e
      failed = true
      log "#{name}: #{e.message}"
      # ビルドの失敗なら、そのビルドのログの場所が e.message に入っている
      notify("#{name} の入れ直しに失敗しました。#{e.message.start_with?('ビルドに失敗') ? e.message : 'ログ: ~/Library/Logs/ios-reinstall.log'}")
    end
  end
end
close_progress_window(window, !failed) if window

exit(failed ? 1 : 0)
