"use strict";
const fs = require("fs");
const { META, STATS, DIAGRAMS, RULES, ACTIONS, SECTIONS } = require("./content");
const { route, labelPos } = require("./diagram");

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const idr = (n) => "IDR " + Number(n).toLocaleString("id-ID");

function svg(key) {
  const d = DIAGRAMS[key];
  const W = 1000, H = d.h;
  const parts = [`<svg viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="dg-${key}-t" class="diagram"><title id="dg-${key}-t">${esc(d.title)}</title>`,
    `<defs><marker id="ar-${key}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" class="ah"/></marker></defs>`];
  for (const e of d.edges) {
    const pts = route(d, e);
    parts.push(`<polyline points="${pts.map((p) => `${p.x},${p.y}`).join(" ")}" class="edge${e.dashed ? " dashed" : ""}" marker-end="url(#ar-${key})"/>`);
  }
  for (const n of d.nodes) {
    parts.push(`<g class="node k-${n.kind}"><rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" rx="12"/>` +
      `<text x="${n.x + n.w / 2}" y="${n.y + n.h / 2 - (n.sub ? 9 : -5)}" class="nl">${esc(n.label)}</text>` +
      (n.sub ? wrapSvg(n.sub, n.x + n.w / 2, n.y + n.h / 2 + 12, n.w - 16) : "") + `</g>`);
  }
  for (const e of d.edges) if (e.label) {
    const p0 = labelPos(route(d, e)); const p = { x: p0.x, y: p0.y + (e.ldy || 0) }; const w = e.label.length * 6.4 + 12;
    parts.push(`<g class="el"><rect x="${p.x - w / 2}" y="${p.y - 10}" width="${w}" height="20" rx="6"/><text x="${p.x}" y="${p.y + 4}">${esc(e.label)}</text></g>`);
  }
  parts.push("</svg>");
  return `<figure class="figure">${parts.join("")}<figcaption>${esc(d.title)}</figcaption></figure>`;
}
function wrapSvg(text, cx, y, width) { // naive word wrap at ~6.2px per char for 11px text
  const max = Math.max(10, Math.floor(width / 6.2)); const words = text.split(" "); const lines = []; let cur = "";
  for (const w of words) { if ((cur + " " + w).trim().length > max) { lines.push(cur.trim()); cur = w; } else cur += " " + w; }
  if (cur.trim()) lines.push(cur.trim());
  return lines.slice(0, 2).map((l, i) => `<text x="${cx}" y="${y + i * 14}" class="ns">${esc(l)}</text>`).join("");
}

