import Foundation

struct SourcedDeployment: Identifiable {
    let deployment: Deployment
    let account: Account
    var id: String { "\(account.id.uuidString)|\(deployment.uid)" }
}

struct SourcedProject: Identifiable {
    let project: Project
    let account: Account
    var id: String { "\(account.id.uuidString)|\(project.id)" }
    var key: ProjectKey {
        ProjectKey(provider: account.provider, accountId: account.id, projectId: project.id)
    }
}
