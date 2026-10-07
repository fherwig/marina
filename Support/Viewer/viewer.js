/* Marina's ⌘3 viewer, for the files a plain text view does badly: markdown,
   rendered with maths, and source code, highlighted by language.

   The Swift side loads this page ONCE per viewer and then calls
   marinaRender(payload) for each file, so arrowing down a folder of notes swaps
   the content instead of reloading WebKit every time.

     payload = { kind: "markdown" | "code", text, lang, dir }

   `dir` is the file's folder, so relative images and links resolve against
   where the file lives rather than against this page. */
(function () {
  "use strict";

  var doc = document.getElementById("doc");
  var MD = window.markdownit({
    html: false,          // a note is not a web page: no raw HTML, no scripts in it
    linkify: true,
    highlight: function (code, lang) {
      return highlighted(code, lang) || "";   // "" → markdown-it escapes it itself
    },
  });

  // ── Maths ────────────────────────────────────────────────────────────────
  // Pulled out BEFORE markdown sees the text: markdown would otherwise read the
  // underscores and asterisks of a formula as emphasis. Each formula becomes a
  // placeholder that survives the parse untouched, and is swapped for KaTeX's
  // output afterwards. Code is skipped on the way, since a $ there is code.

  var OPEN = "\u0002", CLOSE = "\u0003";

  function extractMaths(text, out) {
    var result = "", i = 0, n = text.length;
    function hold(tex, display) {
      out.push({ tex: tex, display: display });
      return OPEN + (out.length - 1) + CLOSE;
    }
    function copyThrough(closer, from) {
      var end = text.indexOf(closer, from);
      var stop = end < 0 ? n : end + closer.length;
      result += text.slice(i, stop);
      i = stop;
    }
    while (i < n) {
      var ch = text[i], end;
      if (text.startsWith("```", i) || text.startsWith("~~~", i)) {
        copyThrough(text.substr(i, 3), i + 3); continue;
      }
      if (ch === "`") { copyThrough("`", i + 1); continue; }
      if (text.startsWith("$$", i) && (end = text.indexOf("$$", i + 2)) > 0) {
        result += hold(text.slice(i + 2, end), true); i = end + 2; continue;
      }
      if (text.startsWith("\\[", i) && (end = text.indexOf("\\]", i + 2)) > 0) {
        result += hold(text.slice(i + 2, end), true); i = end + 2; continue;
      }
      if (text.startsWith("\\(", i) && (end = text.indexOf("\\)", i + 2)) > 0) {
        result += hold(text.slice(i + 2, end), false); i = end + 2; continue;
      }
      // $…$ inline. A dollar in prose ("$5 and $10") must not open a formula:
      // the opener may not be followed by a space, the closer may not follow a
      // space or precede a digit, and the formula may wrap a line but never a
      // paragraph — hard-wrapped notes do break formulas across lines.
      if (ch === "$" && text[i - 1] !== "\\" && i + 1 < n && !/\s/.test(text[i + 1])) {
        var j = i + 1, found = -1;
        while (j < n) {
          if (text[j] === "\n" && /^[ \t]*\n/.test(text.slice(j + 1))) break;
          if (text[j] === "$" && text[j - 1] !== " " && text[j - 1] !== "\\"
              && !/\d/.test(text[j + 1] || "")) { found = j; break; }
          j++;
        }
        if (found > 0) { result += hold(text.slice(i + 1, found), false); i = found + 1; continue; }
      }
      result += ch; i++;
    }
    return result;
  }

  function renderMaths(m) {
    try {
      return katex.renderToString(m.tex, { displayMode: m.display, throwOnError: false });
    } catch (_) {
      return escapeHTML((m.display ? "$$" : "$") + m.tex + (m.display ? "$$" : "$"));
    }
  }

  // ── Code ─────────────────────────────────────────────────────────────────

  // Prism takes seconds on a multi-megabyte file and the page freezes while it
  // does. Above this, show the text plain — still with line numbers.
  var HIGHLIGHT_LIMIT = 400 * 1024;

  function highlighted(code, lang) {
    var grammar = lang && Prism.languages[lang];
    if (!grammar || code.length > HIGHLIGHT_LIMIT) return null;
    try { return Prism.highlight(code, grammar, lang); } catch (_) { return null; }
  }

  function renderCode(text, lang) {
    var lines = text.split("\n");
    if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
    var numbers = [];
    for (var k = 1; k <= lines.length; k++) numbers.push(k);
    var body = highlighted(text, lang) || escapeHTML(text);
    return '<div class="code"><pre class="gutter" aria-hidden="true">' + numbers.join("\n")
         + '</pre><pre class="src language-' + (lang || "none") + '"><code>' + body
         + "</code></pre></div>";
  }

  // ── Paths ────────────────────────────────────────────────────────────────
  // Relative images and links point into the file's own folder.

  // Only LOCAL references are touched. A URL with a scheme (https:, mailto:)
  // or a #fragment is left exactly as written: decoding one would mangle a
  // legitimate %20 in it.
  function absolute(ref, dir) {
    if (!ref || /^[a-z][a-z0-9+.-]*:/i.test(ref) || ref[0] === "#") return ref;
    var raw = ref;
    try { raw = decodeURIComponent(ref); } catch (_) { /* a stray % — keep as written */ }
    var path = raw[0] === "/" ? raw : dir.replace(/\/$/, "") + "/" + raw;
    return "file://" + path.split("/").map(encodeURIComponent).join("/");
  }

  function rewritePaths(root, dir) {
    root.querySelectorAll("img[src]").forEach(function (img) {
      img.setAttribute("src", absolute(img.getAttribute("src"), dir));
    });
    root.querySelectorAll("a[href]").forEach(function (a) {
      a.setAttribute("href", absolute(a.getAttribute("href"), dir));
    });
  }

  function escapeHTML(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ── Spreadsheets ─────────────────────────────────────────────────────────
  // SheetJS reads xlsx, xlsm, xls and ods with one engine. It is 930 KB, so
  // it is fetched the first time a spreadsheet is shown rather than with the
  // page — markdown and code never pay for it.

  var ROW_LIMIT = 2000, COL_LIMIT = 100;
  var sheetsLoading = null;

  function withSheetJS(then) {
    if (window.XLSX) return then();
    if (!sheetsLoading) {
      sheetsLoading = [];
      var s = document.createElement("script");
      s.src = "vendor/xlsx.full.min.js";
      s.onload = function () { sheetsLoading.forEach(function (f) { f(); }); sheetsLoading = null; };
      s.onerror = function () { doc.innerHTML = '<p class="note">The spreadsheet reader failed to load.</p>'; };
      document.head.appendChild(s);
    }
    sheetsLoading.push(then);
  }

  function renderSheets(p) {
    var book;
    try {
      // cellDates: a date cell shows as a date, not as Excel's day count
      book = XLSX.read(p.data, { type: "base64", cellDates: true, dense: true });
    } catch (e) {
      doc.innerHTML = '<p class="note">Could not read this workbook: ' + escapeHTML(e.message) + "</p>";
      return;
    }
    var tabs = book.SheetNames.map(function (name, i) {
      return '<button data-i="' + i + '"' + (i ? "" : ' class="on"') + ">" + escapeHTML(name) + "</button>";
    }).join("");
    doc.className = "sheet";
    doc.innerHTML = (book.SheetNames.length > 1 ? '<nav class="tabs">' + tabs + "</nav>" : "")
                  + '<div id="sheet"></div>';
    function show(i) {
      var ws = book.Sheets[book.SheetNames[i]];
      var out = document.getElementById("sheet");
      if (!ws || !ws["!ref"]) { out.innerHTML = '<p class="note">This sheet is empty.</p>'; return; }
      // a huge sheet is cut to its top-left corner and says so: laying out
      // 100 000 rows of HTML would freeze the pane for a long time
      var range = XLSX.utils.decode_range(ws["!ref"]);
      var rows = range.e.r - range.s.r + 1, cols = range.e.c - range.s.c + 1;
      var shown = { s: range.s, e: { r: Math.min(range.e.r, range.s.r + ROW_LIMIT - 1),
                                     c: Math.min(range.e.c, range.s.c + COL_LIMIT - 1) } };
      var full = ws["!ref"];
      ws["!ref"] = XLSX.utils.encode_range(shown);
      var table = XLSX.utils.sheet_to_html(ws, { header: "", footer: "", editable: false });
      ws["!ref"] = full;
      var cut = rows > ROW_LIMIT || cols > COL_LIMIT;
      out.innerHTML = (cut ? '<p class="note">Showing the first ' + Math.min(rows, ROW_LIMIT)
                       + " of " + rows + " rows and " + Math.min(cols, COL_LIMIT) + " of "
                       + cols + " columns.</p>" : "") + table;
      doc.querySelectorAll(".tabs button").forEach(function (b) {
        b.classList.toggle("on", +b.dataset.i === i);
      });
    }
    doc.querySelectorAll(".tabs button").forEach(function (b) {
      b.onclick = function () { show(+b.dataset.i); };
    });
    show(0);
  }

  // ── Entry point ──────────────────────────────────────────────────────────

  window.marinaRender = function (p) {
    if (p.kind === "sheet") {
      withSheetJS(function () { renderSheets(p); window.scrollTo(0, 0); });
      return;
    }
    if (p.kind === "markdown") {
      var maths = [];
      var html = MD.render(extractMaths(p.text, maths));
      doc.className = "markdown";
      doc.innerHTML = html.replace(new RegExp(OPEN + "(\\d+)" + CLOSE, "g"),
                                   function (_, n) { return renderMaths(maths[+n]); });
      rewritePaths(doc, p.dir || "/");
    } else {
      doc.className = "source";
      doc.innerHTML = renderCode(p.text, p.lang);
    }
    window.scrollTo(0, 0);
  };
})();
