import Foundation
import Bonsplit
#if canImport(libgit2)
import libgit2
#endif

@MainActor
final class DiffPanel: Panel, ObservableObject {
    struct FileEntry: Identifiable, Equatable, Sendable {
        let path: String
        let additions: Int
        let deletions: Int

        var id: String { path }
        var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
        var isBinary: Bool { additions == -1 && deletions == -1 }
    }

    struct CommitEntry: Identifiable, Equatable, Sendable {
        let sha: String
        let shortSHA: String
        let subject: String
        let relativeDate: String
        let author: String

        var id: String { sha }
    }

    struct SelectedFileDiff: Equatable, Sendable {
        private static let swiftRendererByteThreshold = 24_000

        let cacheKey: String
        let path: String
        let oldContent: String
        let newContent: String
        let isBinary: Bool
        let errorMessage: String?

        var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
        var totalByteCount: Int { oldContent.utf8.count + newContent.utf8.count }
        var shouldPreferFastRenderer: Bool { totalByteCount > Self.swiftRendererByteThreshold }
    }

    private struct WorkingTreeSnapshot {
        let repositoryRootPath: String
        let statusFingerprint: String
        let patch: String
        let files: [FileEntry]
        let treeNodes: [DiffPanelTreeNode]
        let filePatchesByPath: [String: String]
        let immediateWebViewPaths: Set<String>
        let precomputedFullPayloadsByIdentity: [String: DiffWebViewCachedFullPayload]
        let commits: [CommitEntry]
        let errorMessage: String?
    }

    private struct CommitSnapshot {
        let sha: String
        let patch: String
        let files: [FileEntry]
        let treeNodes: [DiffPanelTreeNode]
        let filePatchesByPath: [String: String]
        let immediateWebViewPaths: Set<String>
        let precomputedFullPayloadsByIdentity: [String: DiffWebViewCachedFullPayload]
        let errorMessage: String?
    }

    private struct CommandResult {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

    private struct CommandError: LocalizedError {
        let message: String?

        var errorDescription: String? { message }
    }

#if canImport(libgit2)
    private struct Libgit2Error: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }
#endif

    let id: UUID
    let panelType: PanelType = .diff
    let workspaceId: UUID
    private nonisolated(unsafe) var sourcePath: String

    @Published private(set) var repositoryRootPath: String
    @Published private(set) var patch: String = ""
    @Published private(set) var files: [FileEntry] = []
    @Published private(set) var unfilteredTreeNodes: [DiffPanelTreeNode] = []
    @Published private(set) var commits: [CommitEntry] = []
    @Published private(set) var selectedCommitSHA: String?
    @Published private(set) var selectedFilePath: String?
    @Published private(set) var isShowingAllFiles = true
    @Published private(set) var selectedFileDiff: SelectedFileDiff?
    @Published private(set) var isSelectedFileDiffLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoadedSnapshot = false
    @Published private(set) var isScopeLoading = false
    @Published private(set) var focusFlashToken: Int = 0

    var displayTitle: String {
        String(localized: "diffPanel.displayTitle", defaultValue: "Diff")
    }

    var displayIcon: String? { "arrow.triangle.branch" }

    var repositoryDisplayName: String {
        let trimmedPath = repositoryRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return displayTitle }
        return URL(fileURLWithPath: trimmedPath).lastPathComponent
    }

    var isShowingWorkingTree: Bool { selectedCommitSHA == nil }

    var currentTreeCacheKey: String {
        if let selectedCommitSHA {
            return "commit:\(selectedCommitSHA)"
        }
        return "working-tree:\(activeWorkingTreeStatusFingerprint)"
    }

    var selectedCommit: CommitEntry? {
        guard let selectedCommitSHA else { return nil }
        return commits.first(where: { $0.sha == selectedCommitSHA })
    }

    var scopeDisplayTitle: String {
        if let selectedCommit {
            return "\(selectedCommit.shortSHA) \(selectedCommit.subject)"
        }
        return String(localized: "diffPanel.scope.workingTree", defaultValue: "Working Tree")
    }

    private let pollQueue = DispatchQueue(label: "com.cmux.diff-panel-poll", qos: .utility)
    private let commitQueue = DispatchQueue(label: "com.cmux.diff-panel-commit", qos: .userInitiated)
    private let selectedFileQueue = DispatchQueue(label: "com.cmux.diff-panel-selected-file", qos: .userInitiated)
    private nonisolated(unsafe) var pollTimer: DispatchSourceTimer?
    private nonisolated(unsafe) var isClosed = false
    private nonisolated(unsafe) var refreshInFlight = false
    private nonisolated(unsafe) var refreshQueued = false
    private nonisolated(unsafe) var isPollingSuspendedForCommitSelection = false
    private nonisolated(unsafe) var cachedWorkingTreeStatusFingerprint = ""
    private nonisolated(unsafe) var cachedWorkingTreePatch = ""
    private nonisolated(unsafe) var cachedWorkingTreeFiles: [FileEntry] = []
    private nonisolated(unsafe) var cachedWorkingTreeTreeNodes: [DiffPanelTreeNode] = []
    private nonisolated(unsafe) var cachedWorkingTreeFilePatchesByPath: [String: String] = [:]
    private nonisolated(unsafe) var cachedWorkingTreeImmediateWebViewPaths: Set<String> = []
    private nonisolated(unsafe) var cachedWorkingTreePrecomputedFullPayloadsByIdentity: [String: DiffWebViewCachedFullPayload] = [:]
    private nonisolated(unsafe) var cachedWorkingTreeErrorMessage: String?
    private nonisolated(unsafe) var cachedCommits: [CommitEntry] = []
    private nonisolated(unsafe) var cachedRepositoryRootPath: String
    private nonisolated(unsafe) var commitSnapshotCache: [String: CommitSnapshot] = [:]
    private nonisolated(unsafe) var selectedFileDiffCache: [String: SelectedFileDiff] = [:]
    private var activeWorkingTreeStatusFingerprint = ""
    private(set) var currentScopeFilePatchesByPath: [String: String] = [:]
    private(set) var currentScopeImmediateWebViewPaths: Set<String> = []
    private(set) var currentScopePrecomputedFullPayloadsByIdentity: [String: DiffWebViewCachedFullPayload] = [:]
    private nonisolated(unsafe) var preferredWebViewIsDarkMode = false
    private var selectedFileLoadGeneration = 0
#if DEBUG
    private var latestCommitSelectionSHA: String?
    private var latestCommitSelectionStartedAt: Date?
#endif

    private nonisolated static let pollInterval: TimeInterval = 1.5
    private nonisolated static let commandTimeout: TimeInterval = 4.0
    private nonisolated static let maxCommitEntries = 40
    private nonisolated static let autoSelectFileThreshold = 8
#if canImport(libgit2)
    private nonisolated static let libgit2Bootstrap: Void = {
        _ = git_libgit2_init()
    }()
