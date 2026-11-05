#if canImport(SwiftUI)
import SwiftUI

/// Settings → Learned names (design doc §15 U06): every learned nickname, swipe to remove.
public struct NicknameSettingsView: View {
    @Bindable private var model: NicknameSettingsModel

    public init(model: NicknameSettingsModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if model.items.isEmpty {
                Text("When you often pick a device after searching for a name it doesn't have, that name is learned here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.items) { item in
                VStack(alignment: .leading) {
                    Text("“\(item.nickname)”")
                    Text(item.deviceName).font(.footnote).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { Task { await model.remove(item) } }
                }
            }
        }
        .navigationTitle("Learned names")
        .task { await model.load() }
    }
}
#endif
