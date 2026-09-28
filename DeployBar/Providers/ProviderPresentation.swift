import Foundation

/// How a provider's rows talk about a run: a deploy is "deployed", a CI run "passed".
enum RunVocabulary: Sendable, Equatable {
    case deployments
    case ciRuns
}

/// One entry in a project row's ⋯ menu.
struct ProjectLink: Sendable {
    let title: LocalizedStringResource
    let systemImage: String
    let url: URL
}

/// What views need to know about a provider, as data rather than views.
struct ProviderPresentation: Sendable {
    let vocabulary: RunVocabulary
    let tokenCreationURL: URL
    let tokenHint: LocalizedStringResource
    let projectMenuLinks: @Sendable (_ project: Project, _ scopeName: String) -> [ProjectLink]
    /// The owner shown before a project name in the account's own scope.
    let ownerLabel: @Sendable (_ identity: AccountIdentity?) -> String?
}
