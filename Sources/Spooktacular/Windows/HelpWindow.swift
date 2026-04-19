import SwiftUI

/// In-app Help window — a searchable, topic-driven help browser
/// that replaces the legacy `Help.bundle` / AHT book approach.
///
/// The window is a SwiftUI `WindowGroup(id: "help")` scene (wired in
/// ``SpooktacularApp``) and is opened from the Help menu via
/// `openWindow(id: "help")` or `openWindow(id: "help", value: slug)`
/// when a specific topic should be pre-selected.
///
/// # Architecture
///
/// - ``HelpTopic`` is a plain value struct (title + slug + Markdown
///   body). All topics live in ``HelpTopicLibrary`` as a static
///   `let` array, so there's no I/O and no bundle lookup at open —
///   matching Apple's guidance that help content for a
///   shipped-app release should be static and locale-bundled
///   rather than fetched at runtime.
///   Docs: https://developer.apple.com/documentation/swiftui/windowgroup
///
/// - ``HelpView`` renders a `NavigationSplitView` with a
///   searchable sidebar (category + topic) and a Markdown-rendered
///   content pane via `AttributedString(markdown:)`.
///   Docs: https://developer.apple.com/documentation/foundation/attributedstring/init(markdown:)
///
/// - `⌘?` opens the window from the Help menu (standard macOS
///   shortcut, per
///   https://developer.apple.com/design/human-interface-guidelines/menus).
///
/// # Why not Help.bundle?
///
/// Apple's legacy Help Book format (`Help.bundle` + `.helpindex`)
/// predates SwiftUI and ships as a sidecar resource processed by
/// `hiutil`. A SwiftUI window is portable across macOS 14–26+,
/// searchable with the same `.searchable` modifier the library
/// window uses, and needs zero special tooling to author new
/// topics — just append to `HelpTopicLibrary.topics`.
struct HelpView: View {

    /// Optional starting topic slug — when opened from a specific
    /// Help menu item (e.g. "Getting Started"), the window
    /// pre-selects that topic. Nil = default to the first topic.
    let initialSlug: String?

    @State private var selectedSlug: String?
    @State private var searchText: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Help")
        .frame(minWidth: 780, minHeight: 520)
        // Use the window-wide material background helper — on
        // macOS 26 this renders as Liquid Glass; on 14–15 as
        // vibrancy blur. Docs cited in
        // `GlassModifiers.swift` → `WindowGlassBackgroundModifier`.
        .windowGlassBackground()
        .onAppear {
            if selectedSlug == nil {
                selectedSlug = initialSlug ?? HelpTopicLibrary.topics.first?.slug
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedSlug) {
            ForEach(HelpTopicLibrary.categories) { category in
                Section(category.title) {
                    ForEach(filteredTopics(in: category)) { topic in
                        Label(topic.title, systemImage: topic.systemImage)
                            .tag(topic.slug as String?)
                            .accessibilityLabel(topic.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !searchText.isEmpty, totalFilteredCount == 0 {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let slug = selectedSlug,
           let topic = HelpTopicLibrary.topic(forSlug: slug) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(for: topic)
                    Divider()
                    bodyContent(for: topic)
                }
                .padding(32)
                .frame(maxWidth: 780, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Spooktacular Help",
                systemImage: "questionmark.circle",
                description: Text("Pick a topic from the sidebar, or search for one.")
            )
        }
    }

    @ViewBuilder
    private func header(for topic: HelpTopic) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: topic.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(topic.subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Renders the topic's Markdown body via
    /// `AttributedString(markdown:options:)`. Apple's Markdown
    /// parser supports headings, lists, inline code, bold, italic,
    /// and links — the topics in ``HelpTopicLibrary`` stick to
    /// that subset. When parsing fails (shouldn't, it's static
    /// content) we fall back to a plain-text render so the help
    /// view never blanks out.
    ///
    /// Docs: https://developer.apple.com/documentation/foundation/attributedstring/init(markdown:options:baseurl:)
    @ViewBuilder
    private func bodyContent(for topic: HelpTopic) -> some View {
        if let attributed = Self.renderMarkdown(topic.body) {
            Text(attributed)
                .textSelection(.enabled)
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(topic.body)
                .textSelection(.enabled)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Parses a Markdown source string into an `AttributedString`
    /// with `.inlineOnlyPreservingWhitespace` — the option that
    /// keeps paragraph breaks and list structure visible in
    /// SwiftUI's text renderer. Returns nil on parse failure.
    static func renderMarkdown(_ source: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return try? AttributedString(markdown: source, options: options)
    }

    // MARK: - Search

    private func filteredTopics(in category: HelpCategory) -> [HelpTopic] {
        let scoped = HelpTopicLibrary.topics.filter { $0.category == category.id }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return scoped }
        return scoped.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    private var totalFilteredCount: Int {
        HelpTopicLibrary.categories.reduce(0) { total, category in
            total + filteredTopics(in: category).count
        }
    }
}
