const state = window.cmuxDiffState;
const root = document.getElementById("root");
const perfReporter = window.webkit?.messageHandlers?.cmuxDiffPerf;
const worker = new Worker(new URL("./cmux-diff-highlight-worker.js", import.meta.url));

let currentHighlightRequestId = 0;
let currentHighlightToken = 0;

worker.onmessage = (event) => {
  const payload = event.data ?? {};
  if (payload.requestId !== currentHighlightRequestId || payload.renderToken !== currentHighlightToken) {
    return;
  }

  const startedAt = performance.now();
  const highlightedLines = payload.lines ?? [];
  for (const line of highlightedLines) {
    const node = document.querySelector(`[data-highlight-id="${cssEscape(line.id)}"]`);
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

window.cmuxDiffRender = function(payload) {
  state.currentPayload = payload;
  currentHighlightToken += 1;
  const renderToken = currentHighlightToken;
  document.documentElement.dataset.theme = payload.isDarkMode ? "dark" : "light";

  const renderStartedAt = performance.now();
  root.textContent = "";

  if (!payload.file) {
    reportPerf({
      type: "render-empty",
      mode: "selected-file",
      totalFiles: 0,
      visibleFiles: 0,
      durationMs: 0,
    });
    return;
  }

  const { element, highlightLines } = renderFile(payload.file);
  root.appendChild(element);

  const renderDurationMs = roundMs(performance.now() - renderStartedAt);
  reportPerf({
    type: "render-ready",
    mode: "selected-file",
    totalFiles: 1,
    visibleFiles: 1,
    durationMs: renderDurationMs,
  });

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      reportPerf({
        type: "first-paint",
        mode: "selected-file",
        totalFiles: 1,
        visibleFiles: 1,
        durationMs: roundMs(performance.now() - renderStartedAt),
      });
    });
  });

  currentHighlightRequestId += 1;
  if (highlightLines.length > 0) {
    worker.postMessage({
      requestId: currentHighlightRequestId,
      renderToken,
      language: payload.file.language,
      lines: highlightLines,
    });
  }
};

function renderFile(file) {
  const container = document.createElement("section");
  container.className = "diff-file";

  if (file.isBinary) {
    const binaryState = document.createElement("div");
    binaryState.className = "binary-state";
    binaryState.textContent = "Binary file changed";
    container.appendChild(binaryState);
    return { element: container, highlightLines: [] };
  }

  if (!Array.isArray(file.hunks) || file.hunks.length === 0) {
    const emptyState = document.createElement("div");
    emptyState.className = "empty-state";
    emptyState.textContent = "No textual diff available.";
    container.appendChild(emptyState);
    return { element: container, highlightLines: [] };
  }

  const highlightLines = [];

  file.hunks.forEach((hunk, hunkIndex) => {
    const hunkElement = document.createElement("section");
    hunkElement.className = "hunk";

    const header = document.createElement("div");
    header.className = "hunk-header";
    header.textContent = hunk.header;
    hunkElement.appendChild(header);

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
      const highlightId = `${hunkIndex}:${lineIndex}`;
      const wordDiffKey = String(lineIndex);

      if (line.isNoNewlineMarker) {
        codeInner.textContent = line.text;
      } else if (wordDiffMarkup.has(wordDiffKey)) {
        codeInner.innerHTML = wordDiffMarkup.get(wordDiffKey);
      } else {
        codeInner.textContent = line.text;
        codeInner.dataset.highlightId = highlightId;
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
    container.appendChild(hunkElement);
  });

  return { element: container, highlightLines };
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