#endif

    init(workspaceId: UUID, repositoryRootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.sourcePath = repositoryRootPath
        self.repositoryRootPath = repositoryRootPath
        self.cachedRepositoryRootPath = repositoryRootPath

        startPolling()
        requestRefresh(forcePatch: true)
    }

    func focus() {
        // Diff panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        if let pollTimer {
            pollTimer.setEventHandler {}
            pollTimer.cancel()
            self.pollTimer = nil
        }
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func updateSourcePath(_ sourcePath: String) {
        guard self.sourcePath != sourcePath else { return }
        self.sourcePath = sourcePath
        repositoryRootPath = sourcePath
        patch = ""
        files = []
        unfilteredTreeNodes = []
        commits = []
        selectedCommitSHA = nil
        selectedFilePath = nil
        isShowingAllFiles = true
        selectedFileDiff = nil
        isSelectedFileDiffLoading = false
        errorMessage = nil
        hasLoadedSnapshot = false
        isScopeLoading = false
        isPollingSuspendedForCommitSelection = false
        activeWorkingTreeStatusFingerprint = ""
        currentScopeFilePatchesByPath = [:]
        currentScopeImmediateWebViewPaths = []
        currentScopePrecomputedFullPayloadsByIdentity = [:]
        cachedWorkingTreeStatusFingerprint = ""
        cachedWorkingTreePatch = ""
        cachedWorkingTreeFiles = []
        cachedWorkingTreeTreeNodes = []
        cachedWorkingTreeFilePatchesByPath = [:]
        cachedWorkingTreeImmediateWebViewPaths = []
        cachedWorkingTreePrecomputedFullPayloadsByIdentity = [:]
        cachedWorkingTreeErrorMessage = nil
        cachedCommits = []
        cachedRepositoryRootPath = sourcePath
        commitSnapshotCache = [:]
        selectedFileDiffCache = [:]
        requestRefresh(forcePatch: true)
    }

    func selectWorkingTree() {
        let hadCommitSelection = selectedCommitSHA != nil
#if DEBUG
        dlog(
            "diff.workingTree.select hadCommit=\(hadCommitSelection ? 1 : 0) cachedPatchBytes=\(cachedWorkingTreePatch.utf8.count) cachedFiles=\(cachedWorkingTreeFiles.count)"
        )
#endif
        isPollingSuspendedForCommitSelection = false
        selectedCommitSHA = nil
        isShowingAllFiles = true
        selectedFilePath = nil
        activeWorkingTreeStatusFingerprint = cachedWorkingTreeStatusFingerprint
        applyWorkingTreeSnapshotFromCache()
        requestRefresh(forcePatch: true)
    }

    func selectCommit(_ sha: String) {
        let normalizedSHA = Self.normalizedRevision(sha)
        guard !normalizedSHA.isEmpty else { return }
        guard selectedCommitSHA != normalizedSHA else { return }
#if DEBUG
        latestCommitSelectionSHA = normalizedSHA
        latestCommitSelectionStartedAt = Date()
        dlog("diff.commit.select sha=\(normalizedSHA) cached=\(commitSnapshotCache[normalizedSHA] != nil ? 1 : 0)")
#endif
        isPollingSuspendedForCommitSelection = true
        selectedCommitSHA = normalizedSHA
        isShowingAllFiles = true
        selectedFilePath = nil
        if let snapshot = commitSnapshotCache[normalizedSHA] {
            apply(commitSnapshot: snapshot)
            return
        }

        isScopeLoading = true
        let repositoryRoot = cachedRepositoryRootPath
        commitQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            let snapshotStart = Date()
#endif
            let snapshot = Self.commitSnapshot(
                repositoryRootPath: repositoryRoot,
                sha: normalizedSHA,
                preferredWebViewIsDarkMode: self.preferredWebViewIsDarkMode
            )
#if DEBUG
            let snapshotElapsedMs = Int(Date().timeIntervalSince(snapshotStart) * 1000)
            dlog(
                "diff.commit.snapshot sha=\(normalizedSHA) ms=\(snapshotElapsedMs) patchBytes=\(snapshot.patch.utf8.count) files=\(snapshot.files.count) error=\(snapshot.errorMessage == nil ? "0" : "1")"
            )
#endif
            self.commitSnapshotCache[normalizedSHA] = snapshot
            Task { @MainActor [weak self] in
                guard let self, self.selectedCommitSHA == normalizedSHA else { return }
                self.apply(commitSnapshot: snapshot)
            }
        }
    }

    func selectAllFiles() {
        guard !files.isEmpty else {
            selectedFilePath = nil
            selectedFileDiff = nil
            isSelectedFileDiffLoading = false
            return
        }
        isShowingAllFiles = true
        selectedFilePath = nil
        selectedFileDiff = nil
        isSelectedFileDiffLoading = false
    }

    func selectFile(_ path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        guard selectedFilePath != path else { return }
        isShowingAllFiles = false
        selectedFilePath = path
        selectedFileDiff = nil
        isSelectedFileDiffLoading = false
    }

    func setPreferredWebViewIsDarkMode(_ isDarkMode: Bool) {
        preferredWebViewIsDarkMode = isDarkMode
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval
        )
        timer.setEventHandler { [weak self] in
            self?.performRefresh(forcePatch: false)
        }
        timer.resume()
        pollTimer = timer
    }

    private func requestRefresh(forcePatch: Bool) {
        pollQueue.async { [weak self] in
            self?.performRefresh(forcePatch: forcePatch)
        }
    }

    private nonisolated func performRefresh(forcePatch: Bool) {
        guard !isClosed else { return }
        guard !isPollingSuspendedForCommitSelection else { return }

        if refreshInFlight {
            refreshQueued = true
            return
        }

        refreshInFlight = true
        let snapshot = Self.workingTreeSnapshot(
            for: sourcePath,
            previousStatusFingerprint: cachedWorkingTreeStatusFingerprint,
            previousPatch: cachedWorkingTreePatch,
            previousFiles: cachedWorkingTreeFiles,
            previousRepositoryRootPath: cachedRepositoryRootPath,
            preferredWebViewIsDarkMode: preferredWebViewIsDarkMode,
            forcePatch: forcePatch
        )
        cachedWorkingTreeStatusFingerprint = snapshot.statusFingerprint
        cachedWorkingTreePatch = snapshot.patch
        cachedWorkingTreeFiles = snapshot.files
        cachedWorkingTreeTreeNodes = snapshot.treeNodes
        cachedWorkingTreeFilePatchesByPath = snapshot.filePatchesByPath
        cachedWorkingTreeImmediateWebViewPaths = snapshot.immediateWebViewPaths
        cachedWorkingTreePrecomputedFullPayloadsByIdentity = snapshot.precomputedFullPayloadsByIdentity
        cachedWorkingTreeErrorMessage = snapshot.errorMessage
        cachedCommits = snapshot.commits
        cachedRepositoryRootPath = snapshot.repositoryRootPath

        Task { @MainActor [weak self] in
            self?.apply(workingTreeSnapshot: snapshot)
        }

        refreshInFlight = false
        if refreshQueued {
            refreshQueued = false
            performRefresh(forcePatch: false)
        }
    }

    private func apply(workingTreeSnapshot snapshot: WorkingTreeSnapshot) {
        guard !isClosed else { return }

        if repositoryRootPath != snapshot.repositoryRootPath {
            repositoryRootPath = snapshot.repositoryRootPath
        }
        activeWorkingTreeStatusFingerprint = snapshot.statusFingerprint
        if commits != snapshot.commits {
            commits = snapshot.commits
        }
        if !hasLoadedSnapshot {
            hasLoadedSnapshot = true
        }

        if let selectedCommitSHA, commits.contains(where: { $0.sha == selectedCommitSHA }) == false {
            self.selectedCommitSHA = nil
        }

        if isShowingWorkingTree {
            patch = snapshot.patch
            files = snapshot.files
            unfilteredTreeNodes = snapshot.treeNodes
            currentScopeFilePatchesByPath = snapshot.filePatchesByPath
            currentScopeImmediateWebViewPaths = snapshot.immediateWebViewPaths
            currentScopePrecomputedFullPayloadsByIdentity = snapshot.precomputedFullPayloadsByIdentity
            reconcileSelectedFilePath(with: snapshot.files)
            errorMessage = snapshot.errorMessage
            isScopeLoading = false
            refreshSelectedFileDiffIfNeeded(forceReload: false)
        }
    }

    private func apply(commitSnapshot snapshot: CommitSnapshot) {
        guard !isClosed else { return }
        guard selectedCommitSHA == snapshot.sha else { return }

        patch = snapshot.patch
        files = snapshot.files
        unfilteredTreeNodes = snapshot.treeNodes
        currentScopeFilePatchesByPath = snapshot.filePatchesByPath
        currentScopeImmediateWebViewPaths = snapshot.immediateWebViewPaths
        currentScopePrecomputedFullPayloadsByIdentity = snapshot.precomputedFullPayloadsByIdentity
        reconcileSelectedFilePath(with: snapshot.files)
        errorMessage = snapshot.errorMessage
        isScopeLoading = false
        if !hasLoadedSnapshot {
            hasLoadedSnapshot = true
        }
        refreshSelectedFileDiffIfNeeded(forceReload: false)
#if DEBUG
        let totalMs: Int
        if latestCommitSelectionSHA == snapshot.sha, let latestCommitSelectionStartedAt {
            totalMs = Int(Date().timeIntervalSince(latestCommitSelectionStartedAt) * 1000)
        } else {
            totalMs = -1
        }
        dlog(
            "diff.commit.apply sha=\(snapshot.sha) totalMs=\(totalMs) patchBytes=\(snapshot.patch.utf8.count) files=\(snapshot.files.count) error=\(snapshot.errorMessage == nil ? "0" : "1")"
        )
#endif
    }

    private func applyWorkingTreeSnapshotFromCache() {
        patch = cachedWorkingTreePatch
        files = cachedWorkingTreeFiles
        unfilteredTreeNodes = cachedWorkingTreeTreeNodes
        currentScopeFilePatchesByPath = cachedWorkingTreeFilePatchesByPath
        currentScopeImmediateWebViewPaths = cachedWorkingTreeImmediateWebViewPaths
        currentScopePrecomputedFullPayloadsByIdentity = cachedWorkingTreePrecomputedFullPayloadsByIdentity
        reconcileSelectedFilePath(with: cachedWorkingTreeFiles)
        errorMessage = cachedWorkingTreeErrorMessage
        refreshSelectedFileDiffIfNeeded(forceReload: false)
    }

    private func reconcileSelectedFilePath(with files: [FileEntry]) {
        guard !files.isEmpty else {
            selectedFilePath = nil
            isShowingAllFiles = true
            self.selectedFileDiff = nil
            self.isSelectedFileDiffLoading = false
            return
        }

        if isShowingAllFiles {
            selectedFilePath = nil
            self.selectedFileDiff = nil
            self.isSelectedFileDiffLoading = false
            return
        }

        guard let selectedFilePath else {
            self.selectedFilePath = Self.preferredDefaultSelectedFilePath(from: files)
            self.selectedFileDiff = nil
            self.isSelectedFileDiffLoading = false
            return
        }

        guard files.contains(where: { $0.path == selectedFilePath }) else {
            self.selectedFilePath = Self.preferredDefaultSelectedFilePath(from: files)
            self.selectedFileDiff = nil
            self.isSelectedFileDiffLoading = false
            return
        }
    }

    private func refreshSelectedFileDiffIfNeeded(forceReload: Bool) {
        _ = forceReload
        selectedFileDiff = nil
        isSelectedFileDiffLoading = false
    }

    func currentRenderPayload(isDarkMode: Bool) -> DiffWebViewRenderPayload? {
        guard hasLoadedSnapshot, !patch.isEmpty else { return nil }

        if isShowingAllFiles {
            // Build directly from the files array — no O(n²) linear search per file
            let renderedFiles: [DiffWebViewRenderableFile] = files.compactMap { fileEntry in
                let filePatch = currentScopeFilePatchesByPath[fileEntry.path]
                    ?? DiffPatchSelector.singleFilePatch(from: patch, selectedFilePath: fileEntry.path)
                return DiffWebViewFileBuilder.build(
                    fileEntry: DiffWebViewFileBuilder.FileInput(
                        path: fileEntry.path,
                        additions: fileEntry.additions,
                        deletions: fileEntry.deletions,
                        isBinary: fileEntry.isBinary
                    ),
                    filePatch: filePatch.isEmpty ? patch : filePatch
                )
            }
            guard !renderedFiles.isEmpty else { return nil }
            return DiffWebViewRenderPayload(
                files: renderedFiles,
                selectedFilePath: nil,
                isDarkMode: isDarkMode,
                cacheIdentity: "\(currentTreeCacheKey)|all-files"
            )
        }

        let resolvedSelectedFilePath = selectedFilePath ?? Self.preferredDefaultSelectedFilePath(from: files)
        guard let resolvedSelectedFilePath,
              let renderedFile = renderableFile(path: resolvedSelectedFilePath) else { return nil }

        return DiffWebViewRenderPayload(
            files: [renderedFile],
            selectedFilePath: resolvedSelectedFilePath,
            isDarkMode: isDarkMode,
            cacheIdentity: "\(currentTreeCacheKey)|file:\(resolvedSelectedFilePath)"
        )
    }

    private func renderableFile(path: String) -> DiffWebViewRenderableFile? {
        guard let fileEntry = files.first(where: { $0.path == path }) else { return nil }
        let selectedFilePatch = currentScopeFilePatchesByPath[path]
            ?? DiffPatchSelector.singleFilePatch(from: patch, selectedFilePath: path)
        return DiffWebViewFileBuilder.build(
            fileEntry: DiffWebViewFileBuilder.FileInput(
                path: fileEntry.path,
                additions: fileEntry.additions,
                deletions: fileEntry.deletions,
                isBinary: fileEntry.isBinary
            ),
            filePatch: selectedFilePatch.isEmpty ? patch : selectedFilePatch
        )
    }

    private func loadSelectedFileDiff(for path: String, forceReload: Bool) {
        guard let fileEntry = files.first(where: { $0.path == path }) else {
            selectedFileDiff = nil
            isSelectedFileDiffLoading = false
            return
        }

        let cacheKey = selectedFileDiffCacheKey(for: path)
        if fileEntry.isBinary {
            selectedFileDiff = SelectedFileDiff(
                cacheKey: cacheKey,
                path: path,
                oldContent: "",
                newContent: "",
                isBinary: true,
                errorMessage: nil
            )
            isSelectedFileDiffLoading = false
            return
        }

        if !forceReload, let selectedFileDiff, selectedFileDiff.cacheKey == cacheKey {
            isSelectedFileDiffLoading = false
            return
        }

        if !forceReload, let cachedSelectedFileDiff = selectedFileDiffCache[cacheKey] {
            selectedFileDiff = cachedSelectedFileDiff
            isSelectedFileDiffLoading = false
            return
        }

        selectedFileLoadGeneration &+= 1
        let generation = selectedFileLoadGeneration
        let repositoryRootPath = repositoryRootPath
        let selectedCommitSHA = selectedCommitSHA
        let workingTreeStatusFingerprint = selectedCommitSHA == nil ? activeWorkingTreeStatusFingerprint : nil
        isSelectedFileDiffLoading = true

        selectedFileQueue.async {
#if DEBUG
            let loadStartedAt = Date()
#endif
            let snapshot = Self.buildSelectedFileDiff(
                repositoryRootPath: repositoryRootPath,
                path: path,
                selectedCommitSHA: selectedCommitSHA,
                workingTreeStatusFingerprint: workingTreeStatusFingerprint
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.selectedFileLoadGeneration else { return }
                guard self.selectedFilePath == path else { return }
                guard snapshot.cacheKey == self.selectedFileDiffCacheKey(for: path) else { return }
                self.selectedFileDiffCache[snapshot.cacheKey] = snapshot
                self.selectedFileDiff = snapshot
                self.isSelectedFileDiffLoading = false
#if DEBUG
                let elapsedMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
                dlog(
                    "diff.selectedFile.apply path=\(path) commit=\(selectedCommitSHA ?? "working-tree") ms=\(elapsedMs) oldBytes=\(snapshot.oldContent.utf8.count) newBytes=\(snapshot.newContent.utf8.count) error=\(snapshot.errorMessage == nil ? "0" : "1")"
                )
#endif
            }
        }
    }

    private func selectedFileDiffCacheKey(for path: String) -> String {
        if let selectedCommitSHA {
            return "commit:\(selectedCommitSHA):\(path)"
        }
        return "working-tree:\(activeWorkingTreeStatusFingerprint):\(path)"
    }

    private nonisolated static func workingTreeSnapshot(
        for sourcePath: String,
        previousStatusFingerprint: String,
        previousPatch: String,
        previousFiles: [FileEntry],
        previousRepositoryRootPath: String,
        preferredWebViewIsDarkMode: Bool,
        forcePatch: Bool
    ) -> WorkingTreeSnapshot {
        let repositoryRootResolution = resolvedRepositoryRootResult(for: sourcePath)
        guard let repositoryRootResolution,
              !repositoryRootResolution.timedOut,
              repositoryRootResolution.executionError == nil,
              repositoryRootResolution.exitStatus == 0,
              let repositoryRootPath = repositoryRootResolution.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repositoryRootPath.isEmpty else {
            return WorkingTreeSnapshot(
                repositoryRootPath: previousRepositoryRootPath,
                statusFingerprint: "",
                patch: "",
                files: [],
                treeNodes: [],
                filePatchesByPath: [:],
                immediateWebViewPaths: [],
                precomputedFullPayloadsByIdentity: [:],
                commits: [],
                errorMessage: repositoryRootResolution?.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? repositoryRootResolution?.executionError
            )
        }

        let commits = recentCommitEntries(directory: repositoryRootPath)
        let statusResult = runGitCommandResult(
            directory: repositoryRootPath,
            arguments: ["status", "--porcelain=v1", "--untracked-files=all", "-z"]
        )
        guard let statusResult,
              !statusResult.timedOut,
              statusResult.executionError == nil,
              statusResult.exitStatus == 0 else {
            return WorkingTreeSnapshot(
                repositoryRootPath: repositoryRootPath,
                statusFingerprint: "",
                patch: "",
                files: [],
                treeNodes: [],
                filePatchesByPath: [:],
                immediateWebViewPaths: [],
                precomputedFullPayloadsByIdentity: [:],
                commits: commits,
                errorMessage: statusResult?.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let statusFingerprint = statusResult.stdout ?? ""
        if statusFingerprint.isEmpty {
            return WorkingTreeSnapshot(
                repositoryRootPath: repositoryRootPath,
                statusFingerprint: statusFingerprint,
                patch: "",
                files: [],
                treeNodes: [],
                filePatchesByPath: [:],
                immediateWebViewPaths: [],
                precomputedFullPayloadsByIdentity: [:],
                commits: commits,
                errorMessage: nil
            )
        }

        if !forcePatch,
           statusFingerprint == previousStatusFingerprint,
           repositoryRootPath == previousRepositoryRootPath {
            let patchIndex = DiffPatchSelector.index(from: previousPatch)
            let filePatchesByPath = patchIndex.patchesByPath
            let immediateWebViewPaths = patchIndex.immediateWebViewPaths
            return WorkingTreeSnapshot(
                repositoryRootPath: repositoryRootPath,
                statusFingerprint: statusFingerprint,
                patch: previousPatch,
                files: previousFiles,
                treeNodes: treeNodes(from: previousFiles),
                filePatchesByPath: filePatchesByPath,
                immediateWebViewPaths: immediateWebViewPaths,
                precomputedFullPayloadsByIdentity: precomputedFullPayloads(
                    scopeIdentity: "working-tree:\(statusFingerprint)",
                    patch: previousPatch,
                    selectedFilePath: nil,
                    orderedSelectedFilePaths: previousFiles.map(\.path),
                    filePatchesByPath: filePatchesByPath,
                    isDarkMode: preferredWebViewIsDarkMode
                ),
                commits: commits,
                errorMessage: nil
            )
        }

        do {
            let files = try workingTreeFiles(directory: repositoryRootPath)
            let patch = try buildPatch(repositoryRootPath: repositoryRootPath)
            let patchIndex = DiffPatchSelector.index(from: patch)
            let filePatchesByPath = patchIndex.patchesByPath
            let immediateWebViewPaths = patchIndex.immediateWebViewPaths
            return WorkingTreeSnapshot(
                repositoryRootPath: repositoryRootPath,
                statusFingerprint: statusFingerprint,
                patch: patch,
                files: files,
                treeNodes: treeNodes(from: files),
                filePatchesByPath: filePatchesByPath,
                immediateWebViewPaths: immediateWebViewPaths,
                precomputedFullPayloadsByIdentity: precomputedFullPayloads(
                    scopeIdentity: "working-tree:\(statusFingerprint)",
                    patch: patch,
                    selectedFilePath: nil,
                    orderedSelectedFilePaths: files.map(\.path),
                    filePatchesByPath: filePatchesByPath,
                    isDarkMode: preferredWebViewIsDarkMode
                ),
                commits: commits,
                errorMessage: nil
            )
        } catch {
            return WorkingTreeSnapshot(
                repositoryRootPath: repositoryRootPath,
                statusFingerprint: statusFingerprint,
                patch: "",
                files: [],
                treeNodes: [],
                filePatchesByPath: [:],
                immediateWebViewPaths: [],
                precomputedFullPayloadsByIdentity: [:],
                commits: commits,
                errorMessage: (error as? LocalizedError)?.errorDescription
            )
        }
    }

    private nonisolated static func commitSnapshot(
        repositoryRootPath: String,
        sha: String,
        preferredWebViewIsDarkMode: Bool
    ) -> CommitSnapshot {
        let normalizedSHA = normalizedRevision(sha)
#if canImport(libgit2)
        if let snapshot = try? libgit2CommitSnapshot(
            repositoryRootPath: repositoryRootPath,
            sha: normalizedSHA,
            preferredWebViewIsDarkMode: preferredWebViewIsDarkMode
        ) {
            return snapshot
        }
#endif
        return shellCommitSnapshot(
            repositoryRootPath: repositoryRootPath,
            sha: normalizedSHA,
            preferredWebViewIsDarkMode: preferredWebViewIsDarkMode
        )
    }

    private nonisolated static func shellCommitSnapshot(
        repositoryRootPath: String,
        sha: String,
        preferredWebViewIsDarkMode: Bool
    ) -> CommitSnapshot {
        let normalizedSHA = normalizedRevision(sha)
        do {
            let patch = try requiredGitOutput(
                directory: repositoryRootPath,
                arguments: [
                    "show",
                    "--no-ext-diff",
                    "--binary",
                    "--find-renames",
                    "--format=",
                    "--patch",
                    normalizedSHA,
                    "--",
                ],
                allowedExitStatuses: [0]
            )
            let files = fileEntries(fromPatch: patch)
            let patchIndex = DiffPatchSelector.index(from: patch)
            let filePatchesByPath = patchIndex.patchesByPath
            let immediateWebViewPaths = patchIndex.immediateWebViewPaths
            let defaultSelectedFilePath = preferredDefaultSelectedFilePath(from: files)
            return CommitSnapshot(
                sha: normalizedSHA,
                patch: patch,
                files: files,
                treeNodes: treeNodes(from: files),
                filePatchesByPath: filePatchesByPath,
                immediateWebViewPaths: immediateWebViewPaths,
                precomputedFullPayloadsByIdentity: precomputedFullPayloads(
                    scopeIdentity: "commit:\(normalizedSHA)",
                    patch: patch,
                    selectedFilePath: defaultSelectedFilePath,
                    orderedSelectedFilePaths: files.map(\.path),
                    filePatchesByPath: filePatchesByPath,
                    isDarkMode: preferredWebViewIsDarkMode
                ),
                errorMessage: nil
            )
        } catch {
            return CommitSnapshot(
                sha: normalizedSHA,
                patch: "",
                files: [],
                treeNodes: [],
                filePatchesByPath: [:],
                immediateWebViewPaths: [],
                precomputedFullPayloadsByIdentity: [:],
                errorMessage: (error as? LocalizedError)?.errorDescription
            )
        }
    }

#if canImport(libgit2)
    private nonisolated static func libgit2CommitSnapshot(
        repositoryRootPath: String,
        sha: String,
        preferredWebViewIsDarkMode: Bool
    ) throws -> CommitSnapshot {
        _ = libgit2Bootstrap

        var repositoryPointer: OpaquePointer?
        var commitPointer: OpaquePointer?
        var parentCommitPointer: OpaquePointer?
        var newTreePointer: OpaquePointer?
        var oldTreePointer: OpaquePointer?
        var diffPointer: OpaquePointer?

        defer {
            git_diff_free(diffPointer)
            git_tree_free(oldTreePointer)
            git_tree_free(newTreePointer)
            git_commit_free(parentCommitPointer)
            git_commit_free(commitPointer)
            git_repository_free(repositoryPointer)
        }

        try requireLibgit2(
            git_repository_open(&repositoryPointer, repositoryRootPath),
            operation: "Failed to open repository"
        )
        guard let repositoryPointer else {
            throw Libgit2Error(message: "Failed to open repository")
        }

        var commitOID = git_oid()
        try requireLibgit2(
            git_oid_fromstrp(&commitOID, sha),
            operation: "Failed to parse commit revision"
        )
        try requireLibgit2(
            git_commit_lookup(&commitPointer, repositoryPointer, &commitOID),
            operation: "Failed to load commit"
        )
        guard let commitPointer else {
            throw Libgit2Error(message: "Failed to load commit")
        }

        try requireLibgit2(
            git_commit_tree(&newTreePointer, commitPointer),
            operation: "Failed to load commit tree"
        )

        if git_commit_parentcount(commitPointer) > 0 {
            try requireLibgit2(
                git_commit_parent(&parentCommitPointer, commitPointer, 0),
                operation: "Failed to load parent commit"
            )

            if let parentCommitPointer {
                try requireLibgit2(
                    git_commit_tree(&oldTreePointer, parentCommitPointer),
                    operation: "Failed to load parent tree"
                )
            }
        }

        var diffOptions = git_diff_options()
        try requireLibgit2(
            git_diff_options_init(&diffOptions, UInt32(GIT_DIFF_OPTIONS_VERSION)),
            operation: "Failed to initialize diff options"
        )
        diffOptions.flags = GIT_DIFF_SHOW_BINARY.rawValue

        try requireLibgit2(
            git_diff_tree_to_tree(&diffPointer, repositoryPointer, oldTreePointer, newTreePointer, &diffOptions),
            operation: "Failed to build commit diff"
        )
        guard let diffPointer else {
            throw Libgit2Error(message: "Failed to build commit diff")
        }

        var findOptions = git_diff_find_options()
        if git_diff_find_options_init(&findOptions, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)) == 0 {
            findOptions.flags = GIT_DIFF_FIND_RENAMES.rawValue
            _ = git_diff_find_similar(diffPointer, &findOptions)
        }

        var patchBuffer = git_buf()
        defer { git_buf_dispose(&patchBuffer) }
        try requireLibgit2(
            git_diff_to_buf(&patchBuffer, diffPointer, GIT_DIFF_FORMAT_PATCH),
            operation: "Failed to render commit diff"
        )

        let patch = String(
            decoding: UnsafeRawBufferPointer(
                start: patchBuffer.ptr,
                count: patchBuffer.size
            ),
            as: UTF8.self
        )
        let files = fileEntries(fromLibgit2Diff: diffPointer)
        let patchIndex = DiffPatchSelector.index(from: patch)
        let filePatchesByPath = patchIndex.patchesByPath
        let immediateWebViewPaths = patchIndex.immediateWebViewPaths
        let defaultSelectedFilePath = preferredDefaultSelectedFilePath(from: files)
        return CommitSnapshot(
            sha: sha,
            patch: patch,
            files: files,
            treeNodes: treeNodes(from: files),
            filePatchesByPath: filePatchesByPath,
            immediateWebViewPaths: immediateWebViewPaths,
            precomputedFullPayloadsByIdentity: precomputedFullPayloads(
                scopeIdentity: "commit:\(sha)",
                patch: patch,
                selectedFilePath: defaultSelectedFilePath,
                orderedSelectedFilePaths: files.map(\.path),
                filePatchesByPath: filePatchesByPath,
                isDarkMode: preferredWebViewIsDarkMode
            ),
            errorMessage: nil
        )
    }

    private nonisolated static func requireLibgit2(
        _ result: Int32,
        operation: String
    ) throws {
        guard result == 0 else {
            let detail = libgit2LastErrorMessage()
            let message: String
            if let detail, !detail.isEmpty {
                message = "\(operation): \(detail)"
            } else {
                message = "\(operation) (\(result))"
            }
            throw Libgit2Error(message: message)
        }
    }

    private nonisolated static func libgit2LastErrorMessage() -> String? {
        guard let errorPointer = git_error_last(),
              let messagePointer = errorPointer.pointee.message else {
            return nil
        }
        return String(cString: messagePointer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func fileEntries(fromLibgit2Diff diffPointer: OpaquePointer) -> [FileEntry] {
        let deltaCount = git_diff_num_deltas(diffPointer)
        guard deltaCount > 0 else { return [] }

        var entries: [FileEntry] = []
        entries.reserveCapacity(deltaCount)

        for index in 0..<deltaCount {
            guard let deltaPointer = git_diff_get_delta(diffPointer, index) else { continue }
            let delta = deltaPointer.pointee
            guard let path = resolvedPatchPath(from: delta), !path.isEmpty else { continue }

            var patchPointer: OpaquePointer?
            defer { git_patch_free(patchPointer) }

            let patchResult = git_patch_from_diff(&patchPointer, diffPointer, index)
            if patchResult == 0, let patchPointer {
                var context = 0
                var additions = 0
                var deletions = 0
                let statsResult = git_patch_line_stats(
                    &context,
                    &additions,
                    &deletions,
                    patchPointer
                )

                if statsResult == 0 {
                    entries.append(
                        FileEntry(path: path, additions: additions, deletions: deletions)
                    )
                    continue
                }
            }

            entries.append(FileEntry(path: path, additions: -1, deletions: -1))
        }

        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private nonisolated static func resolvedPatchPath(from delta: git_diff_delta) -> String? {
        if delta.status == GIT_DELTA_DELETED {
            return delta.old_file.path.flatMap { String(cString: $0) }.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let newPath = delta.new_file.path.flatMap { String(cString: $0) }
        let oldPath = delta.old_file.path.flatMap { String(cString: $0) }
        return (newPath ?? oldPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
#endif

    private nonisolated static func resolvedRepositoryRootResult(for sourcePath: String) -> CommandResult? {
        runGitCommandResult(
            directory: sourcePath,
            arguments: ["rev-parse", "--show-toplevel"]
        )
    }

    private nonisolated static func buildPatch(repositoryRootPath: String) throws -> String {
        if hasResolvableHead(directory: repositoryRootPath) {
            return try buildPatchFromHead(repositoryRootPath: repositoryRootPath)
        }
        return try buildPatchForUnbornRepository(repositoryRootPath: repositoryRootPath)
    }

    private nonisolated static func buildPatchFromHead(repositoryRootPath: String) throws -> String {
        var sections: [String] = []

        let trackedDiff = try requiredGitOutput(
            directory: repositoryRootPath,
            arguments: ["diff", "--no-ext-diff", "--binary", "--find-renames", "HEAD", "--"],
            allowedExitStatuses: [0]
        )
        if !trackedDiff.isEmpty {
            sections.append(trackedDiff)
        }

        for path in try untrackedRepositoryPaths(directory: repositoryRootPath) {
            let output = try diffAgainstDevNull(
                directory: repositoryRootPath,
                repositoryRelativePath: path
            )
            if !output.isEmpty {
                sections.append(output)
            }
        }

        return sections.joined(separator: "\n")
    }

    private nonisolated static func buildPatchForUnbornRepository(repositoryRootPath: String) throws -> String {
        let trackedPaths = try repositoryPaths(
            directory: repositoryRootPath,
            arguments: ["ls-files", "-z"]
        )
        let untrackedPaths = try repositoryPaths(
            directory: repositoryRootPath,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        )
        let allPaths = Array(Set(trackedPaths + untrackedPaths)).sorted()

        var sections: [String] = []
        for path in allPaths {
            let output = try diffAgainstDevNull(
                directory: repositoryRootPath,
                repositoryRelativePath: path
            )
            if !output.isEmpty {
                sections.append(output)
            }
        }
        return sections.joined(separator: "\n")
    }

    private nonisolated static func hasResolvableHead(directory: String) -> Bool {
        let result = runGitCommandResult(
            directory: directory,
            arguments: ["rev-parse", "--verify", "HEAD"]
        )
        return result?.exitStatus == 0 && result?.timedOut == false && result?.executionError == nil
    }

    private nonisolated static func workingTreeFiles(directory: String) throws -> [FileEntry] {
        var statsByPath: [String: (Int, Int)] = [:]

        if hasResolvableHead(directory: directory) {
            statsByPath = try numstatEntries(
                directory: directory,
                arguments: ["diff", "--numstat", "-z", "HEAD", "--"]
            )
        } else {
            let paths = try repositoryPaths(
                directory: directory,
                arguments: ["ls-files", "-z"]
            )
            for path in paths {
                statsByPath[path] = (0, 0)
            }
        }

        let untrackedPaths = try repositoryPaths(
            directory: directory,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        )
        for path in untrackedPaths where statsByPath[path] == nil {
            let lineCount = countFileLines(directory: directory, relativePath: path)
            statsByPath[path] = (lineCount, 0)
        }

        return statsByPath.keys.sorted().map { path in
            let stats = statsByPath[path] ?? (0, 0)
            return FileEntry(path: path, additions: stats.0, deletions: stats.1)
        }
    }

    private nonisolated static func numstatEntries(
        directory: String,
        arguments: [String]
    ) throws -> [String: (Int, Int)] {
        let output = try requiredGitOutput(
            directory: directory,
            arguments: arguments,
            allowedExitStatuses: [0]
        )
        guard !output.isEmpty else { return [:] }

        // --numstat -z format per non-renamed file: "add\tdel\tpath\0"
        // --numstat -z format per renamed file:     "add\tdel\t\0oldpath\0newpath\0"
        // Binary files use "-" for both counts.
        var result: [String: (Int, Int)] = [:]
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < parts.count {
            let statLine = parts[i]
            let columns = statLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3 else {
                i += 1
                continue
            }

            let add = Int(columns[0]) ?? -1
            let del = Int(columns[1]) ?? -1
            let pathField = columns[2].trimmingCharacters(in: .whitespacesAndNewlines)

            if pathField.isEmpty {
                // Renamed file: old and new paths follow as next two NUL fields
                i += 1 // old path
                i += 1 // new path — use as the current name
                if i < parts.count {
                    let newPath = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !newPath.isEmpty {
                        result[newPath] = (add, del)
                    }
                }
            } else {
                result[pathField] = (add, del)
            }

            i += 1
        }
        return result
    }

    private nonisolated static func fileEntries(fromPatch patch: String) -> [FileEntry] {
        guard !patch.isEmpty else { return [] }

        struct PatchAccumulator {
            var path: String?
            var additions = 0
            var deletions = 0
            var isBinary = false
        }

        func normalizedPatchPath(_ rawPath: String) -> String {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "/dev/null" { return trimmed }
            if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
                return String(trimmed.dropFirst(2))
            }
            return trimmed
        }

        func resolvedPath(from accumulator: PatchAccumulator) -> String? {
            guard let path = accumulator.path, !path.isEmpty, path != "/dev/null" else { return nil }
            return path
        }

        func finalize(_ accumulator: PatchAccumulator, into entries: inout [FileEntry]) {
            guard let path = resolvedPath(from: accumulator) else { return }
            let additions = accumulator.isBinary ? -1 : accumulator.additions
            let deletions = accumulator.isBinary ? -1 : accumulator.deletions
            entries.append(FileEntry(path: path, additions: additions, deletions: deletions))
        }

        var entries: [FileEntry] = []
        var current = PatchAccumulator()

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let stringLine = String(line)

            if stringLine.hasPrefix("diff --git ") {
                finalize(current, into: &entries)
                current = PatchAccumulator()

                let parts = stringLine.split(separator: " ", omittingEmptySubsequences: false)
                if parts.count >= 4 {
                    let oldPath = normalizedPatchPath(String(parts[2]))
                    let newPath = normalizedPatchPath(String(parts[3]))
                    current.path = newPath == "/dev/null" ? oldPath : newPath
                }
                continue
            }

            if stringLine.hasPrefix("+++ ") {
                let candidate = normalizedPatchPath(String(stringLine.dropFirst(4)))
                if candidate != "/dev/null" {
                    current.path = candidate
                }
                continue
            }

            if stringLine.hasPrefix("rename to ") {
                current.path = normalizedPatchPath(String(stringLine.dropFirst("rename to ".count)))
                continue
            }

            if stringLine.hasPrefix("Binary files ") || stringLine == "GIT binary patch" {
                current.isBinary = true
                continue
            }

            if stringLine.hasPrefix("+"), !stringLine.hasPrefix("+++") {
                current.additions += 1
                continue
            }

            if stringLine.hasPrefix("-"), !stringLine.hasPrefix("---") {
                current.deletions += 1
            }
        }

        finalize(current, into: &entries)
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private nonisolated static func countFileLines(directory: String, relativePath: String) -> Int {
        let fullPath = (directory as NSString).appendingPathComponent(relativePath)
        guard let data = FileManager.default.contents(atPath: fullPath),
              let content = String(data: data, encoding: .utf8) else {
            return 0
        }
        guard !content.isEmpty else { return 0 }
        return content.components(separatedBy: "\n").count - (content.hasSuffix("\n") ? 1 : 0)
    }

    private nonisolated static func recentCommitEntries(directory: String) -> [CommitEntry] {
        guard hasResolvableHead(directory: directory) else { return [] }

        guard let output = try? requiredGitOutput(
            directory: directory,
            arguments: [
                "log",
                "--date=relative",
                "--pretty=format:%H%x00%h%x00%s%x00%cr%x00%an%x00",
                "-n",
                String(Self.maxCommitEntries),
                "--",
            ],
            allowedExitStatuses: [0]
        ) else {
            return []
        }

        let fields = output
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        var entries: [CommitEntry] = []
        var index = 0
        while index + 4 < fields.count {
            let sha = normalizedRevision(fields[index])
            let shortSHA = normalizedRevision(fields[index + 1])
            let subject = fields[index + 2].trimmingCharacters(in: .newlines)
            let relativeDate = fields[index + 3].trimmingCharacters(in: .newlines)
            let author = fields[index + 4].trimmingCharacters(in: .newlines)
            index += 5

            guard !sha.isEmpty else { continue }
            entries.append(
                CommitEntry(
                    sha: sha,
                    shortSHA: shortSHA,
                    subject: subject,
                    relativeDate: relativeDate,
                    author: author
                )
            )
        }
        return entries
    }

    private nonisolated static func normalizedRevision(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private nonisolated static func treeNodes(from files: [FileEntry]) -> [DiffPanelTreeNode] {
        DiffPanelTreeBuilder.build(
            from: files.map {
                DiffPanelTreeFile(
                    path: $0.path,
                    fileName: $0.displayName,
                    additions: $0.additions,
                    deletions: $0.deletions
                )
            }
        )
    }

    private nonisolated static func precomputedFullPayloads(
        scopeIdentity: String,
        patch: String,
        selectedFilePath: String?,
        orderedSelectedFilePaths: [String],
        filePatchesByPath: [String: String],
        isDarkMode: Bool
    ) -> [String: DiffWebViewCachedFullPayload] {
        _ = scopeIdentity
        _ = patch
        _ = selectedFilePath
        _ = orderedSelectedFilePaths
        _ = filePatchesByPath
        _ = isDarkMode
        return [:]
    }

    private nonisolated static func preferredDefaultSelectedFilePath(from files: [FileEntry]) -> String? {
        preferredSelectedFilePaths(from: files, limit: 1).first
    }

    private nonisolated static func preferredSelectedFilePaths(
        from files: [FileEntry],
        limit: Int
    ) -> [String] {
        files
            .sorted { lhs, rhs in
                let lhsMagnitude = max(0, lhs.additions) + max(0, lhs.deletions)
                let rhsMagnitude = max(0, rhs.additions) + max(0, rhs.deletions)
                if lhsMagnitude != rhsMagnitude {
                    return lhsMagnitude > rhsMagnitude
                }
                if lhs.isBinary != rhs.isBinary {
                    return !lhs.isBinary
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .prefix(limit)
            .map(\.path)
    }

    private nonisolated static func buildSelectedFileDiff(
        repositoryRootPath: String,
        path: String,
        selectedCommitSHA: String?,
        workingTreeStatusFingerprint: String?
    ) -> SelectedFileDiff {
        let cacheKey: String
        if let selectedCommitSHA {
            cacheKey = "commit:\(selectedCommitSHA):\(path)"
            return selectedCommitFileDiff(
                repositoryRootPath: repositoryRootPath,
                path: path,
                sha: selectedCommitSHA,
                cacheKey: cacheKey
            )
        }

        cacheKey = "working-tree:\(workingTreeStatusFingerprint ?? ""):\(path)"
        return workingTreeFileDiff(
            repositoryRootPath: repositoryRootPath,
            path: path,
            cacheKey: cacheKey
        )
    }

    private nonisolated static func selectedCommitFileDiff(
        repositoryRootPath: String,
        path: String,
        sha: String,
        cacheKey: String
    ) -> SelectedFileDiff {
        let normalizedSHA = normalizedRevision(sha)
#if canImport(libgit2)
        if let snapshot = try? libgit2SelectedCommitFileDiff(
            repositoryRootPath: repositoryRootPath,
            path: path,
            sha: normalizedSHA,
            cacheKey: cacheKey
        ) {
            return snapshot
        }
#endif
        do {
            let parentRevision = firstParentRevision(
                directory: repositoryRootPath,
                revision: normalizedSHA
            )
            let oldContent = try gitFileContentIfPresent(
                directory: repositoryRootPath,
                revision: parentRevision,
                path: path
            ) ?? ""
            let newContent = try gitFileContentIfPresent(
                directory: repositoryRootPath,
                revision: normalizedSHA,
                path: path
            ) ?? ""
            return SelectedFileDiff(
                cacheKey: cacheKey,
                path: path,
                oldContent: oldContent,
                newContent: newContent,
                isBinary: false,
                errorMessage: nil
            )
        } catch {
            return SelectedFileDiff(
                cacheKey: cacheKey,
                path: path,
                oldContent: "",
                newContent: "",
                isBinary: false,
                errorMessage: (error as? LocalizedError)?.errorDescription
            )
        }
    }

#if canImport(libgit2)
    private nonisolated static func libgit2SelectedCommitFileDiff(
        repositoryRootPath: String,
        path: String,
        sha: String,
        cacheKey: String
    ) throws -> SelectedFileDiff {
        _ = libgit2Bootstrap

        var repositoryPointer: OpaquePointer?
        var commitPointer: OpaquePointer?
        var parentCommitPointer: OpaquePointer?
        var newTreePointer: OpaquePointer?
        var oldTreePointer: OpaquePointer?

        defer {
            git_tree_free(oldTreePointer)
            git_tree_free(newTreePointer)
            git_commit_free(parentCommitPointer)
            git_commit_free(commitPointer)
            git_repository_free(repositoryPointer)
        }

        try requireLibgit2(
            git_repository_open(&repositoryPointer, repositoryRootPath),
            operation: "Failed to open repository"
        )
        guard let repositoryPointer else {
            throw Libgit2Error(message: "Failed to open repository")
        }

        var commitOID = git_oid()
        try requireLibgit2(
            git_oid_fromstrp(&commitOID, sha),
            operation: "Failed to parse commit revision"
        )
        try requireLibgit2(
            git_commit_lookup(&commitPointer, repositoryPointer, &commitOID),
            operation: "Failed to load commit"
        )
        guard let commitPointer else {
            throw Libgit2Error(message: "Failed to load commit")
        }

        try requireLibgit2(
            git_commit_tree(&newTreePointer, commitPointer),
            operation: "Failed to load commit tree"
        )

        if git_commit_parentcount(commitPointer) > 0 {
            try requireLibgit2(
                git_commit_parent(&parentCommitPointer, commitPointer, 0),
                operation: "Failed to load parent commit"
            )

            if let parentCommitPointer {
                try requireLibgit2(
                    git_commit_tree(&oldTreePointer, parentCommitPointer),
                    operation: "Failed to load parent tree"
                )
            }
        }

        let oldContent = try libgit2BlobContentIfPresent(
            repositoryPointer: repositoryPointer,
            treePointer: oldTreePointer,
            path: path
        ) ?? ""
        let newContent = try libgit2BlobContentIfPresent(
            repositoryPointer: repositoryPointer,
            treePointer: newTreePointer,
            path: path
        ) ?? ""

        return SelectedFileDiff(
            cacheKey: cacheKey,
            path: path,
            oldContent: oldContent,
            newContent: newContent,
            isBinary: false,
            errorMessage: nil
        )
    }

    private nonisolated static func libgit2BlobContentIfPresent(
        repositoryPointer: OpaquePointer,
        treePointer: OpaquePointer?,
        path: String
    ) throws -> String? {
        guard let treePointer else { return nil }

        var treeEntryPointer: OpaquePointer?
        let entryResult = git_tree_entry_bypath(&treeEntryPointer, treePointer, path)
        if entryResult == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try requireLibgit2(
            entryResult,
            operation: "Failed to resolve file in tree"
        )
        guard let treeEntryPointer else { return nil }
        defer { git_tree_entry_free(treeEntryPointer) }

        var blobPointer: OpaquePointer?
        defer { git_blob_free(blobPointer) }
        try requireLibgit2(
            git_blob_lookup(&blobPointer, repositoryPointer, git_tree_entry_id(treeEntryPointer)),
            operation: "Failed to load file blob"
        )
        guard let blobPointer else { return nil }

        let rawSize = git_blob_rawsize(blobPointer)
        guard rawSize > 0 else { return "" }
        guard let rawContent = git_blob_rawcontent(blobPointer) else { return "" }

        return String(
            decoding: UnsafeRawBufferPointer(
                start: rawContent,
                count: Int(rawSize)
            ),
            as: UTF8.self
        )
    }
#endif

    private nonisolated static func workingTreeFileDiff(
        repositoryRootPath: String,
        path: String,
        cacheKey: String
    ) -> SelectedFileDiff {
        do {
            let oldContent: String
            if hasResolvableHead(directory: repositoryRootPath) {
                oldContent = try gitFileContentIfPresent(
                    directory: repositoryRootPath,
                    revision: "HEAD",
                    path: path
                ) ?? ""
            } else {
                oldContent = ""
            }

            let newContent = try fileContentIfPresent(
                directory: repositoryRootPath,
                relativePath: path
            ) ?? ""

            return SelectedFileDiff(
                cacheKey: cacheKey,
                path: path,
                oldContent: oldContent,
                newContent: newContent,
                isBinary: false,
                errorMessage: nil
            )
        } catch {
            return SelectedFileDiff(
                cacheKey: cacheKey,
                path: path,
                oldContent: "",
                newContent: "",
                isBinary: false,
                errorMessage: (error as? LocalizedError)?.errorDescription
            )
        }
    }

    private nonisolated static func untrackedRepositoryPaths(directory: String) throws -> [String] {
        try repositoryPaths(
            directory: directory,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        )
    }

    private nonisolated static func firstParentRevision(
        directory: String,
        revision: String
    ) -> String? {
        let result = runGitCommandResult(
            directory: directory,
            arguments: ["rev-parse", "--verify", "-q", "\(revision)^"]
        )
        guard result?.timedOut == false,
              result?.executionError == nil,
              result?.exitStatus == 0,
              let stdout = result?.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stdout.isEmpty else {
            return nil
        }
        return stdout
    }

    private nonisolated static func gitFileContentIfPresent(
        directory: String,
        revision: String?,
        path: String
    ) throws -> String? {
        guard let revision else { return nil }

        let result = runGitCommandResult(
            directory: directory,
            arguments: ["show", "\(revision):\(path)"]
        )
        if result?.timedOut == true {
            throw CommandError(message: nil)
        }
        if let executionError = result?.executionError {
            throw CommandError(message: executionError)
        }
        guard let result else {
            throw CommandError(message: nil)
        }
        if result.exitStatus == 0 {
            return result.stdout ?? ""
        }
        let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stderr.contains("exists on disk, but not in"),
           stderr.contains(path) {
            return nil
        }
        if stderr.contains("does not exist in"),
           stderr.contains(path) {
            return nil
        }
        if stderr.contains("invalid object name") {
            return nil
        }
        throw CommandError(message: stderr.isEmpty ? nil : stderr)
    }

    private nonisolated static func fileContentIfPresent(
        directory: String,
        relativePath: String
    ) throws -> String? {
        let fileURL = URL(fileURLWithPath: directory)
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func repositoryPaths(
        directory: String,
        arguments: [String]
    ) throws -> [String] {
        let output = try requiredGitOutput(
            directory: directory,
            arguments: arguments,
            allowedExitStatuses: [0]
        )
        guard !output.isEmpty else { return [] }

        return output
            .split(separator: "\0")
            .map(String.init)
            .filter { !$0.isEmpty }
    }



    private nonisolated static func diffAgainstDevNull(
        directory: String,
        repositoryRelativePath: String
    ) throws -> String {
        try requiredGitOutput(
            directory: directory,
            arguments: ["diff", "--no-index", "--binary", "--", "/dev/null", repositoryRelativePath],
            allowedExitStatuses: [0, 1]
        )
    }

    private nonisolated static func requiredGitOutput(
        directory: String,
        arguments: [String],
        allowedExitStatuses: Set<Int32>
    ) throws -> String {
        guard let result = runGitCommandResult(directory: directory, arguments: arguments) else {
            throw CommandError(message: nil)
        }
        if result.timedOut {
            throw CommandError(message: nil)
        }
        if let executionError = result.executionError {
            throw CommandError(message: executionError)
        }
        guard let exitStatus = result.exitStatus,
              allowedExitStatuses.contains(exitStatus) else {
            let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CommandError(message: stderr.isEmpty ? nil : stderr)
        }
        return result.stdout ?? ""
    }

    private nonisolated static func runGitCommandResult(
        directory: String,
        arguments: [String]
    ) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: String(describing: error)
            )
        }

        if completion.wait(timeout: .now() + Self.commandTimeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            stdout: String(data: stdoutData, encoding: .utf8),
            stderr: String(data: stderrData, encoding: .utf8),
            exitStatus: process.terminationStatus,
            timedOut: false,
            executionError: nil
        )
    }

    deinit {
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
    }
}
