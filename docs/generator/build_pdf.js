"use strict";
const fs = require("fs");
const PDFDocument = require("pdfkit");
const { META, STATS, DIAGRAMS, RULES, ACTIONS, SECTIONS } = require("./content");
const { KIND, route, labelPos } = require("./diagram");

const F = { r: "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", b: "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", m: "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" };
const C = { ink: "#15171b", text: "#1f2328", muted: "#5d636d", border: "#e1e4e8", surface: "#f6f7f9", surface2: "#eef0f3", accent: "#ffb21e", accentInk: "#1d1a12",
  approve: "#1f8a70", review: "#b37700", flag: "#d0603a", block: "#c0392b", ok: "#1f8a70" };
const M = 50; // page margin (pt)

const doc = new PDFDocument({ size: "A4", margins: { top: M, bottom: M + 14, left: M, right: M }, bufferPages: true,
  info: { Title: `${META.title} - ${META.docName}`, Author: META.brand, Subject: META.subtitle } });
doc.registerFont("R", F.r); doc.registerFont("B", F.b); doc.registerFont("Mono", F.m);
doc.pipe(fs.createWriteStream(process.argv[2]));

const W = () => doc.page.width - M * 2;
const bottom = () => doc.page.height - doc.page.margins.bottom;
const ensure = (h) => { if (doc.y + h > bottom()) doc.addPage(); };
const tocEntries = [];
const pending = []; let drawing = false; const origAddPage = doc.addPage.bind(doc);
// A diagram is drawn on its own landscape page at the next natural page break, so text keeps filling the current page.
doc.addPage = function (opts) {
  if (pending.length && !drawing) { drawing = true; while (pending.length) { const [k, t] = pending.shift(); diagramPage(k, t); } drawing = false; }
  return origAddPage(opts);
};

// ---------- cover ----------
doc.rect(0, 0, doc.page.width, doc.page.height).fill(C.ink);
doc.roundedRect(M, 120, 44, 44, 10).fill(C.accent);
doc.font("B").fontSize(18).fillColor(C.accentInk).text("gj", M, 131, { width: 44, align: "center" });
doc.font("B").fontSize(13).fillColor("#ffffff").text(META.brand, M + 58, 134, { characterSpacing: 1.2 });
doc.font("B").fontSize(40).fillColor("#ffffff").text(META.title, M, 210, { width: W() });
doc.font("R").fontSize(15).fillColor("#c9ccd2").text(META.subtitle, M, doc.y + 8, { width: W() - 40, lineGap: 3 });
doc.font("B").fontSize(13).fillColor(C.accent).text(META.docName, M, doc.y + 28);
// stat tiles
const tiles = [[String(STATS.analyzed), "transaksi dianalisis"], [String(STATS.fraud + STATS.gambling), "fraud / judi terdeteksi"],
  ["IDR " + (STATS.riskFraudIdr / 1e6).toFixed(1).replace(".", ",") + " jt", "nilai berisiko fraud"], [`${STATS.e2ePass}/${STATS.e2eTotal}`, "pengujian E2E lulus"]];
const tw = (W() - 3 * 10) / 4; let ty = 520;
tiles.forEach(([b, s], i) => { const x = M + i * (tw + 10);
  doc.roundedRect(x, ty, tw, 78, 8).fill("#1f2227");
  let fz = 18; while (doc.font("B").fontSize(fz).widthOfString(b) > tw - 20 && fz > 11) fz -= 0.5;
  doc.font("B").fontSize(fz).fillColor(C.accent).text(b, x + 10, ty + 14, { width: tw - 20, lineBreak: false });
  doc.font("R").fontSize(9).fillColor("#e3e5e9").text(s, x + 10, ty + 44, { width: tw - 20 }); });
doc.font("R").fontSize(10).fillColor("#9aa0aa").text(`${META.version} · ${META.date}\n${META.env}`, M, 700, { width: W(), lineGap: 3 });

// ---------- TOC placeholder page (filled at the end) ----------
doc.addPage(); const tocPage = doc.bufferedPageRange().count - 1;

