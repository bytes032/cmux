import AppKit
import Bonsplit
import SwiftUI
import WebKit

struct DiffPanelView: View {
    private typealias FileTreeNode = DiffPanelTreeNode

    private static let additionColor = Color(nsColor: NSColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1.0))
    private static let deletionColor = Color(nsColor: NSColor(red: 0.90, green: 0.30, blue: 0.28, alpha: 1.0))

    private struct FileTreeRowView: View {
        let node: FileTreeNode
        let depth: Int
        let selectedFilePath: String?
        @Binding var expandedDirectoryPaths: Set<String>
        let onSelectFile: (String) -> Void

        private var isExpanded: Bool {
            expandedDirectoryPaths.contains(node.id)
        }

        var body: some View {
            if node.isDirectory {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if isExpanded {
                            expandedDirectoryPaths.remove(node.id)
                        } else {
                            expandedDirectoryPaths.insert(node.id)
                        }
                    } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.62))

                        Text(node.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.primary.opacity(0.82))
                            .lineLimit(1)

                            Spacer(minLength: 4)

                            if !isExpanded {
                                FileStatsView(
                                    additions: node.additions,
                                    deletions: node.deletions,
                                    isBinary: false
                                )
                            }

                        }
                        .padding(.leading, CGFloat(depth) * 16 + 4)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        ForEach(node.children) { child in
                            FileTreeRowView(
                                node: child,
                                depth: depth + 1,
                                selectedFilePath: selectedFilePath,
                                expandedDirectoryPaths: $expandedDirectoryPaths,
                                onSelectFile: onSelectFile
                            )
                        }
                    }
                }
            } else if let fullPath = node.fullPath {
                let isSelected = selectedFilePath == fullPath
                Button {
                    onSelectFile(fullPath)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(isSelected ? .primary.opacity(0.7) : .secondary.opacity(0.45))

                        Text(node.name)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .primary : .primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        FileStatsView(additions: node.additions, deletions: node.deletions, isBinary: node.isBinary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(depth) * 16 + 18)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? cmuxAccentColor().opacity(0.16) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .id(fullPath)
            }
        }
    }

    private struct FileStatsView: View {
        let additions: Int
        let deletions: Int
        let isBinary: Bool

        var body: some View {
            if isBinary {
                Text("BIN")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                HStack(spacing: 3) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(additionColor)
                    }
                    if deletions > 0 {
                        Text("-\(deletions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(deletionColor)
                    }
                }
            }
        }
    }

    private struct SearchableFileEntry {
        let file: DiffPanel.FileEntry
        let treeFile: DiffPanelTreeFile
        let searchPath: String
        let searchDisplayName: String

        init(file: DiffPanel.FileEntry) {
            let treeFile = DiffPanelTreeFile(
                path: file.path,
                fileName: file.displayName,
                additions: file.additions,
                deletions: file.deletions
            )
            self.file = file
            self.treeFile = treeFile
            self.searchPath = treeFile.searchPath
            self.searchDisplayName = treeFile.searchFileName
        }
    }

    @ObservedObject var panel: DiffPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var expandedDirectoryPaths: Set<String> = []
    @State private var fileFilterQuery: String = ""
    @State private var searchableFiles: [SearchableFileEntry] = []
    @State private var treeContext = DiffPanelTreeContext()
    @State private var sharedWebViewUpdateContext = DiffWebViewUpdateContext()
    @State private var showingCommits: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private let inspectorWidth: CGFloat = 284

    var body: some View {
        HStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            inspector
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            if isVisibleInUI {
                DiffPanelPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onAppear {
            panel.setPreferredWebViewIsDarkMode(colorScheme == .dark)
            refreshSearchableFiles(from: panel.files)
            syncExpandedDirectories(with: panel.files)
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
        .onChange(of: colorScheme) {
            panel.setPreferredWebViewIsDarkMode(colorScheme == .dark)
        }
        .onChange(of: panel.files) {
            refreshSearchableFiles(from: panel.files)
            syncExpandedDirectories(with: panel.files)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            if let payload = currentWebViewPayload {
                DiffWebViewRepresentable(
                    payload: payload,
                    updateContext: sharedWebViewUpdateContext
                )
            }

            mainForegroundContent
        }
        .overlay {
            if shouldShowLoadingOverlay {
                loadingOverlayView
            }
        }
        .background(backgroundColor)
    }

    private var shouldShowLoadingOverlay: Bool {
        panel.hasLoadedSnapshot && panel.isScopeLoading
    }

    private var currentWebViewPayload: DiffWebViewRenderPayload? {
        panel.currentRenderPayload(isDarkMode: colorScheme == .dark)
    }

    @ViewBuilder
    private var mainForegroundContent: some View {
        if !panel.hasLoadedSnapshot {
            loadingView
        } else if let errorMessage = panel.errorMessage, panel.patch.isEmpty {
            errorView(message: errorMessage)
        } else if panel.patch.isEmpty {
            cleanView
        } else {
            EmptyView()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(panel.scopeDisplayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingOverlayView: some View {
        Group {
            if panel.hasLoadedSnapshot {
                diffLoadingSkeletonView
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor.opacity(0.88))
    }

    private var cleanView: some View {
        VStack(spacing: 12) {
            Image(systemName: panel.isShowingWorkingTree ? "checkmark.seal" : "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(
                panel.isShowingWorkingTree
                    ? String(localized: "diffPanel.clean.title", defaultValue: "Working tree clean")
                    : String(localized: "diffPanel.emptySelection.title", defaultValue: "No diff in this selection")
            )
            .font(.headline)
            .foregroundColor(.primary)
            Text(
                panel.isShowingWorkingTree
                    ? String(localized: "diffPanel.clean.message", defaultValue: "No uncommitted changes in this repository.")
                    : String(localized: "diffPanel.emptySelection.message", defaultValue: "This commit selection does not produce a patch.")
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "diffPanel.error.title", defaultValue: "Diff unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            inspectorToggle

            Divider().opacity(0.4)

            if showingCommits {
                commitsPane
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                    TextField(
                        String(localized: "diffPanel.sidebar.files.filterPlaceholder", defaultValue: "Filter files..."),
                        text: $fileFilterQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                    if !fileFilterQuery.isEmpty {
                        Button {
                            fileFilterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(sectionHeaderBackgroundColor.opacity(0.32))

                Divider().opacity(0.3)

                fileTreePane
            }
        }
        .background(inspectorBackgroundColor)
    }

    private var diffLoadingSkeletonView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    skeletonFileCard(lineCount: index == 0 ? 9 : 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .allowsHitTesting(false)
    }

    private func skeletonFileCard(lineCount: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 168, height: 12)

                Spacer(minLength: 0)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Self.additionColor.opacity(0.18))
                    .frame(width: 30, height: 10)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Self.deletionColor.opacity(0.16))
                    .frame(width: 26, height: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(sectionHeaderBackgroundColor.opacity(0.42))

            VStack(spacing: 0) {
                ForEach(0..<lineCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 56, height: 24)

                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.secondary.opacity(0.07))
                            .frame(width: 56, height: 24)

                        RoundedRectangle(cornerRadius: 0)
                            .fill(
                                row.isMultiple(of: 5)
                                    ? Self.additionColor.opacity(0.12)
                                    : (row.isMultiple(of: 4) ? Self.deletionColor.opacity(0.10) : Color.secondary.opacity(0.06))
                            )
                            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 1)
        )
        .redacted(reason: .placeholder)
    }

    private var inspectorToggle: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                inspectorToggleButton(
                    title: String(localized: "diffPanel.toggle.files", defaultValue: "Files"),
                    icon: "doc.on.doc",
                    isActive: !showingCommits
                ) {
                    showingCommits = false
                }

                inspectorToggleButton(
                    title: String(localized: "diffPanel.toggle.commits", defaultValue: "Commits"),
                    icon: "clock.arrow.circlepath",
                    isActive: showingCommits
                ) {
                    showingCommits = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(sectionHeaderBackgroundColor.opacity(0.52))
    }

    private func inspectorToggleButton(
        title: String,
        icon: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isActive ? .primary : .secondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fileTreePane: some View {
        VStack(spacing: 0) {
            if !panel.files.isEmpty {
                fileSummaryBar
            }

            Group {
                if panel.files.isEmpty {
                    emptyStateLabel(
                        String(localized: "diffPanel.sidebar.files.empty", defaultValue: "No modified files")
                    )
                } else if filteredFiles.isEmpty {
                    emptyStateLabel(
                        String(localized: "diffPanel.sidebar.files.noMatches", defaultValue: "No matching files")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(fileTreeNodes) { node in
                                FileTreeRowView(
                                    node: node,
                                    depth: 0,
                                    selectedFilePath: sidebarHighlightedFilePath,
                                    expandedDirectoryPaths: $expandedDirectoryPaths
                                ) { path in
                                    if !panel.isShowingAllFiles, panel.selectedFilePath == path {
                                        panel.selectAllFiles()
                                    } else {
                                        panel.selectFile(path)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fileSummaryBar: some View {
        let files = panel.files
        let totalAdditions = files.reduce(0) { $0 + max(0, $1.additions) }
        let totalDeletions = files.reduce(0) { $0 + max(0, $1.deletions) }

        return HStack(spacing: 4) {
            Text("\(files.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary.opacity(0.86))
            Text(files.count == 1
                 ? String(localized: "diffPanel.summary.file", defaultValue: "file")
                 : String(localized: "diffPanel.summary.files", defaultValue: "files")
            )
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.82))

            Spacer(minLength: 4)

            Button {
                panel.selectAllFiles()
            } label: {
                Text(String(localized: "diffPanel.sidebar.files.all", defaultValue: "All Files"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(panel.isShowingAllFiles ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(panel.isShowingAllFiles ? Color.primary.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(panel.isShowingAllFiles)

            if totalAdditions > 0 {
                Text("+\(totalAdditions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Self.additionColor.opacity(0.85))
            }
            if totalDeletions > 0 {
                Text("−\(totalDeletions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Self.deletionColor.opacity(0.85))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(sectionHeaderBackgroundColor.opacity(0.54))
    }

    private var commitsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                commitRow(
                    prefix: nil,
                    title: String(localized: "diffPanel.scope.workingTree", defaultValue: "Working Tree"),
                    subtitle: panel.repositoryDisplayName,
                    isSelected: panel.isShowingWorkingTree
                ) {
                    panel.selectWorkingTree()
                }

                if panel.commits.isEmpty {
                    emptyStateLabel(
                        String(localized: "diffPanel.sidebar.commits.empty", defaultValue: "No commits yet")
                    )
                    .padding(.top, 4)
                } else {
                    ForEach(panel.commits) { commit in
                        commitRow(
                            prefix: commit.shortSHA,
                            title: commit.subject,
                            subtitle: "\(commit.relativeDate) \u{00B7} \(commit.author)",
                            isSelected: panel.selectedCommitSHA == commit.sha
                        ) {
                            panel.selectCommit(commit.sha)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func commitRow(
        prefix: String?,
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let prefix, !prefix.isEmpty {
                        Text(prefix)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.82))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(isSelected ? 0.10 : 0.06))
                            )
                    }

                    Text(title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .primary : .primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.74))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? cmuxAccentColor().opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func emptyStateLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTreeNodes: [FileTreeNode] {
        let query = fileFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return panel.unfilteredTreeNodes
        }
        return treeContext.nodes(for: filteredTreeFiles, cacheKey: treeCacheKey)
    }

    private var filteredFiles: [DiffPanel.FileEntry] {
        filteredSearchResults.map(\.file)
    }

    private var sidebarHighlightedFilePath: String? {
        if panel.isShowingAllFiles {
            return nil
        }
        return panel.selectedFilePath
    }

    private var filteredTreeFiles: [DiffPanelTreeFile] {
        filteredSearchResults.map(\.treeFile)
    }

    private var filteredSearchResults: [SearchableFileEntry] {
        let query = fileFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return searchableFiles }

        let normalizedQuery = query.localizedLowercase
        return searchableFiles.filter { candidate in
            candidate.searchPath.contains(normalizedQuery)
                || candidate.searchDisplayName.contains(normalizedQuery)
        }
    }

    private var treeCacheKey: String {
        let query = fileFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return "\(panel.currentTreeCacheKey)|\(query)"
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.97, alpha: 1.0))
    }

    private var inspectorBackgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(red: 0.086, green: 0.094, blue: 0.109, alpha: 1.0))
            : Color(nsColor: NSColor(red: 0.952, green: 0.958, blue: 0.970, alpha: 1.0))
    }

    private var sectionHeaderBackgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(red: 0.108, green: 0.118, blue: 0.138, alpha: 1.0))
            : Color(nsColor: NSColor(red: 0.936, green: 0.942, blue: 0.956, alpha: 1.0))
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }

    private func syncExpandedDirectories(with files: [DiffPanel.FileEntry]) {
        // Expand based on the compacted tree node IDs, not raw path components
        func collectDirectoryIds(_ nodes: [FileTreeNode]) -> Set<String> {
            var ids: Set<String> = []
            for node in nodes where node.isDirectory {
                ids.insert(node.id)
                ids.formUnion(collectDirectoryIds(node.children))
            }
            return ids
        }
        expandedDirectoryPaths.formUnion(collectDirectoryIds(fileTreeNodes))
    }

    private func refreshSearchableFiles(from files: [DiffPanel.FileEntry]) {
        searchableFiles = files.map(SearchableFileEntry.init)
    }
}

private struct DiffWebViewRepresentable: NSViewRepresentable {
    let payload: DiffWebViewRenderPayload
    let updateContext: DiffWebViewUpdateContext

    func makeCoordinator() -> Coordinator {
        Coordinator(updateContext: updateContext)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController.add(context.coordinator, name: "cmuxDiffPerf")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = 0.92
        context.coordinator.bind(webView: webView)
        #if DEBUG
        dlog("diff.webview.make")
        #endif
        if let htmlURL = Self.htmlURL() {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(payload: payload)
    }

    private static func htmlURL() -> URL? {
        Bundle.main.url(forResource: "cmux-diff-viewer", withExtension: "html")
    }

    private static let fallbackHTML = """
    <!doctype html>
    <html>
    <body style="margin:0;display:flex;align-items:center;justify-content:center;height:100vh;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#101214;color:#c8ccd4;">
      Diff viewer resources are missing from the app bundle.
    </body>
    </html>
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var webView: WKWebView?
        private let updateContext: DiffWebViewUpdateContext
        private var didFinishNavigation = false
        private var pendingPayload: DiffWebViewRenderPayload?
        private var appliedPayload: DiffWebViewRenderPayload?
        private var pushInFlight = false
        private var lastPayloadPushStartedAt: Date?

        init(updateContext: DiffWebViewUpdateContext) {
            self.updateContext = updateContext
        }

        func bind(webView: WKWebView) {
            self.webView = webView
        }

        func update(payload: DiffWebViewRenderPayload) {
            pendingPayload = payload
            pushPayloadIfPossible()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishNavigation = true
            #if DEBUG
            dlog("diff.webview.navReady")
            #endif
            pushPayloadIfPossible()
        }

        func pushPayloadIfPossible() {
            guard didFinishNavigation,
                  !pushInFlight,
                  let webView,
                  let pendingPayload,
                  let update = updateContext.makeUpdate(
                    previous: appliedPayload,
                    next: pendingPayload,
                    pageHasLoaded: true
                  ) else {
                return
            }

            pushInFlight = true
            #if DEBUG
            lastPayloadPushStartedAt = Date()
                dlog(
                "diff.webview.push kind=\(update.kind) payloadBytes=\(update.encodedBytes) selected=\(pendingPayload.selectedFilePath ?? "all-files") fileCount=\(pendingPayload.files.count) firstFile=\(pendingPayload.files.first?.displayPath ?? "none")"
            )
            #endif
            webView.evaluateJavaScript(update.javaScript) { [weak self] _, error in
                guard let self else { return }
                self.pushInFlight = false
                guard error == nil else { return }
                self.appliedPayload = pendingPayload
                #if DEBUG
                if let lastPayloadPushStartedAt = self.lastPayloadPushStartedAt {
                    let elapsedMs = Int(Date().timeIntervalSince(lastPayloadPushStartedAt) * 1000)
                    dlog(
                        "diff.webview.push.complete kind=\(update.kind) ms=\(elapsedMs) payloadBytes=\(update.encodedBytes)"
                    )
                }
                #endif
                self.pushPayloadIfPossible()
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxDiffPerf",
                  let payload = message.body as? [String: Any] else {
                return
            }

            #if DEBUG
            let type = payload["type"] as? String ?? "unknown"
            let mode = payload["mode"] as? String ?? "n/a"
            let totalFiles = payload["totalFiles"] as? Int ?? -1
            let visibleFiles = payload["visibleFiles"] as? Int ?? -1
            let durationMs = payload["durationMs"] as? Double ?? -1
            let messageText = payload["message"] as? String
            let path = payload["path"] as? String
            dlog(
                "diff.webview.render type=\(type) mode=\(mode) totalFiles=\(totalFiles) visibleFiles=\(visibleFiles) durationMs=\(String(format: "%.2f", durationMs)) path=\(path ?? "n/a") message=\(messageText ?? "n/a")"
            )
            #endif
        }
    }
}

private struct DiffPanelPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> DiffPanelPointerObserverView {
        let view = DiffPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: DiffPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class DiffPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard PaneFirstClickFocusSettings.isEnabled(),
              window?.isKeyWindow != true,
              bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }

    private func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        if PaneFirstClickFocusSettings.isEnabled(), window.isKeyWindow != true {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }
}
