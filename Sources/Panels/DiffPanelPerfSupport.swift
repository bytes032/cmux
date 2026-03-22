import Foundation

struct DiffPanelTreeFile: Equatable, Sendable {
    let path: String
    let fileName: String
    let pathComponents: [String]
    let pathPrefixes: [String]
    let searchPath: String
    let searchFileName: String
    let additions: Int
    let deletions: Int

    init(path: String, fileName: String? = nil, additions: Int, deletions: Int) {
        let resolvedFileName = fileName ?? (path as NSString).lastPathComponent
        let components = path.split(separator: "/").map(String.init)
        var prefixes: [String] = []
        prefixes.reserveCapacity(components.count)
        var currentPath = ""
        for component in components {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            prefixes.append(currentPath)
        }

        self.path = path
        self.fileName = resolvedFileName
        self.pathComponents = components
        self.pathPrefixes = prefixes
        self.searchPath = path.localizedLowercase
        self.searchFileName = resolvedFileName.localizedLowercase
        self.additions = additions
        self.deletions = deletions
    }
}

struct DiffPanelTreeNode: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fullPath: String?
    let additions: Int
    let deletions: Int
    let fileCount: Int
    let children: [DiffPanelTreeNode]

    var isDirectory: Bool { fullPath == nil }
    var isBinary: Bool { additions == -1 && deletions == -1 }
}

final class DiffPanelTreeContext {
    private var cache: [String: [DiffPanelTreeNode]] = [:]

    func nodes(for files: [DiffPanelTreeFile], cacheKey: String) -> [DiffPanelTreeNode] {
        if let cached = cache[cacheKey] {
            return cached
        }

        let nodes = DiffPanelTreeBuilder.build(from: files)
        cache[cacheKey] = nodes
        return nodes
    }
}

final class DiffSelectedFileWebPayloadContext {
    func payload(
        scopePatch: String,
        scopeIdentity: String,
        selectedFilePath: String,
        isDarkMode: Bool
    ) -> DiffWebViewRenderPayload {
        _ = scopePatch
        return DiffWebViewRenderPayload(
            files: [],
            selectedFilePath: selectedFilePath,
            isDarkMode: isDarkMode,
            cacheIdentity: "\(scopeIdentity)|file:\(selectedFilePath)"
        )
    }
}

enum DiffPatchSelector {
    static func singleFilePatch(
        from patch: String,
        selectedFilePath: String
    ) -> String {
        filePatchesByPath(from: patch)[selectedFilePath] ?? ""
    }

    static func filePatchesByPath(from patch: String) -> [String: String] {
        guard !patch.isEmpty else { return [:] }

        var patchesByPath: [String: String] = [:]
        var currentPath: String?
        var currentSectionStart: String.Index?

        func flushCurrentSection(until endIndex: String.Index) {
            guard let currentPath, let currentSectionStart, currentSectionStart < endIndex else { return }
            patchesByPath[currentPath] = String(patch[currentSectionStart..<endIndex])
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flushCurrentSection(until: line.startIndex)
                currentPath = diffHeaderPath(line)
                currentSectionStart = line.startIndex
            }
        }

        if let currentSectionStart, currentPath != nil {
            patchesByPath[currentPath!] = String(patch[currentSectionStart..<patch.endIndex])
        }
        return patchesByPath
    }

    fileprivate static func diffHeaderPath<S: StringProtocol>(_ line: S) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let oldPath = normalizePatchPath(String(parts[2]))
        let newPath = normalizePatchPath(String(parts[3]))
        return newPath.isEmpty ? oldPath : newPath
    }

    fileprivate static func normalizePatchPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }
}

enum DiffPatchRenderProxy {
    static func selectedFileRenderWork(
        patch: String,
        selectedFilePath: String?
    ) -> Int {
        guard !patch.isEmpty else { return 0 }
        guard let selectedFilePath else { return patch.utf8.count }

        let normalizedTarget = DiffPatchSelector.normalizePatchPath(selectedFilePath)
        var currentPath: String?
        var currentBytes = 0
        var matchedBytes = 0

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let stringLine = String(line)
            if stringLine.hasPrefix("diff --git ") {
                if currentPath == normalizedTarget {
                    matchedBytes += currentBytes
                }
                currentPath = DiffPatchSelector.diffHeaderPath(stringLine)
                currentBytes = stringLine.utf8.count + 1
            } else {
                currentBytes += stringLine.utf8.count + 1
            }
        }

