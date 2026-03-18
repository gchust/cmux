import Combine
import Foundation

@MainActor
protocol WorkspaceLiveSyncing: AnyObject {
    func publisher(teamID: String) -> AnyPublisher<[MobileInboxWorkspaceRow], Never>
}

@MainActor
final class ConvexWorkspaceLiveSync: WorkspaceLiveSyncing {
    func publisher(teamID: String) -> AnyPublisher<[MobileInboxWorkspaceRow], Never> {
        ConvexClientManager.shared.client
            .subscribe(
                to: "mobileInbox:listForUser",
                with: ["teamSlugOrId": teamID],
                yielding: [MobileInboxWorkspaceRow].self
            )
            .catch { _ in
                Just([])
            }
            .eraseToAnyPublisher()
    }
}
