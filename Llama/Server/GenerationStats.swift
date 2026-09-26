import Foundation
import Darwin
import Dispatch
import Observation

/// Most recently completed inference, collected from llama-server's timing log.
@MainActor
@Observable
final class GenerationStats {
  static let shared = GenerationStats()

  struct Phase: Equatable {
    let milliseconds: Double
    let tokens: Int
    let tokensPerSecond: Double
  }

  struct Snapshot: Equatable {
    let prompt: Phase
    let generation: Phase
    let completedAt: Date
    let model: String?
    let slotId: Int?
    let taskId: Int?
  }

  struct DraftAcceptance: Equatable {
    let accepted: Int
    let generated: Int

    var percent: Double { Double(accepted) / Double(generated) * 100 }
  }

  enum MemoryPressureLevel {
    case normal
    case warning
    case critical

    var title: String {
      switch self {
      case .normal: "Normal"
      case .warning: "Warning"
      case .critical: "Critical"
      }
    }
  }

  struct RangeSummary {
    let average: Double
    let minimum: Double
    let maximum: Double
  }

  struct Summary {
    let count: Int
    let prompt: RangeSummary
    let generation: RangeSummary
  }

  private(set) var latest: Snapshot?
  private(set) var history: [Snapshot] = []
  private(set) var latestContextTokens: Int?
  private(set) var latestContextWindowTokens: Int?
  private(set) var latestDraftAcceptance: DraftAcceptance?
  private(set) var serverResidentBytes: UInt64?
  private(set) var peakServerResidentBytes: UInt64?
  private(set) var residentMemoryUpdatedAt: Date?
  private(set) var systemMemoryPressureLevel: MemoryPressureLevel?
  private(set) var isMemoryMonitoringEnabled = false
  @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
  private var pendingPrompt: Phase?
  private var pendingModel: String?
  private var pendingSlotId: Int?
  private var pendingTaskId: Int?
  private var selectedModel: String?
  private var latestContextMayUpdate = false

  var summary: Summary? {
    guard !history.isEmpty else { return nil }
    return Summary(
      count: history.count,
      prompt: Self.summarize(history.map(\.prompt.tokensPerSecond)),
      generation: Self.summarize(history.map(\.generation.tokensPerSecond)))
  }

  func noteModelSelection(_ modelId: String) {
    if let selectedModel, selectedModel != modelId {
      resetHistory()
      peakServerResidentBytes = nil
    }
    selectedModel = modelId
  }

  func resetHistory() {
    history.removeAll(keepingCapacity: true)
    pendingPrompt = nil
    pendingModel = nil
    pendingSlotId = nil
    pendingTaskId = nil
    latestContextTokens = nil
    latestContextWindowTokens = nil
    latestDraftAcceptance = nil
    latestContextMayUpdate = false
  }

  func resetForServerRestart() {
    resetHistory()
    selectedModel = nil
    clearServerResidentMemory()
  }

  func updateContext(usedTokens: Int?, windowTokens: Int?) {
    latestContextTokens = usedTokens
    latestContextWindowTokens = windowTokens
  }

  func updateContext(
    usedTokens: Int?, windowTokens: Int?, for snapshot: Snapshot
  ) {
    guard latest == snapshot, latestContextMayUpdate else { return }
    updateContext(usedTokens: usedTokens, windowTokens: windowTokens)
  }

  func updateServerResidentMemory(bytes: UInt64) {
    serverResidentBytes = bytes
    peakServerResidentBytes = max(peakServerResidentBytes ?? 0, bytes)
    residentMemoryUpdatedAt = Date()
  }

  func resetPeakServerResidentMemory() {
    peakServerResidentBytes = serverResidentBytes
  }

  func setMemoryMonitoringEnabled(_ enabled: Bool) {
    isMemoryMonitoringEnabled = enabled
  }

