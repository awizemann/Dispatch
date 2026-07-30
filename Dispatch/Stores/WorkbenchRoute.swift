// WorkbenchRoute.swift
// Cross-tab navigation requests (design §4: bus chips are "clickable →
// Messages"). The requester (today: a project card's attention badge) sets
// AppStores.routeRequest; WorkbenchView switches tabs; the target tab consumes
// the request (reveal + scroll + highlight) and clears it back to nil.

import Foundation

nonisolated enum WorkbenchRouteRequest: Equatable, Sendable {
    /// Focus a bus-message card in the Messages tab.
    case message(projectID: UUID, messageID: String)
}
