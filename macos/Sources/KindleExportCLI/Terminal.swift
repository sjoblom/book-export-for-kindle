import Foundation
import KindleExportKit

/// Writing to and reading from the terminal.
enum Terminal {
  /// Straight to the file descriptors, unbuffered: stdout and stderr lines
  /// then interleave in the order they were written, as in the Node tool.
  static func print(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
  }

  static func error(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  static func write(_ line: CommandLineOutput.Line) {
    if line.isError { error(line.text) } else { print(line.text) }
  }

  /// Someone at a keyboard: prompts can be answered and a sign-in window
  /// will be noticed.
  static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 }

  /// Ask and wait for a line; `nil` at end of input. Read off the main
  /// thread so Ctrl-C (a dispatch source on the main queue) still works
  /// while the question is open.
  static func prompt(_ question: String) async -> String? {
    FileHandle.standardOutput.write(Data(question.utf8))
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: readLine(strippingNewline: true))
      }
    }
  }

  static func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
  }
}