  func startSystemMemoryPressureMonitoring() {
    guard memoryPressureSource == nil else { return }

    // Dispatch reports changes only. Read the current kernel level after
    // subscribing, so a transition during setup is still delivered.
    let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
    memoryPressureSource = source
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let event = self.memoryPressureSource?.data else { return }
        if event.contains(.critical) {
          self.systemMemoryPressureLevel = .critical
        } else if event.contains(.warning) {
          self.systemMemoryPressureLevel = .warning
        } else if event.contains(.normal) {
          self.systemMemoryPressureLevel = .normal
        }
      }
    }
    source.activate()
    systemMemoryPressureLevel = Self.readSystemMemoryPressureLevel()
  }

  private static func readSystemMemoryPressureLevel() -> MemoryPressureLevel? {
    // XNU exposes the same 1/2/4 flags as Dispatch. This sysctl is not part of
    // the public SDK, so an unavailable or unfamiliar value stays unknown.
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
      size == MemoryLayout<Int32>.size, level >= 0
    else { return nil }
    switch UInt(level) {
    case DispatchSource.MemoryPressureEvent.normal.rawValue: return .normal
    case DispatchSource.MemoryPressureEvent.warning.rawValue: return .warning
    case DispatchSource.MemoryPressureEvent.critical.rawValue: return .critical
    default: return nil
    }
  }

  func clearServerResidentMemory() {
    serverResidentBytes = nil
    peakServerResidentBytes = nil
    residentMemoryUpdatedAt = nil
  }

  /// Consumes one server log line, recording a `Snapshot` once both timing
  /// phases of a generation have been seen. Returns true when a snapshot was
  /// recorded, so the caller can refresh context data from the server.
  @discardableResult
  func consumeTimingLine(_ line: String) -> Bool {
    let identity = Self.parseTimingIdentity(line)
    if let draft = Self.parseDraftAcceptance(line) {
      if let identity, latest?.slotId == identity.slotId,
        latest?.taskId == identity.taskId {
        latestDraftAcceptance = draft
      }
      return false
    }
    if let identity {
      pendingSlotId = identity.slotId
      pendingTaskId = identity.taskId
    }
    guard let phase = Self.parsePhase(line) else { return false }

    if line.localizedCaseInsensitiveContains("prompt eval time") {
      pendingPrompt = phase
      pendingModel = selectedModel ?? LlamaServer.shared.activeModelId
      if let pendingModel { noteModelSelection(pendingModel) }
    } else if line.localizedCaseInsensitiveContains("generation eval time")
                || line.localizedCaseInsensitiveContains("eval time =") {
      guard let prompt = pendingPrompt else { return false }
      let snapshot = Snapshot(
        prompt: prompt,
        generation: phase,
        completedAt: Date(),
        model: pendingModel,
        slotId: pendingSlotId,
        taskId: pendingTaskId)
      latest = snapshot
      latestContextTokens = nil
      latestContextWindowTokens = nil
      latestDraftAcceptance = nil
      latestContextMayUpdate = true
      if let model = snapshot.model { noteModelSelection(model) }
      history.append(snapshot)
      if history.count > 100 { history.removeFirst(history.count - 100) }
      pendingPrompt = nil
      pendingModel = nil
      pendingSlotId = nil
      pendingTaskId = nil
      return true
    }
    return false
  }

  private static func summarize(_ values: [Double]) -> RangeSummary {
    RangeSummary(
      average: values.reduce(0, +) / Double(values.count),
      minimum: values.min() ?? 0,
      maximum: values.max() ?? 0)
  }

  private static func parseTimingIdentity(_ line: String) -> (slotId: Int, taskId: Int)? {
    guard line.contains("print_timing"),
      let regex = try? NSRegularExpression(
        pattern: #"print_timing\w*:\s*id\s+(\d+)\s*\|\s*task\s+(\d+)"#),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let slotRange = Range(match.range(at: 1), in: line),
      let taskRange = Range(match.range(at: 2), in: line),
      let slotId = Int(line[slotRange]),
      let taskId = Int(line[taskRange])
    else { return nil }
    return (slotId, taskId)
  }

  private static func parseDraftAcceptance(_ line: String) -> DraftAcceptance? {
    guard line.contains("draft acceptance"),
      let regex = try? NSRegularExpression(
        pattern: #"draft acceptance\s*=\s*[0-9]+(?:\.[0-9]+)?\s*\(\s*(\d+)\s+accepted\s*/\s*(\d+)\s+generated\s*\)"#),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let acceptedRange = Range(match.range(at: 1), in: line),
      let generatedRange = Range(match.range(at: 2), in: line),
      let accepted = Int(line[acceptedRange]),
      let generated = Int(line[generatedRange]),
      generated > 0, accepted <= generated
    else { return nil }
    return DraftAcceptance(accepted: accepted, generated: generated)
  }

  private static func parsePhase(_ line: String) -> Phase? {
    // llama.cpp reports: <phase> = 123.4 ms / 56 tokens (..., 12.3 tokens per second)
    let pattern = #"=\s*([0-9]+(?:\.[0-9]+)?)\s*ms\s*/\s*([0-9]+)\s*(?:tokens|runs).*?([0-9]+(?:\.[0-9]+)?)\s*tokens per second"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let msRange = Range(match.range(at: 1), in: line),
      let tokenRange = Range(match.range(at: 2), in: line),
      let speedRange = Range(match.range(at: 3), in: line),
      let milliseconds = Double(line[msRange]),
      let tokens = Int(line[tokenRange]),
      let speed = Double(line[speedRange])
    else { return nil }
    return Phase(milliseconds: milliseconds, tokens: tokens, tokensPerSecond: speed)
  }
}