        if currentPath == normalizedTarget {
            matchedBytes += currentBytes
        }

        return matchedBytes
    }
}

enum DiffSelectedFileRouteDecider {
    static let fastRendererByteThreshold = 24_000

    static func shouldPreferFastRenderer(filePatch: String) -> Bool {
        guard !filePatch.isEmpty else { return false }

        var totalContentBytes = 0
        for line in filePatch.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let marker = line.first else { continue }
            switch marker {
            case "+":
                if !line.hasPrefix("+++") {
                    totalContentBytes += line.utf8.count - 1
                }
            case "-":
                if !line.hasPrefix("---") {
                    totalContentBytes += line.utf8.count - 1
                }
            default:
                continue
            }

            if totalContentBytes > fastRendererByteThreshold {
                return true
            }
        }

        return false
    }
}

enum DiffPanelTreeBuilder {
    private final class BuilderNode {
        let id: String
        let name: String
        var fullPath: String?
        var additions: Int = 0
        var deletions: Int = 0
        var fileCount: Int = 0
        var children: [String: BuilderNode] = [:]

        init(id: String, name: String, fullPath: String? = nil) {
            self.id = id
            self.name = name
            self.fullPath = fullPath
        }
    }

    static func build(from files: [DiffPanelTreeFile]) -> [DiffPanelTreeNode] {
        let root = BuilderNode(id: "", name: "")

        for file in files {
            let components = file.pathComponents
            guard !components.isEmpty else { continue }

            let fileAdditions = max(0, file.additions)
            let fileDeletions = max(0, file.deletions)
            var currentNode = root

            for (index, component) in components.enumerated() {
                let currentPath = file.pathPrefixes[index]
                let isLeaf = index == components.count - 1

                if let existing = currentNode.children[component] {
                    currentNode = existing
                } else {
                    let child = BuilderNode(
                        id: currentPath,
                        name: component,
                        fullPath: isLeaf ? file.path : nil
                    )
                    currentNode.children[component] = child
                    currentNode = child
                }

                if isLeaf {
                    currentNode.fullPath = file.path
                    currentNode.additions = file.additions
                    currentNode.deletions = file.deletions
                    currentNode.fileCount = 1
                } else {
                    currentNode.additions += fileAdditions
                    currentNode.deletions += fileDeletions
                    currentNode.fileCount += 1
                }
            }
        }

        return makeNodes(from: root)
    }

    private static func makeNodes(from builder: BuilderNode) -> [DiffPanelTreeNode] {
        builder.children.values
            .sorted { lhs, rhs in
                if lhs.fullPath == nil, rhs.fullPath != nil {
                    return true
                }
                if lhs.fullPath != nil, rhs.fullPath == nil {
                    return false
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { child -> DiffPanelTreeNode in
                var childNodes = makeNodes(from: child)
                var displayName = child.name
                var nodeID = child.id

                if child.fullPath == nil {
                    while childNodes.count == 1, let only = childNodes.first, only.isDirectory {
                        displayName = "\(displayName)/\(only.name)"
                        nodeID = only.id
                        childNodes = only.children
                    }
                }

                return DiffPanelTreeNode(
                    id: nodeID,
                    name: displayName,
                    fullPath: child.fullPath,
                    additions: child.additions,
                    deletions: child.deletions,
                    fileCount: child.fileCount,
                    children: childNodes
                )
            }
    }
}

struct DiffWebViewCachedFullPayload: Equatable, Sendable {
    let cacheIdentity: String
    let javaScript: String
    let encodedBytes: Int
}

struct DiffWebViewRenderableLine: Encodable, Equatable, Sendable {
    let kind: String
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let isNoNewlineMarker: Bool
}

struct DiffWebViewRenderableHunk: Encodable, Equatable, Sendable {
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffWebViewRenderableLine]
}

struct DiffWebViewRenderableFile: Encodable, Equatable, Sendable {
    let path: String
    let oldPath: String?
    let newPath: String?
    let displayPath: String
    let language: String
    let changeType: String
    let isBinary: Bool
    let additions: Int
    let deletions: Int
    let hunks: [DiffWebViewRenderableHunk]
}

struct DiffWebViewRenderPayload: Encodable, Equatable, Sendable {
    let files: [DiffWebViewRenderableFile]
    let selectedFilePath: String?
    let isDarkMode: Bool
    let cacheIdentity: String
    let precomputedFullPayload: DiffWebViewCachedFullPayload?

