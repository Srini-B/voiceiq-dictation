import Foundation

/// Where a dictation is going: the target app and its focused window title.
/// Text context for the writing model, in place of a screenshot.
public struct DictationPlace: Equatable, Sendable {
    public var appName: String?
    public var windowTitle: String?
    /// Host and path of the page when the app is a browser.
    public var pageURL: String?

    public init(appName: String?, windowTitle: String?, pageURL: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.pageURL = pageURL
    }
}
