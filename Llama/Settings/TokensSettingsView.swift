import AppKit
import SwiftUI

struct TokensSettingsView: View {
  @State private var allowAnonymous = UserSettings.allowUnauthenticatedAPI
  @State private var tokens: [APITokenStore.Token] = []
  @State private var showingCreate = false
  @State private var newAlias = ""
  @State private var newToken: String?
  @State private var renaming: APITokenStore.Token?
  @State private var editedAlias = ""
  @State private var deleting: APITokenStore.Token?
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Allow API requests without a token")
            Text("Turn this off to require a token for model and chat API requests.")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("", isOn: Binding(
            get: { allowAnonymous },
            set: { enabled in
              UserSettings.allowUnauthenticatedAPI = enabled
              allowAnonymous = enabled
            }
          ))
          .labelsHidden()
          .disabled(allowAnonymous && (tokens.isEmpty || UserSettings.extraArgsContainAPIKey))
        }

        if UserSettings.extraArgsContainAPIKey {
          Text("API key flags are present in extraServerArgs. Remove them before using token enforcement here.")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
        } else if tokens.isEmpty && allowAnonymous {
          Text("Generate a token before requiring one.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      Section {
        ForEach(tokens) { token in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(token.alias)
              Text("Created \(token.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
              editedAlias = token.alias
              renaming = token
            }
            Button(role: .destructive) {
              deleting = token
            } label: {
              Image(systemName: "trash")
            }
            .help("Delete token")
          }
        }
        Button("Generate token") {
          newAlias = ""
          newToken = nil
          showingCreate = true
        }
      } header: {
        Text("Client tokens")
      } footer: {
        Text(allowAnonymous
          ? "Tokens are stored now and become required when anonymous API requests are disabled."
          : "Deleting a token immediately revokes it and restarts the server. The Web UI also asks for a token.")
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
    .sheet(isPresented: $showingCreate, onDismiss: { newToken = nil }) {
      VStack(alignment: .leading, spacing: 14) {
        if let newToken {
          Text("Token created")
            .font(.headline)
          Text("Copy this token now. It will not be shown again.")
            .foregroundStyle(.secondary)
          Text(newToken)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
          HStack {
            Spacer()
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(newToken, forType: .string)
            }
            Button("Done") { showingCreate = false }
              .keyboardShortcut(.defaultAction)
          }
        } else {
          Text("Generate API token")
            .font(.headline)
          TextField("Alias", text: $newAlias)
          Text("Use a name such as the device or client that will use it.")
            .foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button("Cancel") { showingCreate = false }
            Button("Generate") { generate() }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
      .padding(20)
      .frame(width: 420)
    }
    .alert("Rename token", isPresented: Binding(
      get: { renaming != nil }, set: { if !$0 { renaming = nil } }
    )) {
      TextField("Alias", text: $editedAlias)
      Button("Save") { rename() }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .alert("Delete token?", isPresented: Binding(
      get: { deleting != nil }, set: { if !$0 { deleting = nil } }
    )) {
      Button("Delete", role: .destructive) { delete() }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("Clients using this token will lose access when the server restarts.")
    }
    .alert("Tokens error", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func refresh() {
    do { tokens = try APITokenStore.list() }
    catch { errorMessage = error.localizedDescription }
  }

  private func generate() {
    do {
      let alias = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
      newToken = try APITokenStore.create(alias: alias.isEmpty ? "Untitled token" : alias)
      refresh()
      if !allowAnonymous { notifyServer() }
    } catch { errorMessage = error.localizedDescription }
  }

  private func rename() {
    guard let token = renaming else { return }
    renaming = nil
    do {
      let alias = editedAlias.trimmingCharacters(in: .whitespacesAndNewlines)
      try APITokenStore.rename(id: token.id, alias: alias.isEmpty ? "Untitled token" : alias)
      refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  private func delete() {
    guard let token = deleting else { return }
    deleting = nil
    do {
      try APITokenStore.delete(id: token.id)
      refresh()
      if !allowAnonymous { notifyServer() }
    } catch { errorMessage = error.localizedDescription }
  }

  private func notifyServer() {
    NotificationCenter.default.post(name: .LBUserSettingsDidChange, object: nil)
  }
}
