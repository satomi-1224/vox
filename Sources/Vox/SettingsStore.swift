import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    let hotkey: Hotkey
    let inputMode: InputMode
    let language: RecognitionLanguage
    let modelID: String
    let dictionary: [WorkerDictionaryEntry]
    let configurationSourceLabel: String
    let isNixManaged: Bool

    init(configuration injectedConfiguration: VoxConfiguration? = nil) {
        let loaded: LoadedConfiguration?
        if let injectedConfiguration {
            loaded = LoadedConfiguration(
                configuration: injectedConfiguration,
                sourceLabel: "注入された構成",
                isNixManaged: true
            )
        } else {
            loaded = Self.loadConfiguration()
        }

        let configuration = loaded?.configuration ?? .fallback
        let normalizedFlags = Hotkey.normalizedModifiers(configuration.hotkey.eventFlags)
        hotkey = Hotkey.isUsable(modifiers: normalizedFlags)
            ? Hotkey(keyCode: configuration.hotkey.keyCode, modifiers: normalizedFlags.rawValue)
            : .default
        inputMode = configuration.inputMode
        language = configuration.language

        let configuredModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        modelID = configuredModel.isEmpty ? VoxConfiguration.fallback.model : configuredModel
        dictionary = Self.cleanDictionary(configuration.dictionary)
        configurationSourceLabel = loaded?.sourceLabel ?? "内蔵デフォルト"
        isNixManaged = loaded?.isNixManaged ?? false
    }

    var workerDictionary: [WorkerDictionaryEntry] { dictionary }

    private static func loadConfiguration() -> LoadedConfiguration? {
        var candidates: [(url: URL, label: String, isNixManaged: Bool)] = []
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["VOX_CONFIG_PATH"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            candidates.append((url, url.lastPathComponent, true))
        }
        if let bundled = Bundle.main.url(forResource: "vox-config", withExtension: "json") {
            candidates.append((bundled, "config.nix", true))
        }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.url.path) {
            do {
                let data = try Data(contentsOf: candidate.url)
                let configuration = try JSONDecoder().decode(VoxConfiguration.self, from: data)
                return LoadedConfiguration(
                    configuration: configuration,
                    sourceLabel: candidate.label,
                    isNixManaged: candidate.isNixManaged
                )
            } catch {
                NSLog("Vox configuration (%@): %@", candidate.url.path, error.localizedDescription)
            }
        }
        return nil
    }

    private static func cleanDictionary(_ entries: [WorkerDictionaryEntry]) -> [WorkerDictionaryEntry] {
        var seenSources = Set<String>()
        return entries.compactMap { entry in
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = source.lowercased()
            guard !source.isEmpty,
                  !replacement.isEmpty,
                  seenSources.insert(key).inserted
            else { return nil }
            return WorkerDictionaryEntry(source: source, replacement: replacement)
        }
        .prefix(200)
        .map { $0 }
    }

    private struct LoadedConfiguration {
        let configuration: VoxConfiguration
        let sourceLabel: String
        let isNixManaged: Bool
    }
}
