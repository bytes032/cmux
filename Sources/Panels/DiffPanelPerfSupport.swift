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

struct DiffPatchFileIndex: Sendable {
    let originalPatch: String
    private let offsetsByPath: [String: (start: Int, end: Int)]
    let immediateWebViewPaths: Set<String>

    init(originalPatch: String, offsetsByPath: [String: (start: Int, end: Int)], immediateWebViewPaths: Set<String>) {
        self.originalPatch = originalPatch
        self.offsetsByPath = offsetsByPath
        self.immediateWebViewPaths = immediateWebViewPaths
    }

    var patchesByPath: [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(offsetsByPath.count)
        originalPatch.utf8.withContiguousStorageIfAvailable { utf8 in
            let base = utf8.baseAddress!
            for (path, offsets) in offsetsByPath {
                result[path] = String(decoding: UnsafeBufferPointer(start: base + offsets.start, count: offsets.end - offsets.start), as: UTF8.self)
            }
        }
        return result
    }

    subscript(path: String) -> String? {
        guard let offsets = offsetsByPath[path] else { return nil }
        return originalPatch.utf8.withContiguousStorageIfAvailable { utf8 -> String in
            let base = utf8.baseAddress!
            return String(decoding: UnsafeBufferPointer(start: base + offsets.start, count: offsets.end - offsets.start), as: UTF8.self)
        }
    }

    var fileCount: Int { offsetsByPath.count }
}

enum DiffPatchSelector {
    static func singleFilePatch(
        from patch: String,
        selectedFilePath: String
    ) -> String {
        filePatchesByPath(from: patch)[selectedFilePath] ?? ""
    }

    static func filePatchesByPath(from patch: String) -> [String: String] {
        index(from: patch).patchesByPath
    }

    /// Build a patch file index using a single fused UTF-8 buffer scan.
    /// Returns byte-offset ranges per file and the set of files exceeding the webview threshold.
    static func index(from patch: String) -> DiffPatchFileIndex {
        guard !patch.isEmpty else {
            return DiffPatchFileIndex(originalPatch: patch, offsetsByPath: [:], immediateWebViewPaths: [])
        }

        var offsetsByPath: [String: (start: Int, end: Int)] = [:]
        var immediateWebViewPaths: Set<String> = []
        var currentPath: String?
        var currentSectionStartOffset = 0
        var currentContentBytes = 0

        patch.utf8.withContiguousStorageIfAvailable { utf8Buffer -> Void in
            let count = utf8Buffer.count
            guard count > 0 else { return }
            let base = utf8Buffer.baseAddress!
            let newline = UInt8(ascii: "\n")
            let plus = UInt8(ascii: "+")
            let minus = UInt8(ascii: "-")
            let space = UInt8(ascii: " ")
            let rawBase = UnsafeRawPointer(base)

            var lineStart = 0

            func flushSection(until endOffset: Int) {
                guard let path = currentPath, currentSectionStartOffset < endOffset else { return }
                offsetsByPath[path] = (start: currentSectionStartOffset, end: endOffset)
                if currentContentBytes > DiffSelectedFileRouteDecider.fastRendererByteThreshold {
                    immediateWebViewPaths.insert(path)
                }
            }

            func extractPathFromDiffHeader(at offset: Int, length: Int) -> String? {
                var spaceCount = 0
                var thirdTokenStart = -1
                var fourthTokenStart = -1
                let lineEnd = offset + length
                var i = offset
                while i < lineEnd {
                    if base[i] == space {
                        spaceCount += 1
                        if spaceCount == 2 { thirdTokenStart = i + 1 }
                        else if spaceCount == 3 { fourthTokenStart = i + 1; break }
                    }
                    i += 1
                }
                let tokenStart: Int
                let tokenEnd: Int
                if fourthTokenStart >= 0, fourthTokenStart < lineEnd {
                    tokenStart = fourthTokenStart; tokenEnd = lineEnd
                } else if thirdTokenStart >= 0, thirdTokenStart < lineEnd {
                    tokenStart = thirdTokenStart; tokenEnd = fourthTokenStart >= 0 ? fourthTokenStart - 1 : lineEnd
                } else { return nil }
                var pathStart = tokenStart
                if tokenEnd - tokenStart >= 2,
                   (base[tokenStart] == UInt8(ascii: "a") || base[tokenStart] == UInt8(ascii: "b")),
                   base[tokenStart + 1] == UInt8(ascii: "/") {
                    pathStart = tokenStart + 2
                }
                guard pathStart < tokenEnd else { return nil }
                return String(decoding: UnsafeBufferPointer(start: base + pathStart, count: tokenEnd - pathStart), as: UTF8.self)
            }

            // Use memchr for line-oriented scanning
            var pos = 0
            while pos < count {
                let nlResult = memchr(rawBase + pos, Int32(newline), count - pos)
                let lineEnd: Int
                if let nlPtr = nlResult {
                    lineEnd = base.distance(to: nlPtr.assumingMemoryBound(to: UInt8.self))
                } else {
                    lineEnd = count
                }

                let lineScanLength = lineEnd - lineStart
                if lineScanLength > 0 {
                    let firstByte = base[lineStart]
                    if firstByte == UInt8(ascii: "d") && lineScanLength >= 11 {
                        var isDiffGit = true
                        let pfx: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0x64,0x69,0x66,0x66,0x20,0x2D,0x2D,0x67,0x69,0x74,0x20)
                        withUnsafeBytes(of: pfx) { pfxBuf in
                            for j in 0..<11 {
                                if base[lineStart + j] != pfxBuf[j] { isDiffGit = false; return }
                            }
                        }
                        if isDiffGit {
                            flushSection(until: lineStart)
                            currentPath = extractPathFromDiffHeader(at: lineStart, length: lineScanLength)
                            currentSectionStartOffset = lineStart
                            currentContentBytes = 0
                        }
                    } else if currentPath != nil {
                        if firstByte == plus && !(lineScanLength >= 3 && base[lineStart + 1] == plus && base[lineStart + 2] == plus) {
                            currentContentBytes += lineScanLength - 1
                        } else if firstByte == minus && !(lineScanLength >= 3 && base[lineStart + 1] == minus && base[lineStart + 2] == minus) {
                            currentContentBytes += lineScanLength - 1
                        }
                    }
                }

                if nlResult != nil {
                    lineStart = lineEnd + 1
                    pos = lineEnd + 1
                } else {
                    pos = count
                }
            }

            // Flush final section
            if currentPath != nil {
                offsetsByPath[currentPath!] = (start: currentSectionStartOffset, end: count)
                if currentContentBytes > DiffSelectedFileRouteDecider.fastRendererByteThreshold {
                    immediateWebViewPaths.insert(currentPath!)
                }
            }
        }