// ---------- helpers ----------
function h2(num, title) {
  ensure(70);
  const y = doc.y;
  doc.roundedRect(M, y + 2, 26, 18, 4).fill(C.accent);
  doc.font("B").fontSize(10).fillColor(C.accentInk).text(String(num).padStart(2, "0"), M, y + 6, { width: 26, align: "center" });
  doc.font("B").fontSize(19).fillColor(C.ink).text(title, M + 36, y, { width: W() - 36 });
  doc.moveDown(0.5);
}
function h3(t) { ensure(40); doc.moveDown(0.4); doc.font("B").fontSize(12.5).fillColor(C.ink).text(t, M, doc.y, { width: W() }); doc.moveDown(0.3); }
function para(t) { doc.font("R").fontSize(10.5).fillColor(C.text).text(t, M, doc.y, { width: W(), lineGap: 2.5, align: "left" }); doc.moveDown(0.55); }
function bullets(list) {
  list.forEach((t) => {
    const hgt = doc.font("R").fontSize(10.5).heightOfString(t, { width: W() - 16, lineGap: 2.5 });
    ensure(hgt + 4);
    const y = doc.y;
    doc.circle(M + 4, y + 6.5, 2).fill(C.accent);
    doc.fillColor(C.text).text(t, M + 16, y, { width: W() - 16, lineGap: 2.5 });
    doc.moveDown(0.25);
  });
  doc.moveDown(0.3);
}
function note(t) {
  const hgt = doc.font("R").fontSize(9.5).heightOfString("Catatan · " + t, { width: W() - 24, lineGap: 2 });
  ensure(hgt + 22);
  const y = doc.y;
  doc.roundedRect(M, y, W(), hgt + 16, 8).fillAndStroke(C.surface, C.border);
  doc.fillColor(C.muted).font("B").fontSize(9.5).text("Catatan · ", M + 12, y + 8, { continued: true, width: W() - 24, lineGap: 2 })
    .font("R").text(t);
  doc.y = y + hgt + 24;
}
function table(head, rows, widths) {
  const total = widths.reduce((a, b) => a + b, 0); const ws = widths.map((w) => (w / total) * W());
  const pad = 6, fs_ = 9;
  const rowH = (cells, font) => Math.max(...cells.map((c, i) => doc.font(font).fontSize(fs_).heightOfString(String(c), { width: ws[i] - pad * 2, lineGap: 1.5 }))) + pad * 2;
  const drawRow = (cells, header) => {
    const font = header ? "B" : "R"; const hgt = rowH(cells, font); const y = doc.y; let x = M;
    if (header) doc.rect(M, y, W(), hgt).fill(C.surface2);
    cells.forEach((c, i) => {
      const txt = String(c); const bold = !header && i === 0;
      if (!header && txt === "Lulus") { doc.font("B").fontSize(fs_).fillColor(C.ok).text("✓ Lulus", x + pad, y + pad, { width: ws[i] - pad * 2 }); }
      else doc.font(bold ? "B" : font).fontSize(fs_).fillColor(header ? C.ink : C.text).text(txt, x + pad, y + pad, { width: ws[i] - pad * 2, lineGap: 1.5 });
      x += ws[i];
    });
    doc.moveTo(M, y + hgt).lineTo(M + W(), y + hgt).lineWidth(0.6).strokeColor(C.border).stroke();
    doc.y = y + hgt;
  };
  ensure(rowH(head, "B") + rowH(rows[0], "R") + 4);
  doc.moveTo(M, doc.y).lineTo(M + W(), doc.y).lineWidth(0.6).strokeColor(C.border).stroke();
  drawRow(head, true);
  rows.forEach((r) => { if (doc.y + rowH(r, "R") > bottom()) { doc.addPage(); drawRow(head, true); } drawRow(r, false); });
  doc.moveDown(0.8);
}
function cards(list) {
  const cols = list.length >= 4 ? 2 : list.length; const gap = 10; const cw = (W() - gap * (cols - 1)) / cols;
  for (let i = 0; i < list.length; i += cols) {
    const row = list.slice(i, i + cols);
    const hgt = Math.max(...row.map(([t, d]) => doc.font("B").fontSize(10.5).heightOfString(t, { width: cw - 20 }) +
      doc.font("R").fontSize(9.5).heightOfString(d, { width: cw - 20, lineGap: 2 }))) + 30;
    ensure(hgt + gap); const y = doc.y;
    row.forEach(([t, d], j) => { const x = M + j * (cw + gap);
      doc.roundedRect(x, y, cw, hgt, 8).fillAndStroke(C.surface, C.border);
      doc.font("B").fontSize(10.5).fillColor(C.ink).text(t, x + 10, y + 10, { width: cw - 20 });
      doc.font("R").fontSize(9.5).fillColor(C.muted).text(d, x + 10, doc.y + 4, { width: cw - 20, lineGap: 2 }); });
    doc.y = y + hgt + gap;
  }
  doc.moveDown(0.3);
}
function steps(list) {
  list.forEach(([t, d], i) => {
    const hgt = doc.font("B").fontSize(10.5).heightOfString(t, { width: W() - 52 }) + doc.font("R").fontSize(9.5).heightOfString(d, { width: W() - 52, lineGap: 2 }) + 18;
    ensure(hgt + 6); const y = doc.y;
    doc.roundedRect(M, y, W(), hgt, 8).fillAndStroke(C.surface, C.border);
    doc.circle(M + 20, y + 18, 11).fill(C.accent);
    doc.font("B").fontSize(10).fillColor(C.accentInk).text(String(i + 1), M + 9, y + 12.5, { width: 22, align: "center" });
    doc.font("B").fontSize(10.5).fillColor(C.ink).text(t, M + 42, y + 9, { width: W() - 52 });
    doc.font("R").fontSize(9.5).fillColor(C.muted).text(d, M + 42, doc.y + 2, { width: W() - 52, lineGap: 2 });
    doc.y = y + hgt + 6;
  });
  doc.moveDown(0.4);
}
function actions() {
  const gap = 8, cw = (W() - gap * 3) / 4; const col = { APPROVE: C.approve, REVIEW: C.review, FLAG: C.flag, BLOCK: C.block };
  const hgt = Math.max(...ACTIONS.map(([a, c, r]) => doc.font("R").fontSize(9).heightOfString(c, { width: cw - 16 }) + doc.font("R").fontSize(8.5).heightOfString(r, { width: cw - 16 }))) + 44;
  ensure(hgt + 10); const y = doc.y;
  ACTIONS.forEach(([a, c, r], i) => { const x = M + i * (cw + gap);
    doc.roundedRect(x, y, cw, hgt, 8).fillAndStroke(C.surface, C.border);
    doc.font("B").fontSize(11).fillColor(col[a]).text(a, x + 8, y + 9, { width: cw - 16, characterSpacing: 0.6 });
    doc.font("R").fontSize(9).fillColor(C.text).text(c, x + 8, doc.y + 4, { width: cw - 16 });
    doc.font("R").fontSize(8.5).fillColor(C.muted).text(r, x + 8, doc.y + 4, { width: cw - 16 }); });
  doc.y = y + hgt + 12;
}
function code(t) {
  const hgt = doc.font("Mono").fontSize(8.5).heightOfString(t, { width: W() - 24, lineGap: 1.5 });
  ensure(hgt + 24); const y = doc.y;
  doc.roundedRect(M, y, W(), hgt + 20, 8).fill(C.ink);
  doc.font("Mono").fontSize(8.5).fillColor("#e6e8eb").text(t, M + 12, y + 10, { width: W() - 24, lineGap: 1.5 });
  doc.y = y + hgt + 30;
}
function diagramPage(key, sectionTitle) {
  const d = DIAGRAMS[key];
  origAddPage({ size: "A4", layout: "landscape", margins: { top: M, bottom: M + 14, left: M, right: M } });
  doc.font("B").fontSize(17).fillColor(C.ink).text(d.title, M, M, { width: W() });
  doc.font("R").fontSize(10).fillColor(C.muted).text(`Diagram · ${sectionTitle}`, M, doc.y + 2);
  const top = doc.y + 16; const availH = bottom() - top - 30;
  const s = Math.min(W() / 1000, availH / d.h); const ox = M + (W() - 1000 * s) / 2, oy = top;
  const P = (p) => [ox + p.x * s, oy + p.y * s];
  doc.lineWidth(1.4);
  for (const e of d.edges) {
    const pts = route(d, e).map(P);
    doc.moveTo(...pts[0]); pts.slice(1).forEach((p) => doc.lineTo(...p));
    if (e.dashed) doc.dash(4, { space: 3 }); doc.strokeColor(C.muted).stroke(); doc.undash();
    const [x2, y2] = pts[pts.length - 1], [x1, y1] = pts[pts.length - 2]; const ang = Math.atan2(y2 - y1, x2 - x1), L = 8;
    doc.polygon([x2, y2], [x2 - L * Math.cos(ang - 0.4), y2 - L * Math.sin(ang - 0.4)], [x2 - L * Math.cos(ang + 0.4), y2 - L * Math.sin(ang + 0.4)]).fill(C.muted);
  }
  for (const n of d.nodes) {
    const k = KIND[n.kind]; const [x, y] = P(n); const w = n.w * s, hh = n.h * s;
    doc.roundedRect(x, y, w, hh, 8).lineWidth(1.4).fillAndStroke("#" + k.fill, "#" + k.stroke);
    const lh = doc.font("B").fontSize(10.5).heightOfString(n.label, { width: w - 12 });
    const sh = n.sub ? doc.font("R").fontSize(8.5).heightOfString(n.sub, { width: w - 12, lineGap: 1 }) : 0;
    const ty0 = y + (hh - lh - sh - (n.sub ? 4 : 0)) / 2;
    doc.font("B").fontSize(10.5).fillColor(C.ink).text(n.label, x + 6, ty0, { width: w - 12, align: "center" });
    if (n.sub) doc.font("R").fontSize(8.5).fillColor(C.muted).text(n.sub, x + 6, ty0 + lh + 4, { width: w - 12, align: "center", lineGap: 1 });
  }
  for (const e of d.edges) if (e.label) {
    const p0 = labelPos(route(d, e)); const [x, y] = P({ x: p0.x, y: p0.y + (e.ldy || 0) });
    const tw2 = doc.font("B").fontSize(8.5).widthOfString(e.label) + 12;
    doc.roundedRect(x - tw2 / 2, y - 8, tw2, 16, 5).lineWidth(0.8).fillAndStroke("#ffffff", C.border);
    doc.font("B").fontSize(8.5).fillColor(C.ink).text(e.label, x - tw2 / 2, y - 4.5, { width: tw2, align: "center" });
  }
  // legend
  const items = [["actor", "Pengguna"], ["edge", "Portal / proxy"], ["boomi", "Boomi process"], ["data", "PostgreSQL / data"], ["ai", "Agent Garden"], ["ext", "Notifikasi / keluaran"]];
  let lx = M; const ly = bottom() - 14;
  items.forEach(([k, l]) => { doc.roundedRect(lx, ly, 10, 10, 2).lineWidth(1).fillAndStroke("#" + KIND[k].fill, "#" + KIND[k].stroke);
    doc.font("R").fontSize(8.5).fillColor(C.muted).text(l, lx + 14, ly + 1, { lineBreak: false }); lx += 26 + doc.widthOfString(l); });
}

