import SwiftUI

/// Mark where Lovely sorted each recent message as right or wrong, then share the tally.
/// Verdicts stay on this phone and never change sorting by themselves.
struct SortingReviewView: View {
    @Environment(FeedStore.self) private var store
    @State private var includeSubjects = false
    @State private var confirmingReset = false

    private static let limit = 60

    private var recent: [Post] {
        Array(store.activePosts.sorted { $0.email.date > $1.email.date }.prefix(Self.limit))
    }

    private func isPrivate(_ post: Post) -> Bool { ConversationPresentation.isSensitive(post.email, summary: post.summary) }

    private var items: [SortingReviewSummary.Item] {
        guard let review = store.review else { return [] }
        return recent.compactMap { post in
            guard let verdict = review.verdict(for: post.id) else { return nil }
            return SortingReviewSummary.Item(verdict: verdict, reason: store.assessment(for: post).reason,
                                             senderFirstName: post.email.from.firstName, senderAddress: post.email.from.email,
                                             subject: isPrivate(post) ? nil : post.email.subject)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("For each message, tap Right if Lovely put it in the right place, or pick where it belongs. Your answers stay on this phone and don't change sorting.")
                    .font(.subheadline).foregroundStyle(CalmStyle.secondary)
                if let review = store.review {
                    tally(review)
                    ForEach(recent) { post in ReviewRow(post: post, review: review, isPrivate: isPrivate(post)) }
                } else {
                    Text("Connect Gmail to review sorting.").font(.subheadline)
                }
            }
            .padding(20)
        }
        .background(CalmStyle.background).foregroundStyle(CalmStyle.ink)
        .navigationTitle("Review sorting").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func tally(_ review: SortingReview) -> some View {
        let reviewed = items
        let right = reviewed.filter(\.verdict.isRight).count
        VStack(alignment: .leading, spacing: 10) {
            Text(reviewed.isEmpty ? "Nothing reviewed yet" : "\(right) of \(reviewed.count) right")
                .font(.headline)
            Text("Showing your \(recent.count) newest messages.").font(.caption).foregroundStyle(CalmStyle.secondary)
            if !reviewed.isEmpty {
                Toggle("Include subjects when sharing", isOn: $includeSubjects).font(.subheadline)
                Text("Without subjects, the summary has only counts and the rule's reason, with names removed.")
                    .font(.caption).foregroundStyle(CalmStyle.secondary)
                HStack {
                    ShareLink(item: SortingReviewSummary.text(reviewed, includeSubjects: includeSubjects)) {
                        Label("Share summary", systemImage: "square.and.arrow.up").lineLimit(1)
                    }
                    .buttonStyle(CalmActionStyle(prominent: true)).fixedSize()
                    Spacer()
                    if confirmingReset {
                        Button("Clear all", role: .destructive) { review.reset(); confirmingReset = false }.buttonStyle(CalmActionStyle()).fixedSize()
                        Button("Keep") { confirmingReset = false }.buttonStyle(CalmActionStyle()).fixedSize()
                    } else {
                        Button("Start over") { confirmingReset = true }.buttonStyle(CalmActionStyle()).fixedSize()
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ReviewRow: View {
    @Environment(FeedStore.self) private var store
    let post: Post
    let review: SortingReview
    let isPrivate: Bool

    var body: some View {
        let assessment = store.assessment(for: post)
        let verdict = review.verdict(for: post.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(post.email.from.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(MailTime.short(post.email.date)).font(.caption).foregroundStyle(CalmStyle.secondary)
            }
            Text(isPrivate ? "Private message" : post.email.subject).font(.subheadline).lineLimit(2)
            Text("In \(assessment.section.title). \(assessment.reason)").font(.caption).foregroundStyle(CalmStyle.secondary)
            if let verdict {
                HStack {
                    if verdict.isRight {
                        Label("Right", systemImage: "checkmark.circle.fill").foregroundStyle(CalmStyle.blue)
                    } else {
                        Label("Belongs in \(FeedSection(rawValue: verdict.correct)?.title ?? "?")", systemImage: "arrow.uturn.right.circle.fill")
                            .foregroundStyle(CalmStyle.roseInk)
                    }
                    Spacer()
                    Button("Change") { review.clear(post.id) }.buttonStyle(CalmActionStyle()).fixedSize()
                }
                .font(.subheadline)
            } else {
                HStack(spacing: 8) {
                    Button { review.mark(post.id, shown: assessment.section, correct: assessment.section) } label: {
                        Label("Right", systemImage: "checkmark").lineLimit(1)
                    }
                    .buttonStyle(CalmActionStyle()).fixedSize()
                    Menu {
                        ForEach(FeedSection.allCases.filter { $0 != assessment.section }) { section in
                            Button(section.title) { review.mark(post.id, shown: assessment.section, correct: section) }
                        }
                    } label: {
                        Label("Belongs in…", systemImage: "arrow.uturn.right").lineLimit(1)
                    }
                    .buttonStyle(CalmActionStyle()).fixedSize()
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(CalmStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
