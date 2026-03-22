const state = window.cmuxDiffState;
const root = document.getElementById("root");
const perfReporter = window.webkit?.messageHandlers?.cmuxDiffPerf;
let worker = null;
let workerCreationAttempted = false;

let currentHighlightRequestId = 0;
let currentHighlightToken = 0;

function ensureHighlightWorker() {
  if (workerCreationAttempted) {
    return worker;
  }

  workerCreationAttempted = true;
  try {
    worker = new Worker("cmux-diff-highlight-worker.js");
    worker.onmessage = (event) => {
      const payload = event.data ?? {};
      if (payload.requestId !== currentHighlightRequestId || payload.renderToken !== currentHighlightToken) {
        return;
      }

      const startedAt = performance.now();
      const highlightedLines = payload.lines ?? [];
      for (const line of highlightedLines) {
        // Use getElementById for O(1) lookup instead of querySelector with attribute selector (O(n))
        const node = document.getElementById(`hl-${line.id}`);
        if (!node) {
          continue;
        }
        node.innerHTML = line.html;
      }
      reportPerf({
        type: "highlight-ready",
        mode: "selected-file",
        totalFiles: payload.fileCount ?? 1,
        visibleFiles: 1,
        durationMs: roundMs(performance.now() - startedAt),
      });
    };
  } catch (error) {
    console.error("cmux diff worker unavailable", error);
    window.cmuxReportError?.("worker-unavailable", error);
    worker = null;
  }

  return worker;
}

window.cmuxDiffRender = function(payload) {
  try {
    state.currentPayload = payload;
    currentHighlightToken += 1;
    const renderToken = currentHighlightToken;
    document.documentElement.dataset.theme = payload.isDarkMode ? "dark" : "light";
    const files = Array.isArray(payload.files) ? payload.files : [];

    const renderStartedAt = performance.now();
    root.textContent = "";

    if (files.length === 0) {
      reportPerf({
        type: "render-empty",
        mode: "selected-file",
        totalFiles: 0,
        visibleFiles: 0,
        durationMs: 0,
      });
      return;
    }

    // Best practice: build all DOM nodes into a DocumentFragment first,
    // then append once to avoid layout thrashing from per-file appendChild.
    const fragment = document.createDocumentFragment();
    const perFileHighlightLines = []; // [{language, lines}] per file
    files.forEach((file, fileIndex) => {
      const result = renderFile(file, fileIndex, files.length);
      fragment.appendChild(result.element);
      if (result.highlightLines.length > 0) {
        perFileHighlightLines.push({
          language: file.language ?? "plain",
          lines: result.highlightLines,
        });
      }
    });
    root.appendChild(fragment);

    const renderDurationMs = roundMs(performance.now() - renderStartedAt);
    reportPerf({
      type: "render-ready",
      mode: "selected-file",
      totalFiles: files.length,
      visibleFiles: visibleFileCount(files),
      durationMs: renderDurationMs,
    });

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        reportPerf({
          type: "first-paint",
          mode: "selected-file",
          totalFiles: files.length,
          visibleFiles: visibleFileCount(files),
          durationMs: roundMs(performance.now() - renderStartedAt),
        });
      });
    });
    // Request syntax highlighting for all files (not just single-file mode).
    // Send per-file batches so the worker processes them incrementally.
    currentHighlightRequestId += 1;
    const highlightWorker = ensureHighlightWorker();
    if (highlightWorker && perFileHighlightLines.length > 0) {
      for (const batch of perFileHighlightLines) {
        highlightWorker.postMessage({
          requestId: currentHighlightRequestId,
          renderToken,
          language: batch.language,
          lines: batch.lines,
          fileCount: files.length,
        });
      }
    }
  } catch (error) {
    console.error("cmux diff render failed", error);
    root.textContent = "";
    const errorState = document.createElement("div");
    errorState.className = "empty-state";
    errorState.textContent = `Diff render failed: ${error && error.message ? error.message : String(error)}`;
    root.appendChild(errorState);
    window.cmuxReportError?.("render-error", error);
  }
};

if (state.currentPayload) {
  window.cmuxDiffRender(state.currentPayload);
}

