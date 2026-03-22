const keywordSets = {
  swift: new Set(["actor", "as", "async", "await", "break", "case", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "fallthrough", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "protocol", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"]),
  typescript: new Set(["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "interface", "let", "new", "null", "return", "switch", "throw", "true", "try", "type", "typeof", "undefined", "var", "while"]),
  javascript: new Set(["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "let", "new", "null", "return", "switch", "throw", "true", "try", "undefined", "var", "while"]),
  tsx: new Set(["as", "async", "await", "const", "export", "extends", "false", "for", "from", "function", "if", "import", "interface", "let", "null", "return", "true", "type", "var"]),
  jsx: new Set(["async", "await", "const", "export", "extends", "false", "for", "from", "function", "if", "import", "let", "null", "return", "true", "var"]),
  python: new Set(["and", "as", "assert", "async", "await", "class", "def", "elif", "else", "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]),
  go: new Set(["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]),
  rust: new Set(["as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "trait", "true", "type", "unsafe", "use", "where", "while"]),
  json: new Set(["false", "null", "true"]),
  shell: new Set(["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "return", "then", "while"]),
  yaml: new Set(["false", "null", "true"]),
  toml: new Set(["false", "true"]),
};

const commentPrefixes = {
  swift: ["//"],
  typescript: ["//"],
  javascript: ["//"],
  tsx: ["//"],
  jsx: ["//"],
  python: ["#"],
  ruby: ["#"],
  shell: ["#"],
  yaml: ["#"],
  toml: ["#"],
  go: ["//"],
  rust: ["//"],
  java: ["//"],
  kotlin: ["//"],
  c: ["//"],
  cpp: ["//"],
  css: ["/*"],
  scss: ["//", "/*"],
};

self.onmessage = (event) => {
  const payload = event.data ?? {};
  const language = payload.language ?? "plain";
  const lines = Array.isArray(payload.lines) ? payload.lines : [];
  const highlighted = lines.map((line) => ({
    id: line.id,
    html: highlightLine(line.text ?? "", language),
  }));

  self.postMessage({
    requestId: payload.requestId,
    renderToken: payload.renderToken,
    fileCount: 1,
    lines: highlighted,
  });
};

function highlightLine(text, language) {
  const trimmed = text.trimStart();
  for (const prefix of commentPrefixes[language] ?? []) {
    if (trimmed.startsWith(prefix)) {
      return `<span class="tok-comment">${escapeHTML(text)}</span>`;
    }
  }

  const escaped = escapeHTML(text);
  const placeholders = [];
  let working = escaped.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`/g, (match) => {
    const placeholder = `__CMUX_STR_${placeholders.length}__`;
    placeholders.push(`<span class="tok-string">${match}</span>`);
    return placeholder;
  });

  working = working.replace(/\b\d+(?:\.\d+)?\b/g, '<span class="tok-number">$&</span>');

  const keywords = keywordSets[language];
  if (keywords && keywords.size > 0) {
    const pattern = new RegExp(`\\b(${Array.from(keywords).join("|")})\\b`, "g");
    working = working.replace(pattern, '<span class="tok-keyword">$1</span>');
  }

  return working.replace(/__CMUX_STR_(\d+)__/g, (_, index) => placeholders[Number(index)] ?? "");
}

function escapeHTML(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}
