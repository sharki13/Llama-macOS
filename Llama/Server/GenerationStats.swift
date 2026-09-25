import Foundation
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
  private(set) var serverResidentBytes: UInt64?
  private(set) var residentMemoryUpdatedAt: Date?
  private var pendingPrompt: Phase?
  private var pendingModel: String?
  private var selectedModel: String?

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
    }
    selectedModel = modelId
  }

  func resetHistory() {
    history.removeAll(keepingCapacity: true)
    pendingPrompt = nil
    pendingModel = nil
  }

  func resetForServerRestart() {
    resetHistory()
    selectedModel = nil
    clearServerResidentMemory()
  }

  func updateServerResidentMemory(bytes: UInt64) {
    serverResidentBytes = bytes
    residentMemoryUpdatedAt = Date()
  }

  func clearServerResidentMemory() {
    serverResidentBytes = nil
    residentMemoryUpdatedAt = nil
  }

  func consumeTimingLine(_ line: String) {
    guard let phase = Self.parsePhase(line) else { return }

    if line.localizedCaseInsensitiveContains("prompt eval time") {
      pendingPrompt = phase
      pendingModel = selectedModel ?? LlamaServer.shared.activeModelId
      if let pendingModel { noteModelSelection(pendingModel) }
    } else if line.localizedCaseInsensitiveContains("generation eval time")
                || line.localizedCaseInsensitiveContains("eval time =") {
      guard let prompt = pendingPrompt else { return }
      let snapshot = Snapshot(
        prompt: prompt,
        generation: phase,
        completedAt: Date(),
        model: pendingModel)
      latest = snapshot
      if let model = snapshot.model { noteModelSelection(model) }
      history.append(snapshot)
      if history.count > 100 { history.removeFirst(history.count - 100) }
      pendingPrompt = nil
      pendingModel = nil
    }
  }

  private static func summarize(_ values: [Double]) -> RangeSummary {
    RangeSummary(
      average: values.reduce(0, +) / Double(values.count),
      minimum: values.min() ?? 0,
      maximum: values.max() ?? 0)
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