    init(
        files: [DiffWebViewRenderableFile],
        selectedFilePath: String?,
        isDarkMode: Bool,
        cacheIdentity: String,
        precomputedFullPayload: DiffWebViewCachedFullPayload? = nil
    ) {
        self.files = files
        self.selectedFilePath = selectedFilePath
        self.isDarkMode = isDarkMode
        self.cacheIdentity = cacheIdentity
        self.precomputedFullPayload = precomputedFullPayload
    }

    private enum CodingKeys: String, CodingKey {
        case files
        case selectedFilePath
        case isDarkMode
    }
}

struct DiffWebViewJavaScriptUpdate: Equatable, Sendable {
    let kind: String
    let javaScript: String
    let encodedBytes: Int
}

enum DiffWebViewLanguageResolver {
    static func languageHint(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "ts":
            return "typescript"
        case "tsx":
            return "tsx"
        case "js", "mjs", "cjs":
            return "javascript"
        case "jsx":
            return "jsx"
        case "json":
            return "json"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "go":
            return "go"
        case "rs":
            return "rust"
        case "java":
            return "java"
        case "kt", "kts":
            return "kotlin"
        case "c", "h":
            return "c"
        case "cc", "cpp", "cxx", "hpp":
            return "cpp"
        case "sh", "bash", "zsh":
            return "shell"
        case "yml", "yaml":
            return "yaml"
        case "toml":
            return "toml"
        case "html", "htm":
            return "html"
        case "css":
            return "css"
        case "scss":
            return "scss"
        case "md":
            return "markdown"
        default:
            return "plain"
        }
    }
}

enum DiffWebViewFileBuilder {
    private struct HunkBuilder {
        let header: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        var nextOldLine: Int
        var nextNewLine: Int
        var lines: [DiffWebViewRenderableLine]

        init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
            self.header = header
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.nextOldLine = oldStart
            self.nextNewLine = newStart
            self.lines = []
        }

        mutating func appendContextLine(_ text: String) {
            lines.append(
                DiffWebViewRenderableLine(
                    kind: "context",
                    text: text,
                    oldLineNumber: nextOldLine,
                    newLineNumber: nextNewLine,
                    isNoNewlineMarker: false
                )
            )
            nextOldLine += 1
            nextNewLine += 1
        }

        mutating func appendDeletionLine(_ text: String) {
            lines.append(
                DiffWebViewRenderableLine(
                    kind: "deletion",
                    text: text,
                    oldLineNumber: nextOldLine,
                    newLineNumber: nil,
                    isNoNewlineMarker: false
                )
            )
            nextOldLine += 1
        }

        mutating func appendAdditionLine(_ text: String) {
            lines.append(
                DiffWebViewRenderableLine(
                    kind: "addition",
                    text: text,
                    oldLineNumber: nil,
                    newLineNumber: nextNewLine,
                    isNoNewlineMarker: false
                )
            )
            nextNewLine += 1
        }

        mutating func appendNoNewlineMarker(_ text: String) {
            lines.append(
                DiffWebViewRenderableLine(
                    kind: "note",
                    text: text,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    isNoNewlineMarker: true
                )
            )
        }

