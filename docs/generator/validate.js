// Lightweight package check (python validate.py unavailable here): every XML part well-formed, rels targets exist, no bad colors.
const JSZip = require(require.resolve("jszip", { paths: [require.resolve("pptxgenjs")] })); const { XMLValidator } = require("fast-xml-parser"); const fs = require("fs");
(async () => { const z = await JSZip.loadAsync(fs.readFileSync(process.argv[2])); let bad = 0; const names = Object.keys(z.files);
  for (const n of names) { if (!/\.(xml|rels)$/.test(n)) continue; const x = await z.file(n).async("string"); const v = XMLValidator.validate(x); if (v !== true) { bad++; console.log("XML error", n, JSON.stringify(v.err)); }
    if (/val="#|srgbClr val="[0-9A-Fa-f]{8}"/.test(x)) { bad++; console.log("bad color", n); }
    if (n.endsWith(".rels")) for (const m of x.matchAll(/Target="([^"]+)"[^>]*?(TargetMode="External")?/g)) { if (m[2]) continue; const base = n.replace(/_rels\/[^/]+$/, ""); const t = new URL(m[1], "http://x/" + base).pathname.slice(1); if (!z.files[t]) { bad++; console.log("missing rel target", n, "->", t); } } }
  const pres = await z.file("ppt/presentation.xml").async("string"); console.log("slides:", (pres.match(/<p:sldId /g) || []).length, "| problems:", bad); process.exit(bad ? 1 : 0); })();
