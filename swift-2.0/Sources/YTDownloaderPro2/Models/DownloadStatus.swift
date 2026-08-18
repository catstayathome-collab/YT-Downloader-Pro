import Foundation

enum DownloadStatus: String, CaseIterable, Codable, Sendable {
    case queued
    case analyzing
    case downloading
    case paused
    case merging
    case completed
    case failed
    case cancelled

    enum SidebarSection: String, CaseIterable, Codable, Sendable {
        case all
        case running
        case stopped
        case completed
        case failed
    }

    var canPause: Bool {
        switch self {
        case .analyzing, .downloading:
            true
        case .queued, .paused, .merging, .completed, .failed, .cancelled:
            false
        }
    }

    var sidebarSection: SidebarSection {
        switch self {
        case .queued, .analyzing, .downloading, .merging:
            .running
        case .paused, .cancelled:
            .stopped
        case .completed:
            .completed
        case .failed:
            .failed
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .analyzing, .downloading, .paused, .merging:
            false
        }
    }

    var isActive: Bool {
        switch self {
        case .analyzing, .downloading, .merging:
            true
        case .queued, .paused, .completed, .failed, .cancelled:
            false
        }
    }
}