        func build() -> DiffWebViewRenderableHunk {
            DiffWebViewRenderableHunk(
                header: header,
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: lines
            )
        }
    }

    private static let hunkHeaderRegex = try? NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#,
        options: []
    )

    static func build(
        fileEntry: DiffPanel.FileEntry,
        filePatch: String
    ) -> DiffWebViewRenderableFile {
        var oldPath: String?
        var newPath: String?
        var changeType = "modified"
        var isBinary = fileEntry.isBinary
        var hunks: [DiffWebViewRenderableHunk] = []
        var currentHunk: HunkBuilder?

        func flushCurrentHunk() {
            guard let currentHunk else { return }
            hunks.append(currentHunk.build())
        }

        for line in filePatch.split(separator: "\n", omittingEmptySubsequences: false) {
            let stringLine = String(line)

            if stringLine.hasPrefix("diff --git ") {
                let parts = stringLine.split(separator: " ", omittingEmptySubsequences: false)
                if parts.count >= 4 {
                    oldPath = DiffPatchSelector.normalizePatchPath(String(parts[2]))
                    newPath = DiffPatchSelector.normalizePatchPath(String(parts[3]))
                }
                continue
            }

            if stringLine.hasPrefix("new file mode ") {
                changeType = "added"
                continue
            }

            if stringLine.hasPrefix("deleted file mode ") {
                changeType = "deleted"
                continue
            }

            if stringLine.hasPrefix("rename from ") {
                changeType = "renamed"
                oldPath = DiffPatchSelector.normalizePatchPath(String(stringLine.dropFirst("rename from ".count)))
                continue
            }

            if stringLine.hasPrefix("rename to ") {
                changeType = "renamed"
                newPath = DiffPatchSelector.normalizePatchPath(String(stringLine.dropFirst("rename to ".count)))
                continue
            }

            if stringLine.hasPrefix("copy from ") {
                changeType = "copied"
                oldPath = DiffPatchSelector.normalizePatchPath(String(stringLine.dropFirst("copy from ".count)))
                continue
            }

            if stringLine.hasPrefix("copy to ") {
                changeType = "copied"
                newPath = DiffPatchSelector.normalizePatchPath(String(stringLine.dropFirst("copy to ".count)))
                continue
            }

            if stringLine.hasPrefix("Binary files ") || stringLine == "GIT binary patch" {
                isBinary = true
                continue
            }

            if stringLine.hasPrefix("@@"),
               let header = parseHunkHeader(stringLine) {
                flushCurrentHunk()
                currentHunk = HunkBuilder(
                    header: stringLine,
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount
                )
                continue
            }

            guard currentHunk != nil else { continue }

            if stringLine == "\\ No newline at end of file" {
                currentHunk?.appendNoNewlineMarker(stringLine)
                continue
            }

            if stringLine.hasPrefix("+"), !stringLine.hasPrefix("+++") {
                currentHunk?.appendAdditionLine(String(stringLine.dropFirst()))
                continue
            }

            if stringLine.hasPrefix("-"), !stringLine.hasPrefix("---") {
                currentHunk?.appendDeletionLine(String(stringLine.dropFirst()))
                continue
            }

            if stringLine.hasPrefix(" ") {
                currentHunk?.appendContextLine(String(stringLine.dropFirst()))
            }
        }

        flushCurrentHunk()

        let resolvedNewPath = normalizedRenderablePath(newPath, fallback: fileEntry.path)
        let resolvedOldPath = normalizedRenderablePath(oldPath, fallback: resolvedNewPath)
        return DiffWebViewRenderableFile(
            path: fileEntry.path,
            oldPath: resolvedOldPath,
            newPath: resolvedNewPath,
            displayPath: resolvedNewPath ?? fileEntry.path,
            language: DiffWebViewLanguageResolver.languageHint(for: resolvedNewPath ?? fileEntry.path),
            changeType: changeType,
            isBinary: isBinary,
            additions: fileEntry.additions,
            deletions: fileEntry.deletions,
            hunks: hunks
        )
    }

    private static func normalizedRenderablePath(_ value: String?, fallback: String?) -> String? {
        guard let value else { return fallback }
        let normalized = DiffPatchSelector.normalizePatchPath(value)
        if normalized == "/dev/null" || normalized.isEmpty {
            return fallback
        }
        return normalized
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard let hunkHeaderRegex,
              let match = hunkHeaderRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let oldStart = integerCapture(at: 1, in: line, match: match),
              let newStart = integerCapture(at: 3, in: line, match: match) else {
            return nil
        }

        let oldCount = integerCapture(at: 2, in: line, match: match) ?? 1
        let newCount = integerCapture(at: 4, in: line, match: match) ?? 1
        return (oldStart, oldCount, newStart, newCount)
    }

    private static func integerCapture(at index: Int, in text: String, match: NSTextCheckingResult) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text) else {
            return nil
        }
        return Int(text[swiftRange])
    }
}

