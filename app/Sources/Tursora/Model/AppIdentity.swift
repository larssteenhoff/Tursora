import Foundation

/// The name people see. Internal identifiers — the bundle id, the executable,
/// preference and Application Support folders, notification and error domains
/// — keep "Tursora", so settings, saved workspaces and privacy permissions
/// survive the rename.
enum AppIdentity {
    static let displayName = "Files"
}
