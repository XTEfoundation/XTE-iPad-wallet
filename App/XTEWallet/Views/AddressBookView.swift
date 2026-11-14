// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Address book, stored in the app's private Keychain group (not readable by extensions)
// and opened only after Face ID / Touch ID / passcode.

import Security
import SwiftUI
import XTEWalletCore

struct AddressBookEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var paymentID: String?

    var uri: String { PaymentURI(address: address, name: name, paymentID: paymentID).uriString() }
}

@MainActor
final class AddressBook: ObservableObject {
    static let shared = AddressBook()
    @Published private(set) var entries: [AddressBookEntry] = []
    @Published private(set) var unlocked = false

    private let service = (Bundle.main.bundleIdentifier ?? "io.traaitt.wallet") + ".addressbook"
    private let account = "entries"

    func unlock() async throws {
        if unlocked { return }
        try await KeychainStore.authenticate(reason: "Open your address book")
        entries = load()
        unlocked = true
    }

    func lock() {
        entries = []
        unlocked = false
    }

    func upsert(_ e: AddressBookEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func load() -> [AddressBookEntry] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([AddressBookEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

struct AddressBookView: View {
    @ObservedObject private var book = AddressBook.shared
    /// When set, tapping an entry picks it (used from Send).
    var onPick: ((AddressBookEntry) -> Void)?
    @State private var editing: AddressBookEntry?
    @State private var error: String?

    var body: some View {
        Group {
            if book.unlocked {
                List {
                    ForEach(book.entries) { e in
                        Button {
                            if let onPick { onPick(e) } else { editing = e }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(e.name).font(.headline)
                                Text(e.address).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button { editing = e } label: { Label("Edit", systemImage: "pencil") }
                            ShareLink(item: e.uri) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { AppRouter.shared.open(.send(amount: nil, address: e.uri)) } label: {
                                Label("Send", systemImage: "arrow.up.circle")
                            }
                        }
                    }
                    .onDelete { book.delete(at: $0) }
                }
                .overlay { if book.entries.isEmpty { Text("No contacts yet").foregroundStyle(.secondary) } }
                .toolbar {
                    Button { editing = AddressBookEntry(name: "", address: "") } label: { Label("Add", systemImage: "plus") }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.largeTitle)
                    Text("The address book is protected with Face ID")
                    Button("Unlock") { Task { await unlock() } }.buttonStyle(.borderedProminent)
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
        }
        .navigationTitle("Address book")
        .task { await unlock() }
        .sheet(item: $editing) { e in
            NavigationStack { EditContactView(entry: e) { book.upsert($0); editing = nil } }
        }
    }

    private func unlock() async {
        do { try await book.unlock(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct EditContactView: View {
    @State var entry: AddressBookEntry
    let onSave: (AddressBookEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !entry.name.trimmingCharacters(in: .whitespaces).isEmpty && XTEAddress.isValid(entry.address.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Form {
            TextField("Name", text: $entry.name)
            TextField("\(XTEConfig.ticker) address", text: $entry.address, axis: .vertical)
                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Payment ID (optional)", text: Binding(get: { entry.paymentID ?? "" }, set: { entry.paymentID = $0.isEmpty ? nil : $0 }))
                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !entry.address.isEmpty && !XTEAddress.isValid(entry.address.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Text("Not a valid \(XTEConfig.ticker) address").foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle(entry.name.isEmpty ? "New contact" : entry.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    entry.address = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(entry)
                }.disabled(!valid)
            }
        }
    }
}
