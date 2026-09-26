import Foundation
import SwiftUI

/// Builds VS Code's chatLanguageModels.json from the presets the app gives to
/// llama-server. The model ID stays verbatim so requests reach the right preset.
@MainActor
enum CopilotIntegration {
  private struct Configuration: Encodable {
    let name = "llama.cpp"
    let vendor = "customendpoint"
    let apiType = "chat-completions"
    let models: [ModelConfiguration]
    let settings: [String: ModelSettings]
  }

  private struct ModelSettings: Encodable {
    let reasoningEffort = "xhigh"
  }

  private struct ModelConfiguration: Encodable {
    let id: String
    let name: String
    let url: String
    let toolCalling = true
    let vision: Bool
    let contextWindow: Int
    let maxOutputTokens: Int
    let thinking: Bool?
    let supportsReasoningEffort: [String]?
  }

  static func json() throws -> String {
    var endpoint = URLComponents()
    endpoint.scheme = "http"
    endpoint.host = LlamaServer.localHost
    endpoint.port = LlamaServer.port
    endpoint.path = "/v1"
    guard let url = endpoint.url?.absoluteString else { throw URLError(.badURL) }

    let models = ModelManager.shared.effectiveModelSections().compactMap { section -> ModelConfiguration? in
      let parameters = Dictionary(
        section.pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
      guard parameters["model"]?.isEmpty == false,
        let rawContext = parameters["ctx-size"],
        let context = Int(rawContext), context > 0
      else { return nil }

      let id = section.name
      let name: String
      if let colon = id.lastIndex(of: ":") {
        let base = String(id[..<colon])
        let displayBase = base.hasSuffix("-GGUF") ? String(base.dropLast(5)) : base
        name = displayBase + String(id[colon...])
      } else {
        name = id.hasSuffix("-GGUF") ? String(id.dropLast(5)) : id
      }

      let repo = id.split(separator: "/").last.map(String.init) ?? id
      let repoName = repo.split(separator: ":").first.map(String.init) ?? repo
      let isQwen38 = repoName.split(separator: "-").contains { $0.lowercased() == "qwen3.8" }

      return ModelConfiguration(
        id: id,
        name: name,
        url: url,
        vision: parameters["mmproj"]?.isEmpty == false,
        contextWindow: context,
        maxOutputTokens: maxOutputTokens(for: context),
        thinking: isQwen38 ? true : nil,
        supportsReasoningEffort: isQwen38 ? ["none", "low", "medium", "xhigh"] : nil)
    }

    var settings: [String: ModelSettings] = [:]
    for model in models where model.supportsReasoningEffort != nil {
      settings[model.id] = ModelSettings()
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode([Configuration(models: models, settings: settings)])
    // JSONEncoder uses two spaces per indentation level.
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        let spaces = line.prefix(while: { $0 == " " }).count
        return String(repeating: "\t", count: spaces / 2) + String(line.dropFirst(spaces))
      }
      .joined(separator: "\n")
  }

  private static func maxOutputTokens(for context: Int) -> Int {
    switch context {
    case ...4_096: 1_024
    case ...8_192: 2_048
    case ...16_384: 4_096
    case ...65_536: 8_192
    default: 16_384
    }
  }
}

struct IntegrationsSettingsView: View {
  @State private var copied = false
  @State private var copyFailed = false

  var body: some View {
    Form {
      Section {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text("VSCode Copilot")
            Text("Copies the contents of chatLanguageModels.json to the clipboard.")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }

          Spacer()

          HStack(spacing: 8) {
            if copied {
              Text("Copied")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Button("Copy") {
              do {
                Clipboard.copy(try CopilotIntegration.json())
                copied = true
              } catch {
                copyFailed = true
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .alert("Could not copy integration settings", isPresented: $copyFailed) {
      Button("OK") { }
    }
  }
}
