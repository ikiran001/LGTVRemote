import Foundation
import Combine

struct SavedTV: Identifiable, Codable, Equatable {
    var id = UUID()
    var brand: String
    var name: String
    var ip: String
    var mac: String
    var lastSeen: Date

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? brand : name
    }
}

final class SavedTVStore: ObservableObject {
    static let shared = SavedTVStore()

    @Published var items: [SavedTV] = [] {
        didSet { persist() }
    }

    private let key = "LGRemoteMVP.savedTVs"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedTV].self, from: data) {
            self.items = decoded
        }
    }

    func addOrUpdate(_ tv: SavedTV) {
        if let idx = items.firstIndex(where: { $0.ip == tv.ip || $0.mac.caseInsensitiveCompare(tv.mac) == .orderedSame }) {
            items[idx] = tv
        } else {
            items.append(tv)
        }
        sortItems()
    }

    // Avoid SwiftUI’s remove(atOffsets:); do it manually so no extra import needed
    func delete(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) {
            guard items.indices.contains(i) else { continue }
            items.remove(at: i)
        }
    }

    func markSeen(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lastSeen = Date()
        sortItems()
    }

    private func sortItems() {
        items.sort { $0.lastSeen > $1.lastSeen }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

