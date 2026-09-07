import AppKit
import ServiceManagement
import SwiftUI

private let panelWidth: CGFloat = 330
private let rowHeight: CGFloat = 56

private func defaultCodexDirectory() -> URL {
    if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
        return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
}

private extension Color {
    static let codexBackground = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    static let codexGreen = Color(red: 40 / 255, green: 224 / 255, blue: 123 / 255)
    static let codexOrange = Color(red: 255 / 255, green: 106 / 255, blue: 54 / 255)
    static let codexText = Color(red: 248 / 255, green: 248 / 255, blue: 245 / 255)
    static let codexMuted = Color(red: 150 / 255, green: 150 / 255, blue: 150 / 255)
}

@MainActor
final class ConversationsModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var unreadCount = 0

    private let reader: CodexReader
    private let readerQueue = DispatchQueue(label: "local.sanz.codexmodels.reader")
    private var refreshTimer: Timer?
    private let startedAt = Date().timeIntervalSince1970
    private var seenSubagentIDs: Set<String>?
    private var unreadSubagentIDs: Set<String> = []

    init(directory: URL = defaultCodexDirectory()) {
        reader = CodexReader(directory: directory)
        startMonitoring()
    }

    var activeCount: Int {
        conversations.reduce(0) { $0 + $1.activeCount }
    }

    var isHealthy: Bool {
        lastSuccess != nil && errorMessage == nil
    }

    func startMonitoring() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func acknowledgeNewAgents() {
        unreadSubagentIDs.removeAll()
        unreadCount = 0
    }

    private func trackNewAgents(_ loaded: [Conversation]) {
        let children = loaded.flatMap(\.descendants)
        let currentIDs = Set(children.map(\.id))
        if let seen = seenSubagentIDs {
            let newIDs = children.filter { !seen.contains($0.id) && $0.createdAt >= startedAt }.map(\.id)
            unreadSubagentIDs.formUnion(newIDs)
            unreadSubagentIDs.formIntersection(currentIDs)
            if unreadCount != unreadSubagentIDs.count { unreadCount = unreadSubagentIDs.count }
            seenSubagentIDs = seen.union(currentIDs)
        } else {
            // Existing children form the baseline; startup never floods the badge.
            seenSubagentIDs = currentIDs
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let reader = reader
        readerQueue.async {
            do {
                let loaded = try reader.load()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.trackNewAgents(loaded)
                    if self.conversations != loaded {
                        self.conversations = loaded
                    }
                    self.lastSuccess = Date()
                    self.errorMessage = nil
                    self.isRefreshing = false
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.errorMessage = message
                    self.isRefreshing = false
                }
            }
        }
    }
}

struct ConversationListView: View {
    @ObservedObject var model: ConversationsModel
    let onQuit: () -> Void
    @AppStorage("showCompleted") private var showCompleted = false
    @State private var expandedIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ConversationsModel,
         onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.model = model
        self.onQuit = onQuit
    }

    private var visible: [Conversation] {
        model.conversations.flatMap { $0.filtered(showCompleted: showCompleted) }
    }

    private var listHeight: CGFloat {
        func rowCount(_ item: Conversation) -> Int {
            1 + (expandedIDs.contains(item.id) ? item.children.reduce(0) { $0 + rowCount($1) } : 0)
        }
        let count = visible.reduce(0) { $0 + rowCount($1) }
        return min(300, max(70, CGFloat(count) * rowHeight + 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("Codex")
                    .font(.system(size: 12, weight: .semibold))
                if model.isHealthy {
                    if model.activeCount > 0 {
                        Circle().fill(Color.codexOrange).frame(width: 4, height: 4)
                    }
                    Text("\(model.activeCount) en cours")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer(minLength: 5)
                if model.unreadCount > 0 {
                    Button { model.acknowledgeNewAgents() } label: {
                        Label("\(model.unreadCount)", systemImage: "bell.fill")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.codexOrange)
                    .help("Nouveaux sous-agents · cliquer pour effacer le badge")
                    .accessibilityLabel("Marquer \(model.unreadCount) nouveaux sous-agents comme vus")
                }
                Toggle("Terminées", isOn: $showCompleted)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .help("Afficher les conversations et sous-agents terminés non archivés")
                    .accessibilityLabel("Afficher les terminées")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text(model.errorMessage != nil ? "Lecture indisponible" :
                             model.lastSuccess == nil ? "Chargement…" :
                             model.conversations.isEmpty ? "Aucune conversation" : "Tout est terminé")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(visible) { item in
                            MinimalConversationRow(item: item, expandedIDs: $expandedIDs)
                        }
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: visible)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expandedIDs)
            }
            .scrollIndicators(.hidden)
            .frame(height: listHeight)

            Divider().overlay(Color.white.opacity(0.04))
            HStack(spacing: 12) {
                if let error = model.errorMessage {
                    Text("Lecture indisponible")
                        .foregroundStyle(Color.codexOrange)
                        .help(error)
                } else if let date = model.lastSuccess {
                    Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                        .monospacedDigit()
                        .help("Dernière lecture réussie · actualisation chaque seconde")
                } else {
                    Text("Connexion…")
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Actualiser")
                    .accessibilityLabel("Actualiser")
                Button(action: onQuit) { Image(systemName: "power") }
                    .help("Quitter")
                    .accessibilityLabel("Quitter Codex Models")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Color.codexMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: panelWidth)
        .background(Color.codexBackground)
        .foregroundStyle(Color.codexText)
        .environment(\.colorScheme, .dark)
        .onAppear { model.acknowledgeNewAgents() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.acknowledgeNewAgents()
        }
    }
}