// ---------- body ----------
doc.addPage();
SECTIONS.forEach((s, i) => {
  if (i > 0 && doc.y > doc.page.margins.top + 10) { if (doc.y > bottom() - 160) doc.addPage(); else doc.moveDown(1.2); }
  h2(i + 1, s.title);
  tocEntries.push([i + 1, s.title, doc.bufferedPageRange().count]);
  (s.paras || []).forEach(para);
  if (s.cards) cards(s.cards);
  (s.after || []).forEach(para);
  if (s.steps) steps(s.steps);
  if (s.rules) { h3("Aturan deterministik"); table(["Indikator", "Bobot", "Kondisi"], RULES, [2.3, 1, 4]); }
  if (s.table) table(s.table.head, s.table.rows, s.table.head.length === 2 ? [1.3, 3.2] : s.table.head.length === 4 ? [1.2, 2.4, 2.2, 0.8] : [1.6, 1.5, 2.6]);
  (s.sub || []).forEach((x) => { h3(x.title); bullets(x.bullets); });
  if (s.actions) { ensure(150); h3("Rekomendasi tindakan"); actions(); }
  if (s.bullets) bullets(s.bullets);
  if (s.code) code(s.code);
  if (s.note) note(s.note);
  if (s.diagram) { para(`Diagram "${DIAGRAMS[s.diagram].title}" disajikan pada halaman landscape tersendiri setelah halaman ini.`); pending.push([s.diagram, s.title]); }
});

