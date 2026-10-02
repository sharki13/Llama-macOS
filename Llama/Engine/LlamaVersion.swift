import Foundation

/// A llama.cpp build version. Comparison is by build number -- the monotonic
/// `bXXXX` counter llama.cpp bumps each release; commit shas and semantic
/// versions are ignored.
struct LlamaVersion: Comparable, CustomStringConvertible {
  /// The build number, e.g. `9370` for `b9370`.
  let build: Int
  /// The original token as reported, e.g. `b9370-aa50b2c2a`, or the full
  /// `version:` line for modern builds.
  let raw: String

  /// Parses a pinned tag (`b9370`) or `llama version` output, which comes in
  /// two formats:
  /// - `b9370-aa50b2c2a` -- builds before b10398
  /// - `version: 0.5.0-dev (build 11200, commit 81bc6b83f)` -- b10398 on, when
  ///   llama.cpp introduced semantic versioning; the build number moved into
  ///   the parenthetical, so the leading token is no longer the version
  /// Returns nil if no build number can be read.
  init?(parsing output: String) {
    // Newer format: take the number after `(build `. Checked first because the
    // leading token (`version:`) would otherwise fail the older-format parse.
    if let range = output.range(of: "(build ") {
      guard let build = Int(output[range.upperBound...].prefix(while: { $0.isNumber })) else {
        return nil
      }
      self.build = build
      let line = output.split(whereSeparator: \.isNewline)
        .first { $0.localizedCaseInsensitiveContains("(build ") }
      self.raw = (line.map(String.init) ?? output).trimmingCharacters(in: .whitespaces)
      return
    }

    // Older format (and pinned tags): an optional leading `b`, the build digits,
    // then optionally `-<sha>`.
    guard let token = output.split(whereSeparator: { $0.isWhitespace }).first else {
      return nil
    }
    var digits = Substring(token)
    if let first = digits.first, first == "b" || first == "B" {
      digits = digits.dropFirst()
    }
    guard let build = Int(digits.prefix(while: { $0.isNumber })) else { return nil }
    self.build = build
    self.raw = String(token)
  }

  /// The clean build tag without the commit sha, e.g. `b9370`. For display.
  var tag: String { "b\(build)" }

  // Identity and ordering are by build number -- the commit sha is ignored, so a
  // pinned tag like `b9444` compares equal to a reported `b9444-<sha>`.
  static func == (lhs: LlamaVersion, rhs: LlamaVersion) -> Bool { lhs.build == rhs.build }
  static func < (lhs: LlamaVersion, rhs: LlamaVersion) -> Bool { lhs.build < rhs.build }

  var description: String { raw }
}