function renderFile(file, fileIndex, totalFiles) {
  const container = document.createElement("section");
  container.className = "diff-file";
  container.dataset.filePath = file.path;

  const fileHeader = renderFileHeader(file, totalFiles);
  container.appendChild(fileHeader.button);

  const body = document.createElement("div");
  body.className = "diff-file-body";
  if (state.collapsedPaths?.[file.path]) {
    setFileBodyCollapsed(body, true, false);
  }

  if (file.isBinary) {
    const binaryState = document.createElement("div");
    binaryState.className = "binary-state";
    binaryState.textContent = "Binary file changed";
    body.appendChild(binaryState);
    container.appendChild(body);
    return { element: container, highlightLines: [] };
  }

  if (!Array.isArray(file.hunks) || file.hunks.length === 0) {
    const emptyState = document.createElement("div");
    emptyState.className = "empty-state";
    emptyState.textContent = "No textual diff available.";
    body.appendChild(emptyState);
    container.appendChild(body);
    return { element: container, highlightLines: [] };
  }

  const highlightLines = [];

  file.hunks.forEach((hunk, hunkIndex) => {
    const hunkElement = document.createElement("section");
    hunkElement.className = "hunk";

    hunkElement.appendChild(renderHunkHeader(hunk));

    const rows = document.createElement("div");
    rows.className = "diff-rows";

    const wordDiffMarkup = buildWordDiffMarkup(hunk.lines ?? []);
    (hunk.lines ?? []).forEach((line, lineIndex) => {
      const row = document.createElement("div");
      row.className = `diff-row diff-row--${line.kind}`;

      row.appendChild(lineNumberCell(line.oldLineNumber));
      row.appendChild(lineNumberCell(line.newLineNumber));

      const codeCell = document.createElement("div");
      codeCell.className = "line-code";

      const codeInner = document.createElement("div");
      codeInner.className = "line-code-inner";
      const highlightId = `${fileIndex}:${hunkIndex}:${lineIndex}`;
      const wordDiffKey = String(lineIndex);

      if (line.isNoNewlineMarker) {
        codeInner.textContent = line.text;
      } else if (wordDiffMarkup.has(wordDiffKey)) {
        codeInner.innerHTML = wordDiffMarkup.get(wordDiffKey);
      } else {
        codeInner.textContent = line.text;
        codeInner.id = `hl-${highlightId}`;
        highlightLines.push({
          id: highlightId,
          text: line.text,
          kind: line.kind,
        });
      }

      codeCell.appendChild(codeInner);
      row.appendChild(codeCell);
      rows.appendChild(row);
    });

    hunkElement.appendChild(rows);
    body.appendChild(hunkElement);
  });

  container.appendChild(body);
  return { element: container, highlightLines };
}

function renderFileHeader(file, totalFiles) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "diff-file-header";

  const leading = document.createElement("div");
  leading.className = "diff-file-header-leading";
  const pathParts = splitDisplayPath(file.displayPath);

  if (pathParts.directory) {
    const directory = document.createElement("span");
    directory.className = "diff-file-directory";
    directory.textContent = `${pathParts.directory}/`;
    leading.appendChild(directory);
  }

  const fileName = document.createElement("span");
  fileName.className = "diff-file-name";
  fileName.textContent = pathParts.fileName;
  leading.appendChild(fileName);

  button.appendChild(leading);

  const trailing = document.createElement("div");
  trailing.className = "diff-file-header-trailing";

  const stats = document.createElement("div");
  stats.className = "diff-file-stats";
  if (file.additions > 0) {
    const additions = document.createElement("span");
    additions.className = "diff-stat diff-stat--add";
    additions.textContent = `+${file.additions}`;
    stats.appendChild(additions);
  }
  if (file.deletions > 0) {
    const deletions = document.createElement("span");
    deletions.className = "diff-stat diff-stat--del";
    deletions.textContent = `-${file.deletions}`;
    stats.appendChild(deletions);
  }
  trailing.appendChild(stats);

  button.appendChild(trailing);

  if (totalFiles > 1) {
    button.addEventListener("click", () => {
      const nextCollapsed = !Boolean(state.collapsedPaths?.[file.path]);
      state.collapsedPaths[file.path] = nextCollapsed;
      const body = button.nextElementSibling;
      if (body) {
        setFileBodyCollapsed(body, nextCollapsed, true);
      }
    });
  } else {
    button.disabled = true;
  }

  return { button };
}

function visibleFileCount(files) {
  return files.reduce((count, file) => count + (state.collapsedPaths?.[file.path] ? 0 : 1), 0);
}

function renderHunkHeader(hunk) {
  const header = document.createElement("div");
  header.className = "hunk-header";
  header.title = hunk.header;

  return header;
}

function setFileBodyCollapsed(body, collapsed, animated) {
  if (!animated) {
    body.classList.toggle("is-collapsed", collapsed);
    body.style.height = collapsed ? "0px" : "";
    body.style.opacity = collapsed ? "0" : "";
    return;
  }

  const cleanup = () => {
    body.style.height = collapsed ? "0px" : "";
    body.style.opacity = collapsed ? "0" : "";
    body.removeEventListener("transitionend", cleanup);
  };

  body.removeEventListener("transitionend", cleanup);

  if (collapsed) {
    const currentHeight = body.getBoundingClientRect().height || body.scrollHeight;
    body.style.height = `${currentHeight}px`;
    body.style.opacity = "1";
    body.offsetHeight;
    body.classList.add("is-collapsed");
    requestAnimationFrame(() => {
      body.style.height = "0px";
      body.style.opacity = "0";
    });
    body.addEventListener("transitionend", cleanup);
    return;
  }

  body.classList.remove("is-collapsed");
  body.style.height = "0px";
  body.style.opacity = "0";
  body.offsetHeight;
  requestAnimationFrame(() => {
    body.style.height = `${body.scrollHeight}px`;
    body.style.opacity = "1";
  });
  body.addEventListener("transitionend", cleanup);
}