        return DiffPatchFileIndex(
            originalPatch: patch,
            offsetsByPath: offsetsByPath,
            immediateWebViewPaths: immediateWebViewPaths
        )
    }

    fileprivate static func normalizePatchPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }
}

enum DiffSelectedFileRouteDecider {
    static let fastRendererByteThreshold = 12_000

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
        var childPairs: [(key: String, node: BuilderNode)] = []

        init(id: String, name: String, fullPath: String? = nil) {
            self.id = id
            self.name = name
            self.fullPath = fullPath
        }

        func findChild(_ key: String) -> BuilderNode? {
            for pair in childPairs where pair.key == key {
                return pair.node
            }
            return nil
        }

        func addChild(key: String, node: BuilderNode) {
            childPairs.append((key: key, node: node))
        }
    }

    static func build(from files: [DiffPanelTreeFile]) -> [DiffPanelTreeNode] {
        guard !files.isEmpty else { return [] }
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

                if let existing = currentNode.findChild(component) {
                    currentNode = existing
                } else {
                    let child = BuilderNode(
                        id: currentPath,
                        name: component,
                        fullPath: isLeaf ? file.path : nil
                    )
                    currentNode.addChild(key: component, node: child)
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
        builder.childPairs.sort { lhs, rhs in
            let lhsIsDir = lhs.node.fullPath == nil
            let rhsIsDir = rhs.node.fullPath == nil
            if lhsIsDir && !rhsIsDir { return true }
            if !lhsIsDir && rhsIsDir { return false }
            return lhs.key < rhs.key
        }

        var result: [DiffPanelTreeNode] = []
        result.reserveCapacity(builder.childPairs.count)

        for pair in builder.childPairs {
            let child = pair.node
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

            result.append(DiffPanelTreeNode(
                id: nodeID,
                name: displayName,
                fullPath: child.fullPath,
                additions: child.additions,
                deletions: child.deletions,
                fileCount: child.fileCount,
                children: childNodes
            ))
        }

        return result
    }
}

struct DiffWebViewRenderableLine: Encodable, Equatable, Sendable {
    let kind: String
    /// Line text content. Stored as Substring to share backing storage with the original patch,
    /// avoiding per-line String allocation during payload construction.
    let text: Substring
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let isNoNewlineMarker: Bool

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(String(text), forKey: .text)
        try container.encode(oldLineNumber, forKey: .oldLineNumber)
        try container.encode(newLineNumber, forKey: .newLineNumber)
        try container.encode(isNoNewlineMarker, forKey: .isNoNewlineMarker)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, oldLineNumber, newLineNumber, isNoNewlineMarker
    }
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

struct DiffWebViewRenderPayload: Encodable, Sendable {
    let files: [DiffWebViewRenderableFile]
    let selectedFilePath: String?
    let isDarkMode: Bool
    let cacheIdentity: String

    private enum CodingKeys: String, CodingKey {
        case files
        case selectedFilePath
        case isDarkMode
    }
}

