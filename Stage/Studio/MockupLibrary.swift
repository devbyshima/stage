import Foundation

/// An iPhone model that comes with Stage, in one finish.
struct MockupDevice: Identifiable, Hashable, Sendable {
    /// The file's name, "iPhone 18 Pro - Black".
    let id: String
    let family: String
    let finish: String
    let url: URL

    /// The finish's colour, for its dot in the picker.
    var swatch: RGBA { MockupLibrary.swatches[finish] ?? RGBA(0.5, 0.5, 0.5) }
}

/// The 3D iPhones in Stage's resources, each named "<family> - <finish>.usdz".
enum MockupLibrary {
    static let devices: [MockupDevice] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "usdz", subdirectory: nil) ?? []
        return urls.compactMap { url -> MockupDevice? in
            let name = url.deletingPathExtension().lastPathComponent
            let pieces = name.components(separatedBy: " - ")
            guard pieces.count == 2 else { return nil }
            return MockupDevice(id: name, family: pieces[0], finish: pieces[1], url: url)
        }
        .sorted { (rank($0.family, in: familyOrder), rank($0.finish, in: finishOrder), $0.id)
            < (rank($1.family, in: familyOrder), rank($1.finish, in: finishOrder), $1.id) }
    }()

    /// The first model a mockup starts with.
    static var standard: MockupDevice? { device("iPhone 18 Pro - Black") ?? devices.first }

    static var families: [String] {
        devices.reduce(into: []) { families, device in
            if !families.contains(device.family) { families.append(device.family) }
        }
    }

    static func finishes(of family: String) -> [MockupDevice] {
        devices.filter { $0.family == family }
    }

    static func device(_ id: String) -> MockupDevice? {
        devices.first { $0.id == id }
    }

    /// Each finish's colour, from its model's back glass.
    static let swatches: [String: RGBA] = [
        "Black": RGBA(0.19, 0.19, 0.20),
        "Silver": RGBA(0.86, 0.86, 0.84),
        "Glacier": RGBA(0.64, 0.70, 0.76),
        "Burgundy": RGBA(0.36, 0.16, 0.20),
        "Night Sky": RGBA(0.17, 0.20, 0.26),
        "Star White": RGBA(0.93, 0.92, 0.90),
    ]

    private static let familyOrder = ["iPhone 18 Pro", "iPhone 18 Pro Max", "iPhone Duo Fold"]
    private static let finishOrder = ["Black", "Silver", "Glacier", "Burgundy", "Night Sky", "Star White"]

    private static func rank(_ value: String, in order: [String]) -> Int {
        order.firstIndex(of: value) ?? order.count
    }
}