function splitDisplayPath(path) {
  const index = path.lastIndexOf("/");
  if (index === -1) {
    return { directory: "", fileName: path };
  }
  return {
    directory: path.slice(0, index),
    fileName: path.slice(index + 1),
  };
}

function buildWordDiffMarkup(lines) {
  const markup = new Map();
  let index = 0;

  while (index < lines.length) {
    if (lines[index].kind !== "deletion") {
      index += 1;
      continue;
    }

    const deletions = [];
    while (index < lines.length && lines[index].kind === "deletion") {
      deletions.push({ line: lines[index], index });
      index += 1;
    }

    const additions = [];
    while (index < lines.length && lines[index].kind === "addition") {
      additions.push({ line: lines[index], index });
      index += 1;
    }

    if (deletions.length === 0 || additions.length === 0 || deletions.length !== additions.length) {
      continue;
    }

    for (let pairIndex = 0; pairIndex < deletions.length; pairIndex += 1) {
      const deletion = deletions[pairIndex];
      const addition = additions[pairIndex];
      const pair = computeWordDiffPair(deletion.line.text, addition.line.text);
      if (!pair) {
        continue;
      }
      markup.set(String(deletion.index), pair.oldHTML);
      markup.set(String(addition.index), pair.newHTML);
    }
  }

  return markup;
}

function lineNumberCell(value) {
  const cell = document.createElement("div");
  cell.className = "line-number";
  cell.textContent = value == null ? "" : String(value);
  return cell;
}

function computeWordDiffPair(oldText, newText) {
  if (oldText.length + newText.length > 600) {
    return null;
  }

  const oldTokens = tokenizeDiffText(oldText);
  const newTokens = tokenizeDiffText(newText);
  if (oldTokens.length === 0 || newTokens.length === 0 || oldTokens.length * newTokens.length > 4096) {
    return null;
  }

  const lcs = Array.from({ length: oldTokens.length + 1 }, () => Array(newTokens.length + 1).fill(0));
  for (let oldIndex = oldTokens.length - 1; oldIndex >= 0; oldIndex -= 1) {
    for (let newIndex = newTokens.length - 1; newIndex >= 0; newIndex -= 1) {
      if (oldTokens[oldIndex] === newTokens[newIndex]) {
        lcs[oldIndex][newIndex] = lcs[oldIndex + 1][newIndex + 1] + 1;
      } else {
        lcs[oldIndex][newIndex] = Math.max(lcs[oldIndex + 1][newIndex], lcs[oldIndex][newIndex + 1]);
      }
    }
  }

  let oldIndex = 0;
  let newIndex = 0;
  const oldParts = [];
  const newParts = [];

  while (oldIndex < oldTokens.length && newIndex < newTokens.length) {
    if (oldTokens[oldIndex] === newTokens[newIndex]) {
      const escaped = escapeHTML(oldTokens[oldIndex]);
      oldParts.push(escaped);
      newParts.push(escaped);
      oldIndex += 1;
      newIndex += 1;
      continue;
    }

    if (lcs[oldIndex + 1][newIndex] >= lcs[oldIndex][newIndex + 1]) {
      oldParts.push(`<span class="word-del">${escapeHTML(oldTokens[oldIndex])}</span>`);
      oldIndex += 1;
    } else {
      newParts.push(`<span class="word-add">${escapeHTML(newTokens[newIndex])}</span>`);
      newIndex += 1;
    }
  }

  while (oldIndex < oldTokens.length) {
    oldParts.push(`<span class="word-del">${escapeHTML(oldTokens[oldIndex])}</span>`);
    oldIndex += 1;
  }

  while (newIndex < newTokens.length) {
    newParts.push(`<span class="word-add">${escapeHTML(newTokens[newIndex])}</span>`);
    newIndex += 1;
  }

  return {
    oldHTML: oldParts.join(""),
    newHTML: newParts.join(""),
  };
}

function tokenizeDiffText(text) {
  return text.match(/[A-Za-z0-9_]+|\s+|[^A-Za-z0-9_\s]+/g) ?? [];
}

function escapeHTML(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function cssEscape(value) {
  if (window.CSS?.escape) {
    return window.CSS.escape(value);
  }
  return value.replaceAll("\"", "\\\"");
}

function roundMs(value) {
  return Math.round(value * 100) / 100;
}

function reportPerf(payload) {
  try {
    perfReporter?.postMessage(payload);
  } catch (error) {
    console.error(error);
  }
}