extension DiffWebViewRenderPayload: Equatable {
    /// Compare by cacheIdentity + isDarkMode only. The cacheIdentity encodes all inputs
    /// that determine the file content (scope key, selected file, theme). This avoids
    /// the O(n × lines) deep comparison of all DiffWebViewRenderableFile/Hunk/Line arrays
    /// that was wasting ~54ms on every SwiftUI re-evaluation.
    static func == (lhs: DiffWebViewRenderPayload, rhs: DiffWebViewRenderPayload) -> Bool {
        lhs.cacheIdentity == rhs.cacheIdentity && lhs.isDarkMode == rhs.isDarkMode
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

        mutating func appendContextLine(_ text: Substring) {
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

        mutating func appendDeletionLine(_ text: Substring) {
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

        mutating func appendAdditionLine(_ text: Substring) {
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

        mutating func appendNoNewlineMarker(_ text: Substring) {
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

    struct FileInput {
        let path: String
        let additions: Int
        let deletions: Int
        let isBinary: Bool
    }

    static func build(
        fileEntry: FileInput,
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

        filePatch.utf8.withContiguousStorageIfAvailable { utf8 in
            let count = utf8.count
            guard count > 0 else { return }
            let base = utf8.baseAddress!
            let rawBase = UnsafeRawPointer(base)
            var pos = 0

            while pos < count {
                let nlResult = memchr(rawBase + pos, Int32(0x0A), count - pos)
                let lineEnd: Int
                if let nlPtr = nlResult {
                    lineEnd = base.distance(to: nlPtr.assumingMemoryBound(to: UInt8.self))
                } else {
                    lineEnd = count
                }

                let lineLen = lineEnd - pos
                guard lineLen > 0 else {
                    pos = lineEnd + 1
                    continue
                }

                let firstByte = base[pos]

                // Diff metadata: diff --git, ---, +++, new file, deleted file, rename, copy, Binary
                if firstByte == UInt8(ascii: "d") {
                    if lineLen >= 11 && base[pos+1] == 0x69 && base[pos+2] == 0x66 && base[pos+3] == 0x66 && base[pos+4] == 0x20 && base[pos+5] == 0x2D && base[pos+6] == 0x2D {
                        // "diff --git " — extract paths
                        let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                        let parts = lineStr.split(separator: " ", omittingEmptySubsequences: false)
                        if parts.count >= 4 {
                            oldPath = DiffPatchSelector.normalizePatchPath(String(parts[2]))
                            newPath = DiffPatchSelector.normalizePatchPath(String(parts[3]))
                        }
                        pos = lineEnd + 1; continue
                    }
                    if lineLen >= 18 && base[pos+1] == 0x65 { // "deleted file mode "
                        changeType = "deleted"; pos = lineEnd + 1; continue
                    }
                }

                if firstByte == UInt8(ascii: "n") && lineLen >= 14 && base[pos+1] == 0x65 && base[pos+2] == 0x77 {
                    changeType = "added"; pos = lineEnd + 1; continue
                }

                if firstByte == UInt8(ascii: "r") && lineLen >= 10 {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                    if lineStr.hasPrefix("rename from ") {
                        changeType = "renamed"
                        oldPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(12)))
                        pos = lineEnd + 1; continue
                    }
                    if lineStr.hasPrefix("rename to ") {
                        changeType = "renamed"
                        newPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(10)))
                        pos = lineEnd + 1; continue
                    }
                }

                if firstByte == UInt8(ascii: "c") && lineLen >= 8 {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                    if lineStr.hasPrefix("copy from ") {
                        changeType = "copied"
                        oldPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(10)))
                        pos = lineEnd + 1; continue
                    }
                    if lineStr.hasPrefix("copy to ") {
                        changeType = "copied"
                        newPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(8)))
                        pos = lineEnd + 1; continue
                    }
                }

                if firstByte == UInt8(ascii: "B") && lineLen >= 13 {
                    isBinary = true; pos = lineEnd + 1; continue
                }
                if firstByte == UInt8(ascii: "G") && lineLen == 16 {
                    // "GIT binary patch"
                    isBinary = true; pos = lineEnd + 1; continue
                }

                // Hunk header: @@ -N,N +N,N @@
                if firstByte == UInt8(ascii: "@") && lineLen >= 7 && base[pos+1] == UInt8(ascii: "@") {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                    if let header = parseHunkHeader(lineStr) {
                        flushCurrentHunk()
                        currentHunk = HunkBuilder(
                            header: lineStr,
                            oldStart: header.oldStart,
                            oldCount: header.oldCount,
                            newStart: header.newStart,
                            newCount: header.newCount
                        )
                    }
                    pos = lineEnd + 1; continue
                }

                // --- and +++ lines (skip)
                if firstByte == UInt8(ascii: "-") && lineLen >= 3 && base[pos+1] == 0x2D && base[pos+2] == 0x2D {
                    pos = lineEnd + 1; continue
                }
                if firstByte == UInt8(ascii: "+") && lineLen >= 3 && base[pos+1] == 0x2B && base[pos+2] == 0x2B {
                    pos = lineEnd + 1; continue
                }

                guard currentHunk != nil else { pos = lineEnd + 1; continue }

                // \\ No newline at end of file
                if firstByte == UInt8(ascii: "\\") {
                    let startIdx = filePatch.utf8.index(filePatch.startIndex, offsetBy: pos)
                    let endIdx = filePatch.utf8.index(filePatch.startIndex, offsetBy: lineEnd)
                    currentHunk?.appendNoNewlineMarker(filePatch[startIdx..<endIdx])
                    pos = lineEnd + 1; continue
                }

                // Content lines: +, -, or context (space) — use Substring to share backing storage
                let textStart = filePatch.utf8.index(filePatch.startIndex, offsetBy: pos + 1)
                let textEnd = filePatch.utf8.index(filePatch.startIndex, offsetBy: lineEnd)
                let text = filePatch[textStart..<textEnd]
                if firstByte == UInt8(ascii: "+") {
                    currentHunk?.appendAdditionLine(text)
                } else if firstByte == UInt8(ascii: "-") {
                    currentHunk?.appendDeletionLine(text)
                } else if firstByte == UInt8(ascii: " ") {
                    currentHunk?.appendContextLine(text)
                }

                pos = lineEnd + 1
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

