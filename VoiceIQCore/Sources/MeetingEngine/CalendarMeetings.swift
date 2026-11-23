import Combine
import EventKit
import Foundation

/// The calendar event a meeting belongs to, so its notes get the event's
/// title and its speakers can be named from the invitees. Off until the user
/// connects the calendar in Settings, which is when access is asked for. Hex
/// reads the calendar for the same reasons (anomalyco/hex, `src/calendar.rs`,
/// MIT); this is a rewrite on EventKit.
public enum CalendarMeetings {
    public struct Event: Codable, Equatable, Sendable {
        public var title: String
        /// Invitees other than the user, by name (or address when there is no name).
        public var attendees: [String]

        public init(title: String, attendees: [String]) {
            self.title = title
            self.attendees = attendees
        }
    }

    nonisolated(unsafe) private static let store = EKEventStore()

    public static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public static var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    /// The Settings switch. Turning it on asks for access the first time and
    /// stays off when access is refused. Returns whether it is on.
    @MainActor
    public static func connect(_ enabled: Bool) async -> Bool {
        var on = enabled && isAuthorized
        if enabled && !on { on = (try? await store.requestFullAccessToEvents()) ?? false }
        SettingsStore().setCalendarForMeetings(on)
        return on
    }

    /// An event may start this long after the recording does and still be its meeting.
    static let earlyStart: TimeInterval = 10 * 60

    /// The meeting the user is in at `date`: not all-day, cancelled, free or
    /// declined, with other people invited or a call link. When several
    /// overlap, the one that started nearest `date`.
    public static func event(at date: Date) -> Event? {
        guard isAuthorized else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-24 * 3600),
                                                 end: date.addingTimeInterval(earlyStart), calendars: nil)
        let best = store.events(matching: predicate)
            .filter { $0.startDate.addingTimeInterval(-earlyStart) <= date && date < $0.endDate && isMeeting($0) }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
        guard let best, let title = best.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return Event(title: title, attendees: attendees(of: best))
    }

    /// Invitees other than the user, by name or address, at most 30.
    private static func attendees(of event: EKEvent) -> [String] {
        let people = (event.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType == .person }
        let names = people.compactMap { person -> String? in
            if let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return address.isEmpty ? nil : address
        }
        return Array(names.prefix(30))
    }

    /// A meeting still to come, for the Meetings screens and the menu-bar menu.
    public struct Upcoming: Equatable, Sendable {
        public struct Join: Equatable, Sendable {
            public var app: String
            public var url: URL
        }

        public var title: String
        public var start: Date
        /// The call to join, when the event links to a known call service.
        public var join: Join?
        /// What a recording of this meeting keeps, as `event(at:)` gives it.
        public var event: Event
    }

    /// The next meeting from `date`, by the rules of `event(at:)`, up to a
    /// week ahead. One that started up to 10 minutes ago still counts, so a
    /// late joiner sees its link. Nil while the calendar is not connected.
    public static func next(after date: Date) -> Upcoming? {
        guard SettingsStore().calendarForMeetings, isAuthorized else { return nil }
        let earliest = date.addingTimeInterval(-earlyStart)
        let predicate = store.predicateForEvents(withStart: earliest, end: date.addingTimeInterval(7 * 24 * 3600), calendars: nil)
        let next = store.events(matching: predicate)
            .filter { $0.startDate >= earliest && $0.endDate > date && isMeeting($0) }
            .min { $0.startDate < $1.startDate }
        guard let next else { return nil }
        let title = next.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = [next.url?.absoluteString, next.location, next.notes].compactMap { $0 }.joined(separator: " ")
        let shown = title.isEmpty ? "Meeting" : title
        return Upcoming(title: shown, start: next.startDate, join: joinLink(in: text),
                        event: Event(title: shown, attendees: attendees(of: next)))
    }

    /// Slack is left out: a slack.com link in an invite is rarely the call itself.
    static let joinApps: [(service: String, app: String)] = [
        ("zoom.us", "Zoom"),
        ("meet.google.com", "Google Meet"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("webex.com", "Webex"),
    ]

    /// The first https link in `text` to a call service, with the service's name.
    static func joinLink(in text: String) -> Upcoming.Join? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, url.scheme == "https", let host = url.host?.lowercased() else { continue }
            if let entry = joinApps.first(where: { host == $0.service || host.hasSuffix("." + $0.service) }) {
                return Upcoming.Join(app: entry.app, url: url)
            }
        }
        return nil
    }

    /// When a meeting starts, as the Meetings screens and the menu show it:
    /// "Now", "in 12 min", "3:30 PM", "Tomorrow 10:00 AM" or "Wed 10:00 AM".
    public static func when(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "in \(minutes) min" }
        let time = start.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return "\(start.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    private static func isMeeting(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled, event.availability != .free else { return false }
        if event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined { return false }
        let othersInvited = event.attendees?.contains { !$0.isCurrentUser && $0.participantType == .person } ?? false
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        return othersInvited || hasCallLink(text)
    }

    static let callHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "slack.com"]

    static func hasCallLink(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return callHosts.contains { lowered.contains($0) }
    }
}

/// The next meeting, kept current: every 30 seconds, so "in 12 min" counts
/// down and a newly connected calendar shows up, and whenever the calendar changes.
@MainActor
public final class NextMeetingModel: ObservableObject {
    @Published public private(set) var next: CalendarMeetings.Upcoming?
    @Published public private(set) var now = Date()
    private var updates: AnyCancellable?

    public init() {
        refresh()
        updates = Timer.publish(every: 30, on: .main, in: .common).autoconnect().map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: .EKEventStoreChanged).map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: .gtSettingDidChange)
                .filter { $0.object as? String == "calendarForMeetings" }.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
    }

    private func refresh() {
        now = Date()
        next = CalendarMeetings.next(after: now)
    }
}
