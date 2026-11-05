import AppIntents
import SwiftUI
import SearchCore

/// The demo's device list. Edits go through the store, so they reach the search index: a status change is
/// searchable at once, and a rename or move after the coalesced rebuild (well under a second).
struct DevicesView: View {
    let store: DemoDeviceStore
    let services: AppSearchServices
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.rooms, id: \.name) { room in
                    Section(room.name) {
                        ForEach(room.devices) { device in
                            NavigationLink {
                                DeviceEditView(device: device, store: store, services: services)
                            } label: {
                                DeviceRow(device: device, typeLabel: typeLabel(device))
                            }
                            // Tells Siri and Apple Intelligence which device each row shows ("turn this off").
                            .appEntityIdentifier(EntityIdentifier(for: DeviceEntity.self, identifier: device.id))
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.remove(device.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(store.devices.count) devices")
            .toolbar {
                Button("Add", systemImage: "plus") { isAdding = true }
            }
            .sheet(isPresented: $isAdding) {
                AddDeviceView(store: store, services: services)
            }
        }
    }

    private func typeLabel(_ device: DemoDevice) -> String {
        services.knowledge.typeCard(for: DeviceTypeID(device.type)).label
    }
}

struct DeviceRow: View {
    let device: DemoDevice
    let typeLabel: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.name)
                    if device.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                }
                Text("\(typeLabel) · \(device.manufacturer)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.online == false {
                Text("Offline").font(.caption).foregroundStyle(.red)
            } else if let on = device.poweredOn {
                Text(on ? "On" : "Off").font(.caption).foregroundStyle(on ? .green : .secondary)
            }
        }
    }
}

/// Rename, move, and change status. The name and room are applied on Save, like a real rename.
struct DeviceEditView: View {
    let device: DemoDevice
    let store: DemoDeviceStore
    let services: AppSearchServices
    @State private var name: String
    @State private var room: String
    @Environment(\.dismiss) private var dismiss

    init(device: DemoDevice, store: DemoDeviceStore, services: AppSearchServices) {
        self.device = device
        self.store = store
        self.services = services
        _name = State(initialValue: device.name)
        _room = State(initialValue: device.room ?? "")
    }

    private var current: DemoDevice { store.devices.first { $0.id == device.id } ?? device }

    var body: some View {
        Form {
            Section("Name and room") {
                TextField("Name", text: $name)
                TextField("Room", text: $room)
                Button("Save") {
                    store.update(device.id) {
                        $0.name = name.trimmingCharacters(in: .whitespaces)
                        $0.room = room.isEmpty ? nil : room
                    }
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("Status") {
                Toggle("Online", isOn: Binding(get: { current.online ?? true },
                                               set: { value in store.update(device.id) { $0.online = value } }))
                Toggle("Powered on", isOn: Binding(get: { current.poweredOn ?? false },
                                                   set: { value in store.update(device.id) { $0.poweredOn = value } }))
                Toggle("Favorite", isOn: Binding(get: { current.favorite },
                                                 set: { value in store.update(device.id) { $0.favorite = value } }))
            }
            Section("Search data") {
                LabeledContent("Type", value: services.knowledge.typeCard(for: DeviceTypeID(device.type)).label)
                LabeledContent("Manufacturer", value: device.manufacturer)
                LabeledContent("Uses", value: "\(current.uses)")
                LabeledContent("ID", value: device.id)
            }
        }
        .navigationTitle(current.name)
    }
}

struct AddDeviceView: View {
    let store: DemoDeviceStore
    let services: AppSearchServices
    @State private var name = ""
    @State private var room = "Living Room"
    @State private var type = "light"
    @Environment(\.dismiss) private var dismiss

    private static let types = ["ac", "light", "tv", "fan", "camera", "lock", "plug", "speaker", "sensor",
                                "thermostat", "vacuum", "blind", "doorbell", "garage"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Room", text: $room)
                Picker("Type", selection: $type) {
                    ForEach(Self.types, id: \.self) { id in
                        Text(services.knowledge.typeCard(for: DeviceTypeID(id)).label).tag(id)
                    }
                }
            }
            .navigationTitle("Add device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.addDevice(name: name.trimmingCharacters(in: .whitespaces), type: type, room: room)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// What opens when a search result (or Spotlight, or Siri) opens a device. Controlling it records usage,
/// which feeds the usual-pick ranking.
struct DeviceDetailView: View {
    let deviceID: DeviceID
    let store: DemoDeviceStore
    let services: AppSearchServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let device = store.device(deviceID) {
                    Form {
                        Section {
                            LabeledContent("Type", value: services.knowledge.typeCard(for: DeviceTypeID(device.type)).label)
                            LabeledContent("Room", value: device.room ?? "—")
                            LabeledContent("Manufacturer", value: device.manufacturer)
                            LabeledContent("Status", value: device.online == false ? "Offline" : "Online")
                        }
                        if device.poweredOn != nil {
                            Section {
                                Toggle("Power", isOn: Binding(get: { store.device(deviceID)?.poweredOn ?? false }, set: { value in
                                    store.update(device.id) { $0.poweredOn = value; $0.uses += 1; $0.lastUsed = .now }
                                    Task { await services.recordUsage(of: deviceID) }
                                    if let entity { DeviceIntentDonation.power(value, device: entity) }
                                }))
                            }
                        }
                        Section {
                            Text("Opening a device from search counts as a pick. Pick the same device a few times for the same words and it moves to the top; a word it doesn't have becomes a learned nickname (see Settings).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle(device.name)
                } else {
                    ContentUnavailableView("Device not found", systemImage: "questionmark.circle")
                }
            }
            .toolbar { Button("Done") { dismiss() } }
        }
        .deviceActivity(entity)
        .presentationDetents([.medium, .large])
    }

    private var entity: DeviceEntity? {
        store.device(deviceID).map { DeviceEntity(record: DeviceRecord($0), knowledge: services.knowledge) }
    }
}
