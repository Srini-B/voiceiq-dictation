import SwiftUI
import UniformTypeIdentifiers

/// Import from Granola: pick the export's ZIP, see what it holds and what is
/// already here, import, then read what happened. Shared by the macOS and iOS settings.
@MainActor
public struct GranolaImportSection<Header: View>: View {
    private enum Step {
        case idle, reading
        case preview(GranolaImportPlan)
        case importing(done: Int, of: Int)
        case finished(GranolaImportReport)
        case failed(String)
    }

    private let store: MeetingStore
    private let header: Header
    @State private var step = Step.idle
    @State private var picking = false

    public init(store: MeetingStore = MeetingStore(), @ViewBuilder header: () -> Header) {
        self.store = store
        self.header = header()
    }

    public var body: some View {
        Section {
            content
        } header: {
            header
        } footer: {
            Text("In Granola, open Settings › Profile and click Generate CSV. Granola emails you a link to a ZIP of every meeting; choose that ZIP here. Notes, summaries and transcripts come across; Granola keeps no audio, attendees or meeting length.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .commaSeparatedText]) { result in
            switch result {
            case .success(let url): read(url)
            case .failure(let error): step = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .idle:
            Button("Import from Granola…") { picking = true }
        case .reading:
            HStack { ProgressView().controlSize(.small); Text("Reading the export…").foregroundStyle(.secondary) }
        case .preview(let plan):
            preview(plan)
        case .importing(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Importing \(done) of \(total) meetings…")
            }
        case .finished(let report):
            Label(report.imported == 1 ? "Imported 1 meeting" : "Imported \(report.imported) meetings", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if report.imported > 0 { Text("They are with your other meetings, with their notes and transcripts.").foregroundStyle(.secondary) }
            if report.existing > 0 { LabeledContent("Already in VoiceiQ, left as they are", value: "\(report.existing)") }
            skipped(report.skipped)
            Button("Done") { step = .idle }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Button("Choose another file…") { picking = true }
        }
    }

    @ViewBuilder
    private func preview(_ plan: GranolaImportPlan) -> some View {
        LabeledContent("Meetings in the export", value: "\(plan.total)")
        LabeledContent("New", value: "\(plan.new.count)")
        if let first = plan.new.first, let last = plan.new.last {
            LabeledContent("From", value: first.createdAt.formatted(date: .abbreviated, time: .omitted)
                           + " to " + last.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
        if !plan.existing.isEmpty { LabeledContent("Already in VoiceiQ, will be left as they are", value: "\(plan.existing.count)") }
        if !plan.new.isEmpty {
            DisclosureGroup("New meetings") {
                // Newest first, as Meetings lists them.
                ForEach(Array(plan.new.reversed().prefix(200).enumerated()), id: \.offset) { _, meeting in
                    LabeledContent(meeting.title, value: meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if plan.new.count > 200 { Text("and \(plan.new.count - 200) more").foregroundStyle(.secondary) }
            }
        }
        skipped(plan.skipped)
        HStack {
            Button("Cancel") { step = .idle }
            Spacer()
            Button(plan.new.count == 1 ? "Import 1 meeting" : "Import \(plan.new.count) meetings") { run(plan) }
                .buttonStyle(.borderedProminent)
                .disabled(plan.new.isEmpty)
        }
    }

    @ViewBuilder
    private func skipped(_ skipped: [GranolaSkip]) -> some View {
        if !skipped.isEmpty {
            DisclosureGroup("Skipped: \(skipped.count)") {
                ForEach(skipped) { skip in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skip.title ?? skip.place)
                        Text((skip.title == nil ? "" : "\(skip.place) · ") + skip.reason)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func read(_ url: URL) {
        step = .reading
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try GranolaImport.read(url) } }.value
            switch result {
            case .success(let export): step = .preview(GranolaImport.plan(export, store: store))
            case .failure(let error): step = .failed(error.localizedDescription)
            }
        }
    }

    private func run(_ plan: GranolaImportPlan) {
        step = .importing(done: 0, of: plan.new.count)
        Task {
            let report = await GranolaImport.run(plan, store: store) { step = .importing(done: $0, of: plan.new.count) }
            step = .finished(report)
        }
    }
}
