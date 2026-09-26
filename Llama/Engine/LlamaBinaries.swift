import Foundation
import Darwin
import os.log

/// Resolves the `llama` executable the app drives, and classifies whether the
/// app may update it.
///
/// The app follows a shared-path model:
/// - it manages the curl-install path (`~/.llama-app/llama`, what `install.sh`
///   produces): it may install a binary there and keep it updated
/// - any other install (e.g. Homebrew) is left unmanaged: the app uses it
///   but never modifies it
///
/// Supports both the unified `llama` executable and legacy standalone
/// `llama-server` binaries.
enum LlamaBinaries {

  private static let logger = Logger(subsystem: Logging.subsystem, category: "LlamaBinaries")

  /// The curl-install path the app manages (matches `install.sh`'s layout).
  /// The real binary lives in `~/.llama-app`; `install.sh` also drops a
  /// `~/.local/bin/llama` symlink onto PATH, but the app points at the real file.
  static let managedPath: String =
    (NSHomeDirectory() as NSString).appendingPathComponent(".llama-app/llama")

  /// Unsloth's local llama.cpp build directory.
  static let unslothBinDir: String =
    (NSHomeDirectory() as NSString).appendingPathComponent(".unsloth/llama.cpp/build/bin")

  /// `install.sh` may expose the managed binary through this PATH symlink.
  static let localBinPath: String =
    (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/llama")

  /// Unmanaged locations to probe when the app hasn't installed its own binary.
  /// Covers the Homebrew bin dirs (Apple Silicon and Intel).
  private static let unmanagedDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

  /// The build the app installs and keeps its own binary at -- the pinned
  /// target, not whatever is newest. Bump per app release after smoke-testing
  /// `serve` + `fit-params`; the app's auto-updater then rolls it out.
  static let targetVersion = LlamaVersion(parsing: "b10679")!

  /// The minimum build the app accepts from an unmanaged install (e.g. Homebrew)
  /// before nudging the user to update -- the app can't update those itself.
  /// Must be <= targetVersion. Set to the build that introduced the `--agent`
  /// serve flag (llama.cpp PR #24801), the newest flag the app passes -- on
  /// older builds an unknown flag fails the launch outright, so accepting
  /// them would break server start whenever agent mode is on. Only raise this
  /// if the app starts relying on an even newer flag.
  static let floorVersion = LlamaVersion(parsing: "b9726")!

  /// Where the in-use binary comes from. Only `managed` is the app's to
  /// update; `brew` and `external` are both used as-is and never modified.
  /// Brew is split out so the footer can hint at the actual update channel
  /// (`brew upgrade`) instead of a generic "external" marker.
  enum Origin: Equatable { case managed, unsloth, local, brew, external, custom }

  struct Installation: Identifiable, Equatable {
    let path: String
    let origin: Origin
    var id: String { path }
    var isAvailable: Bool {
      var isDirectory = ObjCBool(false)
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
    }
  }

  /// Whether the binary at `path` is a Homebrew install. Follows symlinks and
  /// checks for Homebrew's Cellar layout (`bin/llama` is a symlink into
  /// `../Cellar/llama.cpp/...`) rather than the bin dir alone -- /usr/local/bin
  /// also hosts manual installs.
  private static func isHomebrew(at path: String) -> Bool {
    (path as NSString).resolvingSymlinksInPath.contains("/Cellar/")
  }

  /// Resolves the preferred executable when available, or the first detected
  /// installation in automatic priority order. Nil when none is found.
  static func resolve() -> (path: String, origin: Origin)? {
    let installations = availableInstallations()
    if let preferredPath = UserSettings.llamaBinaryPath,
      let preferred = installations.first(where: { $0.path == preferredPath && $0.isAvailable })
    {
      return (preferred.path, preferred.origin)
    }
    guard let first = installations.first(where: \.isAvailable) else { return nil }
    return (first.path, first.origin)
  }

  /// Detected installations in automatic-selection priority order.
  static func availableInstallations() -> [Installation] {
    let fm = FileManager.default
    var installations: [Installation] = []

    if fm.isExecutableFile(atPath: managedPath) {
      installations.append(Installation(path: managedPath, origin: .managed))
    }

    // Prefer the unified executable when both are present: it supports server
    // mode and the `fit-params` command used for memory profiling.
    for name in ["llama", "llama-server"] {
      let path = (unslothBinDir as NSString).appendingPathComponent(name)
      if fm.isExecutableFile(atPath: path) {
        installations.append(Installation(path: path, origin: .unsloth))
      }
    }

    if fm.isExecutableFile(atPath: localBinPath) {
      // If this is install.sh's standard symlink to our managed executable,
      // the canonical managed entry above is enough and avoids duplicate UI.
      let resolvedLocalPath = (localBinPath as NSString).resolvingSymlinksInPath
      let resolvedManagedPath = (managedPath as NSString).resolvingSymlinksInPath
      if resolvedLocalPath != resolvedManagedPath {
        installations.append(Installation(path: localBinPath, origin: .local))
      }
    }

    #if DEBUG
      // Dev affordance: pretend unmanaged installs (e.g. Homebrew) aren't present,
      // so the missing -> install path can be exercised on a machine that already
      // has llama.cpp. Toggle with:
      //   defaults write app.llama.Llama.dev ignoreUnmanagedLlama -bool YES
      if UserDefaults.standard.bool(forKey: "ignoreUnmanagedLlama") {
        logger.debug("ignoreUnmanagedLlama set; ignoring unmanaged installs")
        return includingCustom(installations)
      }
    #endif

    for dir in unmanagedDirs {
      let path = dir + "/llama"
      if fm.isExecutableFile(atPath: path) {
        installations.append(
          Installation(path: path, origin: isHomebrew(at: path) ? .brew : .external))
      }
    }

    return includingCustom(installations)
  }

  private static func includingCustom(_ found: [Installation]) -> [Installation] {
    var result = found
    for path in UserSettings.customLlamaBinaryPaths where !result.contains(where: { $0.path == path }) {
      result.append(Installation(path: path, origin: .custom))
    }
    return result
  }

  /// The path to the `llama` binary to invoke, or `nil` if none is installed.
  static var llamaPath: String? {
    guard let path = resolve()?.path else {
      logger.error("No llama binary found")
      return nil
    }
    logger.debug("Using llama binary at \(path, privacy: .public)")
    return path
  }

  /// Reads the version reported by the binary at `path`, or nil if it can't be
  /// run or its output can't be parsed. Runs `<path> version`, which just prints
  /// the build and exits -- no model load. Blocks on the subprocess, so call off
  /// the main thread.
  static func readVersion(at path: String) -> LlamaVersion? {
    guard let output = readVersionOutput(at: path) else { return nil }
    return LlamaVersion(parsing: output)
  }

  /// Returns the version line printed by the binary for display in Settings.
  /// This preserves the binary's own version format, which may differ from the
  /// `bNNNN` format used by the install manager for release comparisons.
  static func readVersionDescription(at path: String) -> String? {
    guard let output = readVersionOutput(at: path) else { return nil }
    let lines = output.split(whereSeparator: \.isNewline)
    let versionLine = lines.first { $0.localizedCaseInsensitiveContains("version:") }
    guard let line = (versionLine ?? lines.first)?.trimmingCharacters(in: .whitespaces) else {
      return nil
    }
    guard line.lowercased().hasPrefix("version:") else { return line }
    return line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
  }

  private static func readVersionOutput(at path: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = URL(fileURLWithPath: path).lastPathComponent == "llama-server"
      ? ["--version"] : ["version"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = out  // capture startup chatter too; version may follow it
    let finished = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in finished.signal() }

    do {
      try proc.run()
    } catch {
      logger.error(
        "Couldn't run \(path, privacy: .public) version: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
    // A manually selected executable can be broken or hang in its version
    // command. Never leave the Backend pane waiting indefinitely for it.
    if finished.wait(timeout: .now() + 5) == .timedOut {
      if proc.isRunning { kill(proc.processIdentifier, SIGTERM) }
      if finished.wait(timeout: .now() + 1) == .timedOut && proc.isRunning {
        kill(proc.processIdentifier, SIGKILL)
      }
      proc.waitUntilExit()
      return nil
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
