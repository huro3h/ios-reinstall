#!/usr/bin/env ruby
# frozen_string_literal: true

# ios-reinstall のセットアップ。LaunchAgent の plist をテンプレートから生成して読み込ませる。
# plist には ruby とスクリプトの絶対パスが要るので、静的ファイルでは持ち運べない。
#
#   exit 0 = OK / 2 = エラー

require 'optparse'
require 'open3'
require 'rbconfig'
require 'fileutils'

LABEL     = 'local.ios-reinstall'
TOOL_ROOT = File.expand_path(__dir__)
TEMPLATE  = File.join(TOOL_ROOT, "#{LABEL}.plist.template")
SCRIPT    = File.join(TOOL_ROOT, 'ios-reinstall.rb')
CONFIG    = File.join(TOOL_ROOT, 'ios-reinstall.json')
DEST      = File.join(Dir.home, 'Library', 'LaunchAgents', "#{LABEL}.plist")
LOG       = File.join(Dir.home, 'Library', 'Logs', 'ios-reinstall.log')

def die(msg) = (warn "error: #{msg}"; exit 2)

opts = {}
OptionParser.new do |o|
  o.banner = "Usage: setup.rb [--apply | --uninstall --apply]\n\n" \
             "  LaunchAgent(#{LABEL})を生成して読み込む。既定はドライラン。\n\n"
  o.on('--apply', '実際に書き込んで読み込む') { opts[:apply] = true }
  o.on('--uninstall', 'LaunchAgent を削除する') { opts[:uninstall] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!(ARGV)

uid = Process.uid

if opts[:uninstall]
  unless opts[:apply]
    puts "削除する: #{DEST} (+ launchctl bootout)"
    puts '  実行するには --apply を付けてください'
    exit 0
  end
  Open3.capture3('launchctl', 'bootout', "gui/#{uid}/#{LABEL}")
  File.delete(DEST) if File.exist?(DEST)
  puts "削除しました: #{LABEL}"
  exit 0
end

die("テンプレートがありません: #{TEMPLATE}") unless File.exist?(TEMPLATE)
die("実行ファイルがありません: #{SCRIPT}") unless File.executable?(SCRIPT)
die("設定ファイルがありません: #{CONFIG}(ios-reinstall.example.json を写して作る)") unless File.exist?(CONFIG)

# rbenv の shim は launchd から解決できないので、実体の ruby を埋める
plist = File.read(TEMPLATE)
            .gsub('{{LABEL}}', LABEL)
            .gsub('{{RUBY}}', RbConfig.ruby)
            .gsub('{{SCRIPT}}', SCRIPT)
            .gsub('{{LOG}}', LOG)

unless opts[:apply]
  puts "生成先: #{DEST}"
  puts "  ruby   : #{RbConfig.ruby}"
  puts "  script : #{SCRIPT}"
  puts "  log    : #{LOG}"
  puts "\n実際に書き込んで読み込むには --apply を付けてください"
  exit 0
end

FileUtils.mkdir_p(File.dirname(DEST))
File.write(DEST, plist)
_, err, st = Open3.capture3('plutil', '-lint', DEST)
die("plist が不正です: #{err}") unless st.success?

Open3.capture3('launchctl', 'bootout', "gui/#{uid}/#{LABEL}") # 既存があれば外す
_, err, st = Open3.capture3('launchctl', 'bootstrap', "gui/#{uid}", DEST)
die("launchctl bootstrap に失敗: #{err}") unless st.success?

puts "LaunchAgent を読み込みました: #{LABEL}"
puts "  ログ: tail -f #{LOG}"
