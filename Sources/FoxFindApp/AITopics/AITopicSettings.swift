import SwiftUI

struct AITopicSettings: View {
    @ObservedObject var manager: AITopicManager
    private func text(_ key: String, _ value: String? = nil) -> String { value.map { L10n.text(key, $0) } ?? L10n.text(key) }
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(text("topicsEnabled"), isOn: Binding(get: { manager.enabled }, set: manager.setEnabled))
                    .disabled(manager.clearing)
                Text(text("topicsPrivacy")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            providerRow("topicsClaudeProvider", provider: .claude)
            providerRow("topicsCodexProvider", provider: .codex)
            providerRow("topicsWorkBuddyProvider", provider: .workbuddy)
            if manager.indexing {
                Text(text("topicsBuildingShort")).font(.footnote).foregroundStyle(.secondary)
            } else if manager.failed {
                Button(text("action.retry")) { manager.requestRefresh(immediate: true) }
            } else {
                Text(text("topicsDone", String(manager.count)) + " · " + text("topicsSize", ByteCountFormatter.string(fromByteCount: manager.diskBytes, countStyle: .file)))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(L10n.local("支持这台 Mac 上的本地记录。普通网页聊天记录不在搜索范围内。", "Searches records stored on this Mac. Browser-only chat histories are not included."))
                .font(.footnote).foregroundStyle(.secondary)
            Button(L10n.local("关闭并清除本地对话副本", "Turn off and clear local conversation copies")) { manager.clearCache() }
                .disabled(manager.clearing)
        }
    }
    private func providerRow(_ key: String, provider: AITopicProvider) -> some View {
        Toggle(text(key), isOn: Binding(
            get: { manager.isProviderEnabled(provider) },
            set: { manager.setProviderEnabled(provider, enabled: $0) }
        ))
        .disabled(!manager.enabled)
        .padding(.vertical, 5)
    }
}