private struct MinimalConversationRow: View {
    let item: Conversation
    @Binding var expandedIDs: Set<String>
    @State private var hovered = false
    @State private var showTitle = false

    private var expanded: Bool { expandedIDs.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        MinimalConversationRow(item: child, expandedIDs: $expandedIDs)
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1).padding(.vertical, 4)
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 7) {
            Button {
                if expanded { expandedIDs.remove(item.id) }
                else { expandedIDs.insert(item.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.children.isEmpty ? 0 : 0.5)
            .disabled(item.children.isEmpty)
            .accessibilityLabel("\(expanded ? "Replier" : "Déplier") les sous-agents de \(item.title)")
            if item.status == .running {
                RunningSpinner()
            } else {
                Color.clear.frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    showTitle = false
                    if let url = item.codexURL { NSWorkspace.shared.open(url) }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.codexURL == nil)
                .accessibilityLabel("Ouvrir \(item.title) dans Codex")
                if let parent = item.parentTitle {
                    Text("↳ \(parent)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .help("Tâche parente : \(parent)")
                }
                Text("\(item.model) · \(item.effort)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .help("\(item.model), effort \(item.effort)")
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                if item.status == .completed { Image(systemName: "checkmark") }
                if item.status == .failed { Image(systemName: "exclamationmark.triangle") }
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.status.label)
                    if item.status == .running, let start = item.turnStartedAt {
                        Text(start, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(Color.codexMuted)
                            .help("Durée depuis le début du tour en cours")
                    }
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(item.status == .completed ? Color.codexGreen :
                             item.status == .running || item.status == .failed ? Color.codexOrange : Color.codexMuted)
            .fixedSize()
        }
        .padding(.horizontal, 7)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(hovered ? 0.04 : 0)))
        .onHover { hovered = $0 }
        .task(id: hovered) {
            guard hovered else {
                showTitle = false
                return
            }
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showTitle = true
        }
        .popover(isPresented: $showTitle, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            Text(item.title)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.12))
                .lineLimit(nil)
                .frame(idealWidth: 260, maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.96))
                .environment(\.colorScheme, .light)
        }
        .onDisappear { showTitle = false }
    }
}

private struct RunningSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            Circle().trim(from: 0, to: 0.72)
                .stroke(Color.codexOrange, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)
    }
}

// Same window presentation as PerformanceViewer/PerformanceApp.swift.
struct CodexModelsApp: App {
    @StateObject private var model = ConversationsModel()

    init() {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ConversationListView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.unreadCount > 0 ? "bell.badge" : "square.grid.2x2")
                if model.unreadCount > 0 { Text("\(model.unreadCount)").monospacedDigit() }
            }
            .font(.system(size: 11))
            .accessibilityLabel("Codex Models, \(model.unreadCount) nouveaux sous-agents")
            .help("Codex Models · \(model.activeCount) en cours · \(model.unreadCount) nouveaux sous-agents")
        }
        .menuBarExtraStyle(.window)
    }
}

struct CodexModelsPreviewApp: App {
    @StateObject private var model = ConversationsModel()

    var body: some Scene {
        WindowGroup("Codex Models") {
            ConversationListView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@main
struct CodexModelsEntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check") {
            runChecks()
        } else if CommandLine.arguments.contains("--preview") {
            CodexModelsPreviewApp.main()
        } else {
            CodexModelsApp.main()
        }
    }
}
