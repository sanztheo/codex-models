import AppKit
import ServiceManagement
import SwiftUI

private let panelWidth: CGFloat = 330
private let rowHeight: CGFloat = 52
private let childRowHeight: CGFloat = 36

private func defaultCodexDirectory() -> URL {
    if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
        return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
}

private extension Color {
    static let codexBackground = Color(red: 25 / 255, green: 27 / 255, blue: 29 / 255)
    static let codexGreen = Color(red: 40 / 255, green: 224 / 255, blue: 123 / 255)
    static let codexOrange = Color(red: 255 / 255, green: 163 / 255, blue: 65 / 255)
    static let codexText = Color(red: 248 / 255, green: 248 / 255, blue: 245 / 255)
    static let codexMuted = Color(red: 166 / 255, green: 170 / 255, blue: 176 / 255)
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
        refreshTimer?.tolerance = 0.1
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

private struct CodexMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<6) { index in
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.codexText, lineWidth: 1.2)
                    .frame(width: 10, height: 15)
                    .offset(y: -4)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}

struct ConversationListView: View {
    @ObservedObject var model: ConversationsModel
    @ObservedObject var quota: QuotaModel
    let onQuit: () -> Void
    @AppStorage("showCompleted") private var showCompleted = false
    @State private var collapsedIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ConversationsModel, quota: QuotaModel,
         onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.model = model
        self.quota = quota
        self.onQuit = onQuit
    }

    private var visible: [Conversation] {
        model.conversations.flatMap { $0.filtered(showCompleted: showCompleted) }
    }

    private var listHeight: CGFloat {
        func height(_ item: Conversation, nested: Bool) -> CGFloat {
            (nested ? childRowHeight : rowHeight) + (collapsedIDs.contains(item.id) ? 0 :
                item.children.reduce(CGFloat.zero) { $0 + height($1, nested: true) })
        }
        return min(280, max(70, visible.reduce(CGFloat(4)) { $0 + height($1, nested: false) + 5 }))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    CodexMark().scaleEffect(0.72).frame(width: 18, height: 18)
                    Text("Codex Models").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        (Text("Quota restant ").foregroundColor(.codexMuted) + Text(quota.menuText).bold())
                        if let remaining = quota.snapshot?.remaining {
                            ProgressView(value: Double(remaining), total: 100)
                                .tint(Color(white: 0.76))
                                .scaleEffect(x: 1, y: 0.65)
                                .accessibilityLabel("Quota restant")
                                .accessibilityValue("\(remaining) pour cent")
                        }
                    }
                    .frame(width: 108)
                    .help(quota.tooltip)
                }
                .font(.system(size: 11))
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Circle().fill(model.isHealthy ? Color.codexOrange : Color.codexMuted)
                            .frame(width: 7, height: 7)
                        Text(model.isHealthy ? "\(model.activeCount) en cours" : "Lecture en cours…")
                    }
                    Spacer()
                    if model.unreadCount > 0 {
                        Button { model.acknowledgeNewAgents() } label: {
                            Label("\(model.unreadCount)", systemImage: "bell.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.codexOrange)
                        .accessibilityLabel("Marquer \(model.unreadCount) nouveaux sous-agents comme vus")
                    }
                HStack(spacing: 2) {
                    filterButton("En cours", selected: !showCompleted) { showCompleted = false }
                    filterButton("Terminées", selected: showCompleted) { showCompleted = true }
                }
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .frame(width: 185)
                }
                .font(.system(size: 10))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

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
                            MinimalConversationRow(item: item, collapsedIDs: $collapsedIDs)
                                .padding(.vertical, 2)
                            if item.id != visible.last?.id {
                                Divider().overlay(Color.white.opacity(0.04))
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: visible)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: collapsedIDs)
            }
            .scrollIndicators(.hidden)
            .frame(height: listHeight)

            Divider().overlay(Color.white.opacity(0.04))
            HStack(spacing: 8) {
                Circle().fill(Color.codexMuted).frame(width: 5, height: 5)
                if let error = model.errorMessage {
                    Text("Lecture indisponible").foregroundStyle(Color.codexOrange).help(error)
                } else if let date = model.lastSuccess {
                    Text("Actualisé à \(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))")
                        .monospacedDigit()
                        .help("Dernière lecture réussie · actualisation chaque seconde")
                } else {
                    Text("Connexion…")
                }
                Spacer()
                Button { model.refresh(); quota.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .help("Actualiser").accessibilityLabel("Actualiser")
                Button(action: onQuit) {
                    Image(systemName: "power").frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .help("Quitter").accessibilityLabel("Quitter Codex Models")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Color.codexMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: panelWidth)
        .background(Color.codexBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.16), lineWidth: 0.75))
        .foregroundStyle(Color.codexText)
        .environment(\.colorScheme, .dark)
        .onAppear { model.acknowledgeNewAgents() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.acknowledgeNewAgents()
        }
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if !showCompleted && title == "En cours" && model.isHealthy {
                    Text("\(model.activeCount)")
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .font(.system(size: 11, weight: selected ? .medium : .regular))
            .frame(maxWidth: .infinity).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(selected ? 0.10 : 0)))
            .foregroundStyle(selected ? Color.codexText : Color.codexMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title == "Terminées" ? "Inclure les conversations terminées non archivées" : "Masquer les conversations terminées")
    }
}

