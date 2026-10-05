# Vendored libraries — the ⌘3 viewer's markdown and code rendering

markdown-it, KaTeX and Prism are MIT-licensed, SheetJS Apache-2.0; all were downloaded **from their own published
distributions** on 2026-10-05, not copied from another project. That matters:
the session-dashboard kit uses the first three, but the kit is private
("may not redistribute"), its `prism.js` carries locally written grammars, and
Marina's repository is public. Nothing here came from the kit.

| Library | Version | Licence | Source | Modified |
|---|---|---|---|---|
| markdown-it | 14.1.0 | MIT, `LICENSE-markdown-it.txt` | `cdn.jsdelivr.net/npm/markdown-it@14.1.0/dist/markdown-it.min.js` | no |
| KaTeX | 0.17.0 | MIT, `katex/LICENSE` | `cdn.jsdelivr.net/npm/katex@0.17.0/dist/` — `katex.min.js`, `katex.min.css`, `fonts/` | **fonts pruned** — see below |
| Prism | 1.30.0 | MIT, `LICENSE-prism.txt` | `cdn.jsdelivr.net/npm/prismjs@1.30.0/components/prism-<name>.min.js` | no |
| SheetJS Community Edition | 0.20.3 | Apache-2.0, `LICENSE-sheetjs.txt` | `cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js` (SheetJS publishes on its own CDN, not npm) | no |

**KaTeX fonts:** only the `.woff2` files are kept. The stylesheet lists woff2,
woff and ttf for every face, and WebKit loads the first format it supports,
which is always woff2 — the other 40 files were dead weight (≈1 MB).

**Prism components**, loaded in this order because later grammars extend
earlier ones: core, markup, css, clike, javascript, typescript, c, cpp,
python, bash, json, yaml, toml, markdown, latex, swift, diff, makefile.

**Fortran is Marina's own**, in `../fortran.js`. Upstream Prism has no Fortran
grammar; it was written fresh for Marina, not taken from anywhere.

To update a library, fetch the new version from the same URL pattern and change
the version here. Nothing in these files is edited.

**SheetJS is loaded lazily** by `viewer.js`, the first time a spreadsheet is
shown, not by `viewer.html`: at 930 KB it would otherwise be parsed for every
markdown note and source file.
