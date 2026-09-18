import Foundation

/// Finds and decodes a demo scenario from the app bundle.
///
/// Kept apart from `DemoScenario` so the model stays pure data: the model is
/// exercised by decoding literals in tests, and the bundle lookup is tested on
/// its own.
enum DemoScenarioLoader {
    enum LoadError: Error, Equatable {
        case notFound(String)
    }

    static func load(named name: String, bundle: Bundle = .main) throws -> DemoScenario {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw LoadError.notFound(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DemoScenario.self, from: data)
    }
}
