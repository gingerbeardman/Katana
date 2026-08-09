import Foundation

/// Precomputed inspector inputs so `InspectorView` does not re-walk `AppState.games`
/// on every lazy size-enrichment tick (Instruments: multi-second main-thread thrash).
struct InspectorSnapshot: Equatable {
    enum Content: Equatable {
        case empty
        case single(game: GameEntry, duplicate: DuplicateInfo?, markedNotDuplicate: Bool)
        /// Full multi-selection list (for actions); previews are the first entries for display.
        case multi(games: [GameEntry], totalBytes: Int64, anyDup: Bool, anyMarked: Bool)
    }

    var content: Content = .empty
    var maxNumber: Int = 1
    var menuDisplayName: String = MenuKind.gdMenu.displayName
    var duplicatesEnabled: Bool = false
    var isBusy: Bool = false
    var focusNameFieldToken: Int = 0

    static let empty = InspectorSnapshot()
}
