// usb-trigger
//   LaunchAgent が「iPhone が USB でつながった」(com.apple.iokit.matching)で起動する入口。
//   この合図で起動されたジョブは、合図を受け取らないと launchd に何度も起動し直されるので、受け取ってから
//   引数のコマンド(ios-reinstall.rb)を実行し、その終了コードで終わる。ruby からは合図を受け取れないため、これを挟む。
//   setup.rb が swiftc でビルドする。

import Foundation
import XPC

let command = Array(CommandLine.arguments.dropFirst())
guard !command.isEmpty else {
  FileHandle.standardError.write("usage: usb-trigger <command> [args...]\n".data(using: .utf8)!)
  exit(2)
}

// 受け取るだけでよい(中身は使わない)。たまっている合図は、ハンドラを置いた直後にまとめて届く
xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in }

// 合図が届くのを少し待ってから実行する。手で実行したときなど、合図がなくても実行する
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: command[0])
  process.arguments = Array(command.dropFirst())
  do {
    try process.run()
  } catch {
    FileHandle.standardError.write("usb-trigger: \(command[0]) を実行できません: \(error)\n".data(using: .utf8)!)
    exit(2)
  }
  process.waitUntilExit()
  exit(process.terminationStatus)
}

dispatchMain()