    /// Fast manual hunk header parser. Format: "@@ -OLD_START[,OLD_COUNT] +NEW_START[,NEW_COUNT] @@"
    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        return line.utf8.withContiguousStorageIfAvailable { utf8 -> (Int, Int, Int, Int)? in
            let count = utf8.count
            guard count >= 7 else { return nil }
            let base = utf8.baseAddress!
            var i = 4 // skip "@@ -"

            func scanInt() -> Int? {
                var n = 0; var has = false
                while i < count {
                    let b = base[i]
                    if b >= 0x30 && b <= 0x39 { n = n * 10 + Int(b - 0x30); has = true; i += 1 }
                    else { break }
                }
                return has ? n : nil
            }

            guard let os = scanInt() else { return nil }
            var oc = 1
            if i < count && base[i] == UInt8(ascii: ",") { i += 1; oc = scanInt() ?? 1 }
            guard i < count && base[i] == UInt8(ascii: " ") else { return nil }
            i += 1
            guard i < count && base[i] == UInt8(ascii: "+") else { return nil }
            i += 1
            guard let ns = scanInt() else { return nil }
            var nc = 1
            if i < count && base[i] == UInt8(ascii: ",") { i += 1; nc = scanInt() ?? 1 }
            return (os, oc, ns, nc)
        } ?? nil
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

        let json = DiffWebViewUpdatePlanner.fastEncodePayload(payload)
        let cached = CachedFullPayload(
            javaScript: "window.cmuxReceiveDiffPayload(\(json));",
            encodedBytes: json.utf8.count
        )
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