private struct MinimalConversationRow: View {
    let item: Conversation
    @Binding var collapsedIDs: Set<String>
    var nested = false
    @State private var hovered = false
    @State private var infoHovered = false
    @State private var showTitle = false

    private var expanded: Bool { !collapsedIDs.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        MinimalConversationRow(item: child, collapsedIDs: $collapsedIDs, nested: true)
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.23)).frame(width: 0.75).padding(.vertical, 4)
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 7) {
            Button {
                if expanded { collapsedIDs.insert(item.id) }
                else { collapsedIDs.remove(item.id) }
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
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showTitle = false
                    if let url = item.codexURL { NSWorkspace.shared.open(url) }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.codexURL == nil)
                .accessibilityLabel("Ouvrir \(item.title) dans Codex")
                if !nested && (item.folderName != nil || item.parentTitle != nil) {
                    HStack(spacing: 5) {
                        if let folder = item.folderName {
                            Text(folder).layoutPriority(1)
                        }
                        if let parent = item.parentTitle { Text("↳ \(parent)") }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                }
                Text("\(item.model) · \(item.effort)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .help("\(item.model), effort \(item.effort)")
            }
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                if item.status == .running {
                    if nested { Circle().fill(Color.codexOrange).frame(width: 6, height: 6) }
                    else { RunningSpinner() }
                    if let start = item.turnStartedAt {
                        Text(start, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(Color.codexText)
                            .help("Durée depuis le début du tour en cours")
                    }
                } else {
                    if item.status == .completed { Image(systemName: "checkmark") }
                    if item.status == .failed { Image(systemName: "exclamationmark.triangle") }
                    Text(item.status.label)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(item.status == .completed ? Color.codexGreen :
                             item.status == .failed ? Color.codexOrange : Color.codexMuted)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.status.label)
            titleInfo
        }
        .padding(.horizontal, 7)
        .frame(height: nested ? childRowHeight : rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovered ? 0.055 : 0)))
        .onHover { hovered = $0 }
    }

    private var titleInfo: some View {
        Button { showTitle.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.codexMuted.opacity(hovered || showTitle ? 1 : 0.4))
                .frame(width: 18, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Afficher le titre complet : \(item.title)")
        .onHover { infoHovered = $0 }
        .task(id: infoHovered) {
            guard infoHovered else {
                showTitle = false
                return
            }
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showTitle = true
        }
        .popover(isPresented: $showTitle, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                if let parent = item.parentTitle { Text("Tâche parente : \(parent)") }
                if let directory = item.workingDirectory { Text("Dossier : \(directory)") }
            }
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
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

// Same window presentation as PerformanceViewer/PerformanceApp.swift.
struct CodexModelsApp: App {
    @StateObject private var model = ConversationsModel()
    @StateObject private var quota = QuotaModel()

    init() {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ConversationListView(model: model, quota: quota)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.unreadCount > 0 ? "bell.badge" : "square.grid.2x2")
                Text("| \(quota.menuText)").monospacedDigit()
            }
            .font(.system(size: 11))
            .accessibilityLabel("Codex Models, quota restant \(quota.menuText), \(model.unreadCount) nouveaux sous-agents")
            .help(quota.tooltip)
        }
        .menuBarExtraStyle(.window)
    }
}

struct CodexModelsPreviewApp: App {
    @StateObject private var model = ConversationsModel()
    @StateObject private var quota = QuotaModel()

    var body: some Scene {
        WindowGroup("Codex Models") {
            ConversationListView(model: model, quota: quota)
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