const table = (t) => `<div class="table-wrap"><table><thead><tr>${t.head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${
  t.rows.map((r) => `<tr>${r.map((c, i) => `<td${i === 0 ? ' class="strong"' : ""}>${c === "Lulus" ? '<span class="pill ok">✓ Lulus</span>' : esc(c)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`;
const bullets = (b) => `<ul>${b.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>`;

function section(s, i) {
  const out = [`<section id="${s.id}"><h2><span class="num">${String(i + 1).padStart(2, "0")}</span>${esc(s.title)}</h2>`];
  (s.paras || []).forEach((p) => out.push(`<p>${esc(p)}</p>`));
  if (s.cards) out.push(`<div class="cards">${s.cards.map(([t, d]) => `<div class="card"><h3>${esc(t)}</h3><p>${esc(d)}</p></div>`).join("")}</div>`);
  (s.after || []).forEach((p) => out.push(`<p>${esc(p)}</p>`));
  if (s.diagram) out.push(svg(s.diagram));
  if (s.steps) out.push(`<ol class="steps">${s.steps.map(([t, d]) => `<li><strong>${esc(t)}</strong><span>${esc(d)}</span></li>`).join("")}</ol>`);
  if (s.rules) out.push(`<h3>Aturan deterministik</h3>` + table({ head: ["Indikator", "Bobot", "Kondisi"], rows: RULES }));
  if (s.table) out.push(table(s.table));
  (s.sub || []).forEach((x) => out.push(`<h3>${esc(x.title)}</h3>${bullets(x.bullets)}`));
  if (s.actions) out.push(`<h3>Rekomendasi tindakan</h3><div class="actions">${ACTIONS.map(([a, c, r]) =>
    `<div class="action a-${a.toLowerCase()}"><div class="aname">${a}</div><div class="acond">${esc(c)}</div><div class="ares">${esc(r)}</div></div>`).join("")}</div>`);
  if (s.bullets) out.push(bullets(s.bullets));
  if (s.code) out.push(`<pre><code>${esc(s.code)}</code></pre>`);
  if (s.note) out.push(`<aside class="note">${esc(s.note)}</aside>`);
  out.push("</section>");
  return out.join("\n");
}

const tiles = [
  [String(STATS.analyzed), "transaksi dianalisis", `${STATS.analyzedLive} via API live`],
  [String(STATS.fraud + STATS.gambling), "terdeteksi fraud / judi", `${STATS.fraud} fraud · ${STATS.gambling} judi`],
  ["IDR " + (STATS.riskFraudIdr / 1e6).toFixed(1).replace(".", ",") + " jt", "nilai berisiko fraud", `judi ${idr(STATS.riskGamblingIdr)}`],
  [`${STATS.e2ePass}/${STATS.e2eTotal}`, "pengujian E2E lulus", "13 Nov 2026"],
];

const html = `<!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Payment Intelligence Docs</title>
<style>
:root{--bg:#ffffff;--surface:#f6f7f9;--surface2:#eef0f3;--border:#e1e4e8;--text:#15171b;--muted:#5d636d;--accent:#ffb21e;--accent-ink:#1d1a12;--link:#8a5a00;
--k-actor-f:#eef0f3;--k-actor-s:#8a919c;--k-edge-f:#e8eef7;--k-edge-s:#5b7ba8;--k-boomi-f:#fff3d6;--k-boomi-s:#d99a00;--k-data-f:#dff3ee;--k-data-s:#1f8a70;--k-ai-f:#ece6fa;--k-ai-s:#6b4fc7;--k-ext-f:#fde7de;--k-ext-s:#d0603a;
--approve:#1f8a70;--review:#c98500;--flag:#d0603a;--block:#c0392b;--ok:#1f8a70}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#121316;--surface:#1a1c20;--surface2:#23262b;--border:#30343a;--text:#eceef1;--muted:#a3a9b3;--link:#ffc54d;
--k-actor-f:#262a30;--k-actor-s:#8a919c;--k-edge-f:#1d2633;--k-edge-s:#7c9cc9;--k-boomi-f:#33290f;--k-boomi-s:#ffb21e;--k-data-f:#12302a;--k-data-s:#3cc29f;--k-ai-f:#251f3a;--k-ai-s:#9d86ef;--k-ext-f:#3a2018;--k-ext-s:#f08a63;
--approve:#3cc29f;--review:#f0b429;--flag:#f08a63;--block:#ef6b5e;--ok:#3cc29f}}
:root[data-theme="dark"]{--bg:#121316;--surface:#1a1c20;--surface2:#23262b;--border:#30343a;--text:#eceef1;--muted:#a3a9b3;--link:#ffc54d;
--k-actor-f:#262a30;--k-actor-s:#8a919c;--k-edge-f:#1d2633;--k-edge-s:#7c9cc9;--k-boomi-f:#33290f;--k-boomi-s:#ffb21e;--k-data-f:#12302a;--k-data-s:#3cc29f;--k-ai-f:#251f3a;--k-ai-s:#9d86ef;--k-ext-f:#3a2018;--k-ext-s:#f08a63;
--approve:#3cc29f;--review:#f0b429;--flag:#f08a63;--block:#ef6b5e;--ok:#3cc29f}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif}
a{color:var(--link)}
.hero{background:#15171b;color:#fff;padding:56px 16px 40px}
.hero-inner,.layout{max-width:1180px;margin:0 auto}
.brand{display:inline-flex;align-items:center;gap:10px;font-weight:800;letter-spacing:.04em;font-size:14px}
.mark{display:inline-grid;place-items:center;width:34px;height:34px;border-radius:9px;background:var(--accent);color:var(--accent-ink);font-weight:900}
.hero h1{font-size:clamp(32px,5vw,52px);line-height:1.1;margin:18px 0 10px}
.hero p.lead{font-size:18px;color:#c9ccd2;max-width:760px;margin:0}
.meta{margin-top:18px;color:#9aa0aa;font-size:13px}
.tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-top:28px}
.tile{background:#1f2227;border:1px solid #2c3036;border-radius:12px;padding:14px 16px}
.tile b{display:block;font-size:26px;color:var(--accent);line-height:1.2}
.tile span{display:block;font-size:13px;color:#e3e5e9}.tile small{color:#9aa0aa;font-size:12px}
.layout{display:grid;grid-template-columns:240px minmax(0,1fr);gap:40px;padding:32px 16px 64px}
nav.toc{position:sticky;top:16px;align-self:start;font-size:14px}
nav.toc h4{margin:0 0 8px;font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
nav.toc ol{list-style:none;margin:0;padding:0}nav.toc li a{display:block;padding:5px 10px;border-radius:8px;color:var(--text);text-decoration:none}
nav.toc li a:hover{background:var(--surface2)}
.theme-btn{margin-top:14px;font:inherit;font-size:13px;border:1px solid var(--border);background:var(--surface);color:var(--text);border-radius:999px;padding:6px 12px;cursor:pointer}
section{padding-top:8px;margin-bottom:40px;scroll-margin-top:16px}
h2{font-size:28px;line-height:1.25;margin:0 0 14px;display:flex;align-items:baseline;gap:12px}
h2 .num{font-size:14px;font-weight:800;color:var(--accent-ink);background:var(--accent);border-radius:8px;padding:2px 8px}
h3{font-size:18px;margin:24px 0 8px}
p{margin:0 0 12px;color:var(--text)}ul{padding-left:22px;margin:0 0 12px}li{margin:4px 0}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin:12px 0 16px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:16px}.card h3{margin:0 0 6px;font-size:16px}.card p{margin:0;color:var(--muted);font-size:15px}
.table-wrap{overflow-x:auto;border:1px solid var(--border);border-radius:12px;margin:12px 0 16px}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--border);vertical-align:top}
th{background:var(--surface2);font-weight:700;white-space:nowrap}tr:last-child td{border-bottom:0}td.strong{font-weight:600;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
.pill{display:inline-block;border-radius:999px;padding:1px 10px;font-size:12px;font-weight:700;white-space:nowrap}.pill.ok{color:var(--ok);border:1px solid var(--ok)}
.steps{counter-reset:s;list-style:none;padding:0;display:grid;gap:10px}
.steps li{counter-increment:s;display:grid;grid-template-columns:36px 1fr;gap:4px 12px;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:12px 14px}
.steps li::before{content:counter(s);grid-row:span 2;display:grid;place-items:center;width:30px;height:30px;border-radius:50%;background:var(--accent);color:var(--accent-ink);font-weight:800}
.steps span{color:var(--muted);font-size:15px}
.actions{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:12px 0 16px}
.action{border:1px solid var(--border);border-radius:12px;padding:14px;background:var(--surface)}
.aname{font-weight:900;letter-spacing:.04em}.acond{font-size:14px;margin:6px 0}.ares{font-size:13px;color:var(--muted)}
.a-approve .aname{color:var(--approve)}.a-review .aname{color:var(--review)}.a-flag .aname{color:var(--flag)}.a-block .aname{color:var(--block)}
.note{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:12px 16px;color:var(--muted);font-size:14px;margin:12px 0}
.note::before{content:"Catatan · ";font-weight:700;color:var(--text)}
pre{background:#15171b;color:#e6e8eb;border-radius:12px;padding:16px;overflow-x:auto;font-size:13px;line-height:1.5}
.figure{margin:16px 0 20px;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:16px}
.figure figcaption{font-size:13px;color:var(--muted);margin-top:8px;text-align:center}
.diagram{width:100%;height:auto;display:block}
.diagram .edge{fill:none;stroke:var(--muted);stroke-width:2}.diagram .edge.dashed{stroke-dasharray:6 5}.diagram .ah{fill:var(--muted)}
.diagram .node rect{stroke-width:2}
.diagram .nl{font:700 14px system-ui,Arial,sans-serif;text-anchor:middle;fill:var(--text)}
.diagram .ns{font:11px system-ui,Arial,sans-serif;text-anchor:middle;fill:var(--muted)}
.diagram .el rect{fill:var(--bg);stroke:var(--border)}.diagram .el text{font:600 11px system-ui,Arial,sans-serif;text-anchor:middle;fill:var(--text)}
${["actor", "edge", "boomi", "data", "ai", "ext"].map((k) => `.diagram .k-${k} rect{fill:var(--k-${k}-f);stroke:var(--k-${k}-s)}`).join("")}
.legend{display:flex;flex-wrap:wrap;gap:8px 16px;font-size:13px;color:var(--muted);margin-top:10px;justify-content:center}
.legend i{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:6px;vertical-align:-1px;border:2px solid}
footer{border-top:1px solid var(--border);color:var(--muted);font-size:13px;padding:20px 16px;text-align:center}
@media (max-width:900px){.layout{grid-template-columns:1fr}nav.toc{position:static}.tiles,.actions{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:480px){.tiles,.actions{grid-template-columns:1fr}h2{font-size:23px}.hero{padding-top:40px}}
@media print{nav.toc,.theme-btn{display:none}.layout{display:block}.hero{-webkit-print-color-adjust:exact;print-color-adjust:exact}section{break-inside:avoid-page}}
</style>
</head>
<body>
<header class="hero"><div class="hero-inner">
  <div class="brand"><span class="mark" aria-hidden="true">gj</span>${esc(META.brand)}</div>
  <h1>${esc(META.title)}</h1>
  <p class="lead">${esc(META.subtitle)}</p>
  <div class="meta">${esc(META.docName)} · ${esc(META.version)} · ${esc(META.date)} · ${esc(META.env)}</div>
  <div class="tiles">${tiles.map(([b, s, m]) => `<div class="tile"><b>${esc(b)}</b><span>${esc(s)}</span><small>${esc(m)}</small></div>`).join("")}</div>
</div></header>
<div class="layout">
  <nav class="toc" aria-label="Daftar isi"><h4>Daftar isi</h4><ol>${SECTIONS.map((s, i) => `<li><a href="#${s.id}">${i + 1}. ${esc(s.title)}</a></li>`).join("")}</ol>
  <button class="theme-btn" type="button" id="theme">Ganti tema terang/gelap</button></nav>
  <main>
${SECTIONS.map(section).join("\n")}
  <div class="legend" aria-label="Legenda diagram">${[["actor", "Pengguna"], ["edge", "Portal / proxy"], ["boomi", "Boomi process"], ["data", "PostgreSQL / data"], ["ai", "Agent Garden"], ["ext", "Notifikasi / keluaran"]].map(([k, l]) => `<span><i style="background:var(--k-${k}-f);border-color:var(--k-${k}-s)"></i>${l}</span>`).join("")}</div>
  </main>
</div>
<footer>${esc(META.brand)} · ${esc(META.title)} — ${esc(META.docName)} ${esc(META.version)} · ${esc(META.date)}. Angka diambil dari Query API environment TEST.</footer>
<script>
(function(){var b=document.getElementById("theme");b.addEventListener("click",function(){var r=document.documentElement;var dark=r.getAttribute("data-theme")==="dark"||(!r.getAttribute("data-theme")&&matchMedia("(prefers-color-scheme: dark)").matches);r.setAttribute("data-theme",dark?"light":"dark");try{localStorage.setItem("pi-doc-theme",r.getAttribute("data-theme"))}catch(e){}});try{var t=localStorage.getItem("pi-doc-theme");if(t)document.documentElement.setAttribute("data-theme",t)}catch(e){}})();
</script>
</body>
</html>
`;
fs.writeFileSync(process.argv[2], html);
console.log("wrote", process.argv[2], html.length, "bytes");