        // Detect theme-only change: same scope/selection, different isDarkMode.
        // cacheIdentity encodes scope key + selection but not theme, so equal
        // identities with differing isDarkMode means only the theme changed.
        if previous.isDarkMode != next.isDarkMode,
           previous.cacheIdentity == next.cacheIdentity {
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

        let json = fastEncodePayload(payload)
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

    // MARK: - Fast hand-built JSON serializer for DiffWebViewRenderPayload

    static func fastEncodePayload(_ payload: DiffWebViewRenderPayload) -> String {
        // Estimate: ~200 bytes per line, average 15 lines per file
        let estimatedSize = payload.files.count * 15 * 200 + 512
        var buf = [UInt8]()
        buf.reserveCapacity(estimatedSize)

        let allSafe = false // conservative: always check per-string

        buf.append(contentsOf: "{\"files\":[".utf8)
        for (fi, file) in payload.files.enumerated() {
            if fi > 0 { buf.append(0x2C) } // ,
            writeFile(&buf, file, knownSafe: allSafe)
        }
        buf.append(contentsOf: "],\"selectedFilePath\":".utf8)
        if let sfp = payload.selectedFilePath {
            writeQuotedString(&buf, sfp)
        } else {
            buf.append(contentsOf: "null".utf8)
        }
        buf.append(contentsOf: ",\"isDarkMode\":".utf8)
        buf.append(contentsOf: (payload.isDarkMode ? "true" : "false").utf8)
        buf.append(0x7D) // }
        return String(decoding: buf, as: UTF8.self)
    }

    private static func writeFile(_ buf: inout [UInt8], _ file: DiffWebViewRenderableFile, knownSafe: Bool = false) {
        buf.append(contentsOf: "{\"path\":".utf8)
        writeQuotedString(&buf, file.path)
        buf.append(contentsOf: ",\"oldPath\":".utf8)
        writeOptionalString(&buf, file.oldPath)
        buf.append(contentsOf: ",\"newPath\":".utf8)
        writeOptionalString(&buf, file.newPath)
        buf.append(contentsOf: ",\"displayPath\":".utf8)
        writeQuotedString(&buf, file.displayPath)
        buf.append(contentsOf: ",\"language\":".utf8)
        writeQuotedString(&buf, file.language)
        buf.append(contentsOf: ",\"changeType\":".utf8)
        writeQuotedString(&buf, file.changeType)
        buf.append(contentsOf: ",\"isBinary\":".utf8)
        buf.append(contentsOf: (file.isBinary ? "true" : "false").utf8)
        buf.append(contentsOf: ",\"additions\":".utf8)
        writeInt(&buf, file.additions)
        buf.append(contentsOf: ",\"deletions\":".utf8)
        writeInt(&buf, file.deletions)
        buf.append(contentsOf: ",\"hunks\":[".utf8)
        for (hi, hunk) in file.hunks.enumerated() {
            if hi > 0 { buf.append(0x2C) }
            writeHunk(&buf, hunk, knownSafe: knownSafe)
        }
        buf.append(contentsOf: "]}".utf8)
    }

    private static func writeHunk(_ buf: inout [UInt8], _ hunk: DiffWebViewRenderableHunk, knownSafe: Bool = false) {
        buf.append(contentsOf: "{\"header\":".utf8)
        writeQuotedString(&buf, hunk.header)
        buf.append(contentsOf: ",\"oldStart\":".utf8)
        writeInt(&buf, hunk.oldStart)
        buf.append(contentsOf: ",\"oldCount\":".utf8)
        writeInt(&buf, hunk.oldCount)
        buf.append(contentsOf: ",\"newStart\":".utf8)
        writeInt(&buf, hunk.newStart)
        buf.append(contentsOf: ",\"newCount\":".utf8)
        writeInt(&buf, hunk.newCount)
        buf.append(contentsOf: ",\"lines\":[".utf8)
        for (li, line) in hunk.lines.enumerated() {
            if li > 0 { buf.append(0x2C) }
            writeLine(&buf, line, knownSafe: knownSafe)
        }
        buf.append(contentsOf: "]}".utf8)
    }

    private static func writeLine(_ buf: inout [UInt8], _ line: DiffWebViewRenderableLine, knownSafe: Bool = false) {
        buf.append(contentsOf: "{\"kind\":".utf8)
        writeQuotedString(&buf, line.kind)
        buf.append(contentsOf: ",\"text\":".utf8)
        writeQuotedStringProtocolChecked(&buf, line.text, knownSafe: knownSafe)
        buf.append(contentsOf: ",\"oldLineNumber\":".utf8)
        writeOptionalInt(&buf, line.oldLineNumber)
        buf.append(contentsOf: ",\"newLineNumber\":".utf8)
        writeOptionalInt(&buf, line.newLineNumber)
        buf.append(contentsOf: ",\"isNoNewlineMarker\":".utf8)
        buf.append(contentsOf: (line.isNoNewlineMarker ? "true" : "false").utf8)
        buf.append(0x7D)
    }

    @inline(__always)
    private static func writeQuotedStringProtocol<S: StringProtocol>(_ buf: inout [UInt8], _ value: S) {
        writeQuotedStringProtocolChecked(&buf, value, knownSafe: false)
    }

    /// When `knownSafe` is true, skip the per-string memchr checks for special chars.
    /// Use when a whole-patch pre-check has confirmed no specials exist.
    @inline(__always)
    private static func writeQuotedStringProtocolChecked<S: StringProtocol>(_ buf: inout [UInt8], _ value: S, knownSafe: Bool) {
        buf.append(0x22)
        value.utf8.withContiguousStorageIfAvailable { utf8 in
            guard let base = utf8.baseAddress else { return }
            let count = utf8.count

            if knownSafe {
                buf.append(contentsOf: UnsafeBufferPointer(start: base, count: count))
            } else {
                let rawBase = UnsafeRawPointer(base)
                let hasNewline = memchr(rawBase, Int32(0x0A), count) != nil
                let hasQuote = memchr(rawBase, Int32(0x22), count) != nil
                let hasBackslash = memchr(rawBase, Int32(0x5C), count) != nil
                let hasTab = memchr(rawBase, Int32(0x09), count) != nil
                if !(hasNewline || hasQuote || hasBackslash || hasTab) {
                    buf.append(contentsOf: UnsafeBufferPointer(start: base, count: count))
                } else {
                    var segStart = 0
                    for i in 0..<count {
                        let b = base[i]
                        guard b < 0x20 || b == 0x22 || b == 0x5C else { continue }
                        if segStart < i { buf.append(contentsOf: UnsafeBufferPointer(start: base + segStart, count: i - segStart)) }
                        switch b {
                        case 0x0A: buf.append(0x5C); buf.append(0x6E)
                        case 0x0D: buf.append(0x5C); buf.append(0x72)
                        case 0x09: buf.append(0x5C); buf.append(0x74)
                        case 0x08: buf.append(0x5C); buf.append(0x62)
                        case 0x0C: buf.append(0x5C); buf.append(0x66)
                        case 0x22: buf.append(0x5C); buf.append(0x22)
                        case 0x5C: buf.append(0x5C); buf.append(0x5C)
                        default:
                            buf.append(0x5C); buf.append(0x75); buf.append(0x30); buf.append(0x30)
                            let hi = b >> 4; let lo = b & 0x0F
                            buf.append(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)
                            buf.append(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)
                        }
                        segStart = i + 1
                    }
                    if segStart < count { buf.append(contentsOf: UnsafeBufferPointer(start: base + segStart, count: count - segStart)) }
                }
            }
        }
        buf.append(0x22)
    }

    @inline(__always)
    private static func writeQuotedString(_ buf: inout [UInt8], _ value: String) {
        buf.append(0x22) // "
        // Fast JSON-escape: most code text is safe ASCII
        value.utf8.withContiguousStorageIfAvailable { utf8 in
            guard let base = utf8.baseAddress else { return }
            let count = utf8.count
            let rawBase = UnsafeRawPointer(base)

            // Pre-check if any escaping is needed
            let hasNewline = memchr(rawBase, Int32(0x0A), count) != nil
            let hasQuote = memchr(rawBase, Int32(0x22), count) != nil
            let hasBackslash = memchr(rawBase, Int32(0x5C), count) != nil
            let hasTab = memchr(rawBase, Int32(0x09), count) != nil

            if !(hasNewline || hasQuote || hasBackslash || hasTab) {
                // Fast path: no escaping needed — bulk copy
                buf.append(contentsOf: UnsafeBufferPointer(start: base, count: count))
            } else {
                // Slow path: escape special characters
                var segStart = 0
                for i in 0..<count {
                    let b = base[i]
                    guard b < 0x20 || b == 0x22 || b == 0x5C else { continue }
                    if segStart < i {
                        buf.append(contentsOf: UnsafeBufferPointer(start: base + segStart, count: i - segStart))
                    }
                    switch b {
                    case 0x0A: buf.append(0x5C); buf.append(0x6E)
                    case 0x0D: buf.append(0x5C); buf.append(0x72)
                    case 0x09: buf.append(0x5C); buf.append(0x74)
                    case 0x22: buf.append(0x5C); buf.append(0x22)
                    case 0x5C: buf.append(0x5C); buf.append(0x5C)
                    case 0x08: buf.append(0x5C); buf.append(0x62)
                    case 0x0C: buf.append(0x5C); buf.append(0x66)
                    default:
                        buf.append(0x5C); buf.append(0x75); buf.append(0x30); buf.append(0x30)
                        let hi = b >> 4; let lo = b & 0x0F
                        buf.append(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)
                        buf.append(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)
                    }
                    segStart = i + 1
                }
                if segStart < count {
                    buf.append(contentsOf: UnsafeBufferPointer(start: base + segStart, count: count - segStart))
                }
            }
        }
        buf.append(0x22) // "
    }

    @inline(__always)
    private static func writeOptionalString(_ buf: inout [UInt8], _ value: String?) {
        if let value { writeQuotedString(&buf, value) } else { buf.append(contentsOf: "null".utf8) }
    }

    @inline(__always)
    private static func writeInt(_ buf: inout [UInt8], _ value: Int) {
        if value == 0 { buf.append(0x30); return }
        var n = value
        if n < 0 { buf.append(0x2D); n = -n }
        let start = buf.count
        while n > 0 { buf.append(UInt8(n % 10) + 0x30); n /= 10 }
        var lo = start; var hi = buf.count - 1
        while lo < hi { buf.swapAt(lo, hi); lo += 1; hi -= 1 }
    }

    @inline(__always)
    private static func writeOptionalInt(_ buf: inout [UInt8], _ value: Int?) {
        if let value { writeInt(&buf, value) } else { buf.append(contentsOf: "null".utf8) }
    }

    /// Write a quoted JSON string directly from raw UTF-8 bytes without creating a Swift String.
    @inline(__always)
    private static func writeQuotedBytes(_ buf: inout [UInt8], _ base: UnsafePointer<UInt8>, _ start: Int, _ length: Int, knownSafe: Bool = false) {
        buf.append(0x22) // "
        guard length > 0 else { buf.append(0x22); return }

        if knownSafe {
            buf.append(contentsOf: UnsafeBufferPointer(start: base + start, count: length))
            buf.append(0x22)
            return
        }

        let rawBase = UnsafeRawPointer(base + start)
        let hasNewline = memchr(rawBase, Int32(0x0A), length) != nil
        let hasQuote = memchr(rawBase, Int32(0x22), length) != nil
        let hasBackslash = memchr(rawBase, Int32(0x5C), length) != nil
        let hasTab = memchr(rawBase, Int32(0x09), length) != nil

        if !(hasNewline || hasQuote || hasBackslash || hasTab) {
            buf.append(contentsOf: UnsafeBufferPointer(start: base + start, count: length))
        } else {
            var segStart = 0
            for i in 0..<length {
                let b = base[start + i]
                guard b < 0x20 || b == 0x22 || b == 0x5C else { continue }
                if segStart < i {
                    buf.append(contentsOf: UnsafeBufferPointer(start: base + start + segStart, count: i - segStart))
                }
                switch b {
                case 0x0A: buf.append(0x5C); buf.append(0x6E)
                case 0x0D: buf.append(0x5C); buf.append(0x72)
                case 0x09: buf.append(0x5C); buf.append(0x74)
                case 0x08: buf.append(0x5C); buf.append(0x62)
                case 0x0C: buf.append(0x5C); buf.append(0x66)
                case 0x22: buf.append(0x5C); buf.append(0x22)
                case 0x5C: buf.append(0x5C); buf.append(0x5C)
                default:
                    buf.append(0x5C); buf.append(0x75); buf.append(0x30); buf.append(0x30)
                    let hi = b >> 4; let lo = b & 0x0F
                    buf.append(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)
                    buf.append(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)
                }
                segStart = i + 1
            }
            if segStart < length {
                buf.append(contentsOf: UnsafeBufferPointer(start: base + start + segStart, count: length - segStart))
            }
        }
        buf.append(0x22) // "
    }

    /// Combined build+JSON: parse a single file's patch and write its JSON representation
    /// directly into the buffer, skipping intermediate DiffWebViewRenderableLine allocation.
    static func writeFileFromPatch(
        _ buf: inout [UInt8],
        path: String,
        additions: Int,
        deletions: Int,
        isBinary: Bool,
        filePatch: String
    ) {
        buf.append(contentsOf: "{\"path\":".utf8)
        writeQuotedString(&buf, path)

        // Pre-check: does this file's patch contain any chars needing JSON escaping in content lines?
        // Content lines never contain \n (that's the line delimiter), but may contain ", \, or \t.
        let patchNeedsEscape = filePatch.utf8.withContiguousStorageIfAvailable { utf8 -> Bool in
            guard let base = utf8.baseAddress else { return true }
            let rawBase = UnsafeRawPointer(base)
            let count = utf8.count
            return memchr(rawBase, Int32(0x22), count) != nil
                || memchr(rawBase, Int32(0x5C), count) != nil
                || memchr(rawBase, Int32(0x09), count) != nil
        } ?? true

        var oldPath: String?
        var newPath: String?
        var changeType = "modified"
        var detectedBinary = isBinary

        // Scan the patch to extract metadata and write hunks directly as JSON
        var hunkCount = 0
        var lineCountInHunk = 0

        // We'll build the hunks JSON into a temporary buffer, then splice it
        var hunksBuf = [UInt8]()
        hunksBuf.reserveCapacity(filePatch.utf8.count + filePatch.utf8.count / 4)

        filePatch.utf8.withContiguousStorageIfAvailable { utf8 in
            let count = utf8.count
            guard count > 0 else { return }
            let base = utf8.baseAddress!
            let rawBase = UnsafeRawPointer(base)
            var pos = 0
            var inHunk = false
            var nextOldLine = 0
            var nextNewLine = 0

            while pos < count {
                let nlResult = memchr(rawBase + pos, Int32(0x0A), count - pos)
                let lineEnd: Int
                if let nlPtr = nlResult {
                    lineEnd = base.distance(to: nlPtr.assumingMemoryBound(to: UInt8.self))
                } else {
                    lineEnd = count
                }
                let lineLen = lineEnd - pos
                guard lineLen > 0 else { pos = lineEnd + 1; continue }

                let firstByte = base[pos]

                // Metadata lines
                if firstByte == UInt8(ascii: "d") && lineLen >= 11 && base[pos+1] == 0x69 && base[pos+2] == 0x66 && base[pos+3] == 0x66 {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                    let parts = lineStr.split(separator: " ", omittingEmptySubsequences: false)
                    if parts.count >= 4 {
                        oldPath = DiffPatchSelector.normalizePatchPath(String(parts[2]))
                        newPath = DiffPatchSelector.normalizePatchPath(String(parts[3]))
                    }
                    pos = lineEnd + 1; continue
                }
                if firstByte == UInt8(ascii: "d") && lineLen >= 18 && base[pos+1] == 0x65 {
                    changeType = "deleted"; pos = lineEnd + 1; continue
                }
                if firstByte == UInt8(ascii: "n") && lineLen >= 14 && base[pos+1] == 0x65 && base[pos+2] == 0x77 {
                    changeType = "added"; pos = lineEnd + 1; continue
                }
                if firstByte == UInt8(ascii: "r") && lineLen >= 10 {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                    if lineStr.hasPrefix("rename from ") { changeType = "renamed"; oldPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(12))); pos = lineEnd + 1; continue }
                    if lineStr.hasPrefix("rename to ") { changeType = "renamed"; newPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(10))); pos = lineEnd + 1; continue }
                }
                if firstByte == UInt8(ascii: "c") && lineLen >= 8 {
                    let lineStr = String(decoding: UnsafeBufferPointer(start: base + pos, count: lineLen), as: UTF8.self)
                    if lineStr.hasPrefix("copy from ") { changeType = "copied"; oldPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(10))); pos = lineEnd + 1; continue }
                    if lineStr.hasPrefix("copy to ") { changeType = "copied"; newPath = DiffPatchSelector.normalizePatchPath(String(lineStr.dropFirst(8))); pos = lineEnd + 1; continue }
                }
                if firstByte == UInt8(ascii: "B") && lineLen >= 13 { detectedBinary = true; pos = lineEnd + 1; continue }
                if firstByte == UInt8(ascii: "G") && lineLen == 16 { detectedBinary = true; pos = lineEnd + 1; continue }

                // Hunk header
                if firstByte == UInt8(ascii: "@") && lineLen >= 7 && base[pos+1] == UInt8(ascii: "@") {
                    // Close previous hunk's lines array
                    if inHunk { hunksBuf.append(contentsOf: "]}".utf8) }

                    if hunkCount > 0 { hunksBuf.append(0x2C) }
                    hunkCount += 1
                    lineCountInHunk = 0

                    // Parse header numbers manually
                    var hi = pos + 4; var oldStart = 0; var oldCount = 1; var newStart = 0; var newCount = 1
                    while hi < lineEnd && base[hi] >= 0x30 && base[hi] <= 0x39 { oldStart = oldStart * 10 + Int(base[hi] - 0x30); hi += 1 }
                    if hi < lineEnd && base[hi] == UInt8(ascii: ",") { hi += 1; oldCount = 0; while hi < lineEnd && base[hi] >= 0x30 && base[hi] <= 0x39 { oldCount = oldCount * 10 + Int(base[hi] - 0x30); hi += 1 } }
                    if hi < lineEnd && base[hi] == UInt8(ascii: " ") { hi += 1 }
                    if hi < lineEnd && base[hi] == UInt8(ascii: "+") { hi += 1 }
                    while hi < lineEnd && base[hi] >= 0x30 && base[hi] <= 0x39 { newStart = newStart * 10 + Int(base[hi] - 0x30); hi += 1 }
                    if hi < lineEnd && base[hi] == UInt8(ascii: ",") { hi += 1; newCount = 0; while hi < lineEnd && base[hi] >= 0x30 && base[hi] <= 0x39 { newCount = newCount * 10 + Int(base[hi] - 0x30); hi += 1 } }

                    nextOldLine = oldStart; nextNewLine = newStart

                    hunksBuf.append(contentsOf: "{\"header\":".utf8)
                    writeQuotedBytes(&hunksBuf, base, pos, lineLen)
                    hunksBuf.append(contentsOf: ",\"oldStart\":".utf8); writeInt(&hunksBuf, oldStart)
                    hunksBuf.append(contentsOf: ",\"oldCount\":".utf8); writeInt(&hunksBuf, oldCount)
                    hunksBuf.append(contentsOf: ",\"newStart\":".utf8); writeInt(&hunksBuf, newStart)
                    hunksBuf.append(contentsOf: ",\"newCount\":".utf8); writeInt(&hunksBuf, newCount)
                    hunksBuf.append(contentsOf: ",\"lines\":[".utf8)
                    inHunk = true
                    pos = lineEnd + 1; continue
                }

                // --- / +++ skip
                if firstByte == UInt8(ascii: "-") && lineLen >= 3 && base[pos+1] == 0x2D && base[pos+2] == 0x2D { pos = lineEnd + 1; continue }
                if firstByte == UInt8(ascii: "+") && lineLen >= 3 && base[pos+1] == 0x2B && base[pos+2] == 0x2B { pos = lineEnd + 1; continue }

                guard inHunk else { pos = lineEnd + 1; continue }

                // Content lines — write JSON directly from raw bytes
                if lineCountInHunk > 0 { hunksBuf.append(0x2C) }
                lineCountInHunk += 1

                if firstByte == UInt8(ascii: "\\") {
                    // No newline marker
                    hunksBuf.append(contentsOf: "{\"kind\":\"note\",\"text\":".utf8)
                    writeQuotedBytes(&hunksBuf, base, pos, lineLen)
                    hunksBuf.append(contentsOf: ",\"oldLineNumber\":null,\"newLineNumber\":null,\"isNoNewlineMarker\":true}".utf8)
                } else if firstByte == UInt8(ascii: "+") {
                    hunksBuf.append(contentsOf: "{\"kind\":\"addition\",\"text\":".utf8)
                    writeQuotedBytes(&hunksBuf, base, pos + 1, lineLen - 1, knownSafe: !patchNeedsEscape)
                    hunksBuf.append(contentsOf: ",\"oldLineNumber\":null,\"newLineNumber\":".utf8)
                    writeInt(&hunksBuf, nextNewLine)
                    hunksBuf.append(contentsOf: ",\"isNoNewlineMarker\":false}".utf8)
                    nextNewLine += 1
                } else if firstByte == UInt8(ascii: "-") {
                    hunksBuf.append(contentsOf: "{\"kind\":\"deletion\",\"text\":".utf8)
                    writeQuotedBytes(&hunksBuf, base, pos + 1, lineLen - 1, knownSafe: !patchNeedsEscape)
                    hunksBuf.append(contentsOf: ",\"oldLineNumber\":".utf8)
                    writeInt(&hunksBuf, nextOldLine)
                    hunksBuf.append(contentsOf: ",\"newLineNumber\":null,\"isNoNewlineMarker\":false}".utf8)
                    nextOldLine += 1
                } else if firstByte == UInt8(ascii: " ") {
                    hunksBuf.append(contentsOf: "{\"kind\":\"context\",\"text\":".utf8)
                    writeQuotedBytes(&hunksBuf, base, pos + 1, lineLen - 1, knownSafe: !patchNeedsEscape)
                    hunksBuf.append(contentsOf: ",\"oldLineNumber\":".utf8)
                    writeInt(&hunksBuf, nextOldLine)
                    hunksBuf.append(contentsOf: ",\"newLineNumber\":".utf8)
                    writeInt(&hunksBuf, nextNewLine)
                    hunksBuf.append(contentsOf: ",\"isNoNewlineMarker\":false}".utf8)
                    nextOldLine += 1; nextNewLine += 1
                }

                pos = lineEnd + 1
            }

            if inHunk { hunksBuf.append(contentsOf: "]}".utf8) }
        }

        // Resolve paths
        let resolvedNewPath = newPath ?? path
        let resolvedOldPath = oldPath ?? resolvedNewPath

        buf.append(contentsOf: ",\"oldPath\":".utf8)
        writeOptionalString(&buf, resolvedOldPath)
        buf.append(contentsOf: ",\"newPath\":".utf8)
        writeOptionalString(&buf, resolvedNewPath)
        buf.append(contentsOf: ",\"displayPath\":".utf8)
        writeQuotedString(&buf, resolvedNewPath)
        buf.append(contentsOf: ",\"language\":".utf8)
        writeQuotedString(&buf, DiffWebViewLanguageResolver.languageHint(for: resolvedNewPath))
        buf.append(contentsOf: ",\"changeType\":".utf8)
        writeQuotedString(&buf, changeType)
        buf.append(contentsOf: ",\"isBinary\":".utf8)
        buf.append(contentsOf: (detectedBinary ? "true" : "false").utf8)
        buf.append(contentsOf: ",\"additions\":".utf8)
        writeInt(&buf, additions)
        buf.append(contentsOf: ",\"deletions\":".utf8)
        writeInt(&buf, deletions)
        buf.append(contentsOf: ",\"hunks\":[".utf8)
        buf.append(contentsOf: hunksBuf)
        buf.append(contentsOf: "]}".utf8)
    }

    /// Fast-path: encode a full payload directly from patch data, bypassing intermediate struct creation.
    static func fastEncodePayloadFromPatches(
        fileInputs: [(path: String, additions: Int, deletions: Int, isBinary: Bool, filePatch: String)],
        selectedFilePath: String?,
        isDarkMode: Bool
    ) -> String {
        let estimatedSize = fileInputs.reduce(0) { $0 + $1.filePatch.utf8.count } + fileInputs.count * 200 + 512
        var buf = [UInt8]()
        buf.reserveCapacity(estimatedSize)

        buf.append(contentsOf: "{\"files\":[".utf8)
        for (fi, input) in fileInputs.enumerated() {
            if fi > 0 { buf.append(0x2C) }
            writeFileFromPatch(&buf, path: input.path, additions: input.additions, deletions: input.deletions, isBinary: input.isBinary, filePatch: input.filePatch)
        }
        buf.append(contentsOf: "],\"selectedFilePath\":".utf8)
        if let sfp = selectedFilePath { writeQuotedString(&buf, sfp) } else { buf.append(contentsOf: "null".utf8) }
        buf.append(contentsOf: ",\"isDarkMode\":".utf8)
        buf.append(contentsOf: (isDarkMode ? "true" : "false").utf8)
        buf.append(0x7D)
        return String(decoding: buf, as: UTF8.self)
    }
}
