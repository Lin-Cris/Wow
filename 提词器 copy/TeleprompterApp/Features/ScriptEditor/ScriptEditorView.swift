import SwiftUI

struct ScriptEditorView: View {
    @State private var script: String
    private let draftID: UUID?
    private let onScriptChanged: ((UUID, String) -> Void)?

    init(
        initialScript: String = "",
        draftID: UUID? = nil,
        onScriptChanged: ((UUID, String) -> Void)? = nil
    ) {
        _script = State(initialValue: initialScript)
        self.draftID = draftID
        self.onScriptChanged = onScriptChanged
    }

    private var trimmedScript: String {
        script.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("提词器")
                    .font(.largeTitle.bold())

                Text("输入或粘贴台词，然后打开前置摄像头。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                if script.isEmpty {
                    Text("在这里输入台词…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $script)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("台词输入框")
                    .accessibilityIdentifier("scriptEditor")
                    .onChange(of: script) { _, value in
                        guard let draftID, let onScriptChanged else { return }
                        onScriptChanged(draftID, value)
                    }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            NavigationLink {
                TeleprompterView(script: trimmedScript)
            } label: {
                Label("打开提词器", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedScript.isEmpty)
            .accessibilityHint("打开前置摄像头并显示台词")
            .accessibilityIdentifier("openTeleprompterButton")
        }
        .padding(20)
        .navigationTitle("")
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        ScriptEditorView()
    }
}