final class DiffWebViewUpdateContext {
    private struct CachedFullPayload {
        let javaScript: String
        let encodedBytes: Int
    }

    private var fullPayloadJSONCache: [String: CachedFullPayload] = [:]

    func makeUpdate(
        previous: DiffWebViewRenderPayload?,
        next: DiffWebViewRenderPayload,
        pageHasLoaded: Bool
    ) -> DiffWebViewJavaScriptUpdate? {
        DiffWebViewUpdatePlanner.makeUpdate(
            previous: previous,
            next: next,
            pageHasLoaded: pageHasLoaded,
            context: self
        )
    }

    fileprivate func fullPayloadUpdate(
        for payload: DiffWebViewRenderPayload,
        kind: String
    ) -> DiffWebViewJavaScriptUpdate {
        if let cached = fullPayloadJSONCache[payload.cacheIdentity] {
            return DiffWebViewJavaScriptUpdate(
                kind: kind,
                javaScript: cached.javaScript,
                encodedBytes: cached.encodedBytes
            )
        }

        let cached: CachedFullPayload
        if let precomputed = payload.precomputedFullPayload,
           precomputed.cacheIdentity == payload.cacheIdentity {
            cached = CachedFullPayload(
                javaScript: precomputed.javaScript,
                encodedBytes: precomputed.encodedBytes
            )
        } else {
            let json = DiffWebViewUpdatePlanner.encodeJSON(payload)
            cached = CachedFullPayload(
                javaScript: "window.cmuxReceiveDiffPayload(\(json));",
                encodedBytes: json.utf8.count
            )
        }
        fullPayloadJSONCache[payload.cacheIdentity] = cached

        return DiffWebViewJavaScriptUpdate(
            kind: kind,
            javaScript: cached.javaScript,
            encodedBytes: cached.encodedBytes
        )
    }
}

enum DiffWebViewUpdatePlanner {
    static func makeUpdate(
        previous: DiffWebViewRenderPayload?,
        next: DiffWebViewRenderPayload,
        pageHasLoaded: Bool,
        context: DiffWebViewUpdateContext? = nil
    ) -> DiffWebViewJavaScriptUpdate? {
        guard pageHasLoaded else {
            return fullPayloadUpdate(for: next, kind: "bootstrap", context: context)
        }
        guard let previous else {
            return fullPayloadUpdate(for: next, kind: "bootstrap", context: context)
        }
        guard previous != next else { return nil }

        if previous.files == next.files,
           previous.selectedFilePath == next.selectedFilePath,
           previous.isDarkMode != next.isDarkMode {
            let literal = next.isDarkMode ? "true" : "false"
            return DiffWebViewJavaScriptUpdate(
                kind: "theme",
                javaScript: "window.cmuxApplyTheme(\(literal));",
                encodedBytes: literal.utf8.count
            )
        }

        return fullPayloadUpdate(for: next, kind: "full", context: context)
    }

    private static func fullPayloadUpdate(
        for payload: DiffWebViewRenderPayload,
        kind: String,
        context: DiffWebViewUpdateContext?
    ) -> DiffWebViewJavaScriptUpdate {
        if let context {
            return context.fullPayloadUpdate(for: payload, kind: kind)
        }

        let json = encodeJSON(payload)
        return DiffWebViewJavaScriptUpdate(
            kind: kind,
            javaScript: "window.cmuxReceiveDiffPayload(\(json));",
            encodedBytes: json.utf8.count
        )
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
