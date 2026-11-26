#if os(iOS)
import Foundation

/// iOS cannot capture other apps' screens, so dictation carries no screen text.
/// Same shape as the macOS collector so the coordinator needs no branches.
final class ScreenContextCollector {
    init(vocabulary: [String] = []) {}
    func start() {}
    func stop() -> [String] { [] }
}

/// A keyboard extension is never offered secure text fields, so there is no
/// system-wide secure-input state to respect on iOS.
public enum SecureInput {
    struct Holder { let name: String; let pid: pid_t }
    public static var isActive: Bool { false }
    static func holder() -> Holder? { nil }
    static func advice(forHolder name: String) -> String { "" }
}
#endif