// remove a trailing empty page left by the last diagram
// (pdfkit cannot delete pages; we only add diagram pages mid-document, so the last page always has content)

if (pending.length) { drawing = true; while (pending.length) { const [k, t] = pending.shift(); diagramPage(k, t); } drawing = false; }

// ---------- TOC ----------
doc.switchToPage(tocPage);
doc.font("B").fontSize(22).fillColor(C.ink).text("Daftar isi", M, M + 10);
doc.moveDown(1);
tocEntries.forEach(([n, t, p]) => {
  const y = doc.y;
  doc.font("B").fontSize(11).fillColor(C.accentInk);
  doc.roundedRect(M, y - 1, 22, 15, 3).fill(C.accent);
  doc.fillColor(C.accentInk).text(String(n).padStart(2, "0"), M, y + 2, { width: 22, align: "center" });
  doc.font("R").fontSize(11.5).fillColor(C.text).text(t, M + 32, y, { width: W() - 80 });
  doc.font("R").fontSize(11).fillColor(C.muted).text(String(p), M + W() - 40, y, { width: 40, align: "right" });
  doc.y = y + 24;
});

// ---------- footers ----------
const range = doc.bufferedPageRange();
for (let i = 1; i < range.count; i++) {
  doc.switchToPage(i);
  const pw = doc.page.width, ph = doc.page.height;
  const keep = doc.page.margins.bottom; doc.page.margins.bottom = 0; // footer sits in the margin; avoid auto page breaks
  doc.font("R").fontSize(8).fillColor(C.muted)
    .text(`${META.brand} · ${META.title} — ${META.docName}`, M, ph - M + 6, { width: pw - 2 * M - 60, lineBreak: false, height: 10 });
  doc.text(`${i + 1}`, pw - M - 60, ph - M + 6, { width: 60, align: "right", lineBreak: false, height: 10 });
  doc.page.margins.bottom = keep;
}
doc.end();
console.log("pages", range.count);
