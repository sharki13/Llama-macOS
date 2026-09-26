import Foundation
import SwiftUI

/// Builds VS Code and Copilot CLI configurations from the presets the app gives
/// to llama-server. The model ID stays verbatim so requests reach the right preset.
@MainActor
enum CopilotIntegration {
  struct ModelPreset: Identifiable {
    let id: String
    let name: String
    let vision: Bool
    let contextWindow: Int
    let maxOutputTokens: Int
    let supportsReasoning: Bool
  }

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

    init(preset: ModelPreset, url: String) {
      id = preset.id
      name = preset.name
      self.url = url
      vision = preset.vision
      contextWindow = preset.contextWindow
      maxOutputTokens = preset.maxOutputTokens
      thinking = preset.supportsReasoning ? true : nil
      supportsReasoningEffort = preset.supportsReasoning
        ? ["none", "low", "medium", "xhigh"] : nil
    }
  }

  static func json() throws -> String {
    let url = try endpoint(path: "/v1")
    let models = modelPresets().map { ModelConfiguration(preset: $0, url: url) }

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

  static func modelPresets() -> [ModelPreset] {
    ModelManager.shared.effectiveModelSections().compactMap { section -> ModelPreset? in
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

      return ModelPreset(
        id: id,
        name: name,
        vision: parameters["mmproj"]?.isEmpty == false,
        contextWindow: context,
        maxOutputTokens: maxOutputTokens(for: context),
        supportsReasoning: isQwen38)
    }
  }

  static func cliCommand(for model: ModelPreset) throws -> String {
    let baseURL = try endpoint(path: "")
    return "COPILOT_PROVIDER_BASE_URL=\(shellQuote(baseURL)) "
      + "COPILOT_PROVIDER_MAX_PROMPT_TOKENS=\(model.contextWindow) "
      + "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=\(model.maxOutputTokens) "
      + "COPILOT_MODEL=\(shellQuote(model.id)) copilot"
  }

  private static func endpoint(path: String) throws -> String {
    var components = URLComponents()
    components.scheme = "http"
    components.host = LlamaServer.localHost
    components.port = LlamaServer.port
    components.path = path
    guard let url = components.url?.absoluteString else { throw URLError(.badURL) }
    return url
  }

  private static func shellQuote(_ value: String) -> String {
    guard value.contains(where: { !$0.isLetter && !$0.isNumber && !"-_./:=~".contains($0) })
    else { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
  @State private var copiedCLI = false
  @State private var copyFailed = false
  @State private var models: [CopilotIntegration.ModelPreset] = []
  @State private var selectedModelID = ""

  private var selectedModel: CopilotIntegration.ModelPreset? {
    models.first { $0.id == selectedModelID }
  }

  var body: some View {
    Form {
      Section {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text("GitHub Copilot in VS Code")
            Text("Copies the contents of chatLanguageModels.json to the clipboard. Use 'Open Language Model (JSON)' command in VS Code to load it.")
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

      Section {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text("GitHub Copilot CLI")
            Text("Copies a command for the selected model to the clipboard. Add COPILOT_PROVIDER_API_KEY variable if required.")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }

          Spacer()

          HStack(spacing: 8) {
            if copiedCLI {
              Text("Copied")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Button("Copy") {
              guard let selectedModel else { return }
              do {
                Clipboard.copy(try CopilotIntegration.cliCommand(for: selectedModel))
                copiedCLI = true
              } catch {
                copyFailed = true
              }
            }
            .disabled(selectedModel == nil)
          }
        }

        Picker("Model", selection: $selectedModelID) {
          if models.isEmpty {
            Text("No models available").tag("")
          }
          ForEach(models) { model in
            Text(model.name).tag(model.id)
          }
        }
        .disabled(models.isEmpty)
        .onChange(of: selectedModelID) { _, _ in copiedCLI = false }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refreshModels)
    .onReceive(NotificationCenter.default.publisher(for: .LBModelDownloadedListDidChange)) { _ in
      refreshModels()
    }
    .alert("Could not copy integration settings", isPresented: $copyFailed) {
      Button("OK") { }
    }
  }

  private func refreshModels() {
    models = CopilotIntegration.modelPresets()
    copiedCLI = false
    if !models.contains(where: { $0.id == selectedModelID }) {
      selectedModelID = models.first?.id ?? ""
    }
  }
}
