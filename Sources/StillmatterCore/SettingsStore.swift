import Foundation

public final class SettingsStore {
    public static let defaultStorageKey = "works.stillmatter.settings.v1"

    public var settings: AppSettings {
        didSet {
            persist()
            notifyObservers()
        }
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private var observers: [(AppSettings) -> Void] = []

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = SettingsStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.settings = SettingsStore.load(from: userDefaults, storageKey: storageKey)
    }

    public func observe(_ observer: @escaping (AppSettings) -> Void) {
        observers.append(observer)
        observer(settings)
    }

    public func reset() {
        settings = AppSettings()
    }

    private func notifyObservers() {
        observers.forEach { $0(settings) }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            assertionFailure("Failed to persist Stillmatter settings: \(error)")
        }
    }

    private static func load(from userDefaults: UserDefaults, storageKey: String) -> AppSettings {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return AppSettings()
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return AppSettings()
        }
    }
}
