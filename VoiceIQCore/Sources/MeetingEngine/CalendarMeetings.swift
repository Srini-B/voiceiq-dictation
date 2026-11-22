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
        let people = (best.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType == .person }
        let names = people.compactMap { person -> String? in
            if let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return address.isEmpty ? nil : address
        }
        return Event(title: title, attendees: Array(names.prefix(30)))
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
