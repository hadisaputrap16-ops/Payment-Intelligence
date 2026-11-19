"use strict";
// Builds the PPTX deck and, from the same element list, PNG previews (canvas) for visual QA.
const fs = require("fs");
const pptxgen = require("pptxgenjs");
const { createCanvas } = require("@napi-rs/canvas");
const { META, STATS, DIAGRAMS, RULES, ACTIONS, SECTIONS } = require("./content");
const { KIND, route, labelPos } = require("./diagram");
const { applyTheme } = require("/home/hadisaputra/.claude/skills/synced/9f0cfc61-6ee7-4cde-9e28-28b7662ade57_86417866-2b00-4d82-bf8e-697a82739351/pptx/scripts/apply_theme.js");

const OUT = process.argv[2], PREVIEW = process.argv[3];
const SW = 13.333, SH = 7.5;
const THEME = { name: "Bank Gak Jago", headFontFace: "Arial", bodyFontFace: "Calibri",
  colors: { dk1: "15171B", lt1: "FFFFFF", dk2: "2B2F36", lt2: "F4F5F7", accent1: "FFB21E", accent2: "1F8A70", accent3: "6B4FC7",
    accent4: "D0603A", accent5: "5B7BA8", accent6: "B37700", hlink: "8A5A00", folHlink: "6B4FC7" } };
const C = { ink: "15171B", text: "1F2328", muted: "5D636D", border: "E1E4E8", surface: "F6F7F9", surface2: "EEF0F3", amber: "FFB21E", amberInk: "1D1A12",
  white: "FFFFFF", dark2: "1F2227", darkLine: "2C3036", darkMuted: "A3A9B3", approve: "1F8A70", review: "B37700", flag: "D0603A", block: "C0392B" };
const SEC = SECTIONS.reduce((m, s) => (m[s.id] = s, m), {});

// ---------------- slide model ----------------
const slides = []; // { layout, title, sub, els: [], notes, section }
const S = (layout, title, section, notes) => { const s = { layout, title, section, els: [], notes }; slides.push(s); return s; };
const box = (s, x, y, w, h, fill, line, r = 0.12) => s.els.push({ t: "box", x, y, w, h, fill, line, r });
const txt = (s, x, y, w, h, text, o = {}) => s.els.push({ t: "text", x, y, w, h, text, size: o.size || 15, bold: !!o.bold, color: o.color || C.text,
  align: o.align || "left", valign: o.valign || "top", bullets: o.bullets, font: o.font, italic: !!o.italic, lineSp: o.lineSp });
const badge = (s, x, y, n, d = 0.42) => { s.els.push({ t: "circle", x, y, d, fill: C.amber }); txt(s, x, y, d, d, String(n), { size: 13, bold: true, color: C.amberInk, align: "center", valign: "middle" }); };
const line = (s, pts, o = {}) => s.els.push({ t: "line", pts, color: o.color || C.muted, w: o.w || 1.5, dash: o.dash, arrow: o.arrow !== false });
const table = (s, x, y, colW, rows, o = {}) => s.els.push({ t: "table", x, y, colW, rows, size: o.size || 11, rowH: o.rowH || 0.36 });
const chart = (s, o) => s.els.push({ t: "chart", ...o });
const card = (s, x, y, w, h, title, body, o = {}) => {
  box(s, x, y, w, h, o.fill || C.surface, o.line || C.border);
  txt(s, x + 0.2, y + 0.16, w - 0.4, 0.4, title, { size: o.tsize || 16, bold: true, color: o.tcolor || C.ink });
  txt(s, x + 0.2, y + 0.6, w - 0.4, h - 0.75, body, { size: o.bsize || 13, color: o.bcolor || C.muted });
};
function diagram(s, key, x0, y0, wIn) {
  const d = DIAGRAMS[key]; const k = wIn / 1000; const P = (p) => [x0 + p.x * k, y0 + p.y * k];
  for (const e of d.edges) line(s, route(d, e).map(P), { dash: e.dashed });
  for (const n of d.nodes) {
    const [x, y] = P(n); const w = n.w * k, h = n.h * k; const kd = KIND[n.kind];
    box(s, x, y, w, h, kd.fill, kd.stroke, 0.1);
    txt(s, x + 0.06, y + 0.08, w - 0.12, h * 0.5 - 0.04, n.label, { size: 12, bold: true, color: C.ink, align: "center", valign: "bottom" });
    if (n.sub) txt(s, x + 0.06, y + h * 0.5 + 0.02, w - 0.12, h * 0.5 - 0.08, n.sub, { size: 10, color: C.muted, align: "center", valign: "top" });
  }
  for (const e of d.edges) if (e.label) {
    const p0 = labelPos(route(d, e)); const [x, y] = P({ x: p0.x, y: p0.y + (e.ldy || 0) }); const w = e.label.length * 0.085 + 0.24;
    box(s, x - w / 2, y - 0.13, w, 0.26, C.white, C.border, 0.06);
    txt(s, x - w / 2, y - 0.13, w, 0.26, e.label, { size: 10, bold: true, color: C.ink, align: "center", valign: "middle" });
  }
}
const idrJt = (n) => "IDR " + (n / 1e6).toFixed(1).replace(".", ",") + " jt";

// ---------------- content ----------------
// 1 title
{ const s = S("PI_DARK", META.title, "Pembuka", "Payment Intelligence: deteksi fraud dan judi online real time untuk BANK GAK JAGO, dibangun di Boomi.");
  s.els.push({ t: "circle", x: 0.7, y: 0.7, d: 0.62, fill: C.amber, square: true });
  txt(s, 0.7, 0.7, 0.62, 0.62, "gj", { size: 20, bold: true, color: C.amberInk, align: "center", valign: "middle" });
  txt(s, 1.5, 0.78, 6, 0.46, META.brand, { size: 16, bold: true, color: C.white, valign: "middle" });
  s.titleOverride = { y: 2.2, size: 54 };
  txt(s, 0.7, 3.35, 9.5, 1.0, META.subtitle, { size: 20, color: "C9CCD2" });
  txt(s, 0.7, 4.45, 9, 0.45, META.docName + " · " + META.version + " · " + META.date, { size: 14, bold: true, color: C.amber });
  const tiles = [[String(STATS.analyzed), "transaksi dianalisis"], [String(STATS.fraud + STATS.gambling), "fraud / judi terdeteksi"], [idrJt(STATS.riskFraudIdr), "nilai berisiko fraud"], [`${STATS.e2ePass}/${STATS.e2eTotal}`, "pengujian E2E lulus"]];
  tiles.forEach(([b, l], i) => { const x = 0.7 + i * 3.03; box(s, x, 5.45, 2.83, 1.3, C.dark2, C.darkLine);
    txt(s, x + 0.2, 5.55, 2.5, 0.65, b, { size: 28, bold: true, color: C.amber, valign: "middle" });
    txt(s, x + 0.2, 6.2, 2.5, 0.4, l, { size: 12, color: "E3E5E9" }); }); }

// 2 executive summary
{ const s = S("PI_CONTENT", "Ringkasan eksekutif", "Ringkasan", SEC.ringkasan.paras.join(" "));
  txt(s, 0.6, 1.35, 7.4, 1.5, "Setiap transaksi dinilai real time oleh aturan deterministik + agen AI, menghasilkan klasifikasi, skor 0–100, indikator yang bisa dijelaskan, dan rekomendasi tindakan.", { size: 18, color: C.ink });
  SEC.ringkasan.bullets.forEach((b, i) => { const y = 3.05 + i * 0.95; badge(s, 0.6, y + 0.05, i + 1);
    txt(s, 1.2, y, 6.8, 0.85, b, { size: 15, color: C.text, valign: "middle" }); });
  const stats = [[String(STATS.analyzed), "transaksi dianalisis"], [String(STATS.fraud), "potential fraud"], [String(STATS.gambling), "potential judi online"], [`${STATS.e2ePass}/${STATS.e2eTotal}`, "pengujian E2E lulus"]];
  stats.forEach(([v, l], i) => { const x = 8.5 + (i % 2) * 2.2, y = 1.4 + Math.floor(i / 2) * 2.55;
    box(s, x, y, 2.0, 2.3, C.surface, C.border);
    txt(s, x, y + 0.35, 2.0, 1.0, v, { size: 44, bold: true, color: i === 1 ? C.flag : i === 2 ? C.approve : C.ink, align: "center", valign: "middle" });
    txt(s, x + 0.1, y + 1.45, 1.8, 0.6, l, { size: 12, color: C.muted, align: "center" }); }); }

// 3 business background
{ const s = S("PI_CONTENT", "Latar belakang bisnis", "Latar belakang", SEC.latar.paras.join(" ") + " " + SEC.latar.after.join(" "));
  txt(s, 0.6, 1.3, 12.1, 0.6, SEC.latar.paras[0], { size: 16, color: C.text });
  SEC.latar.cards.forEach(([t, d], i) => { const x = 0.6 + i * 4.1; const col = [C.flag, C.approve, "5B7BA8"][i];
    box(s, x, 2.1, 3.85, 3.15, C.surface, C.border);
    s.els.push({ t: "circle", x: x + 0.25, y: 2.35, d: 0.5, fill: col });
    txt(s, x + 0.25, 2.35, 0.5, 0.5, String(i + 1), { size: 14, bold: true, color: C.white, align: "center", valign: "middle" });
    txt(s, x + 0.9, 2.37, 2.85, 0.46, t, { size: 15.5, bold: true, color: C.ink, valign: "middle" });
    txt(s, x + 0.25, 3.05, 3.4, 2.1, d, { size: 13, color: C.muted }); });
  box(s, 0.6, 5.5, 12.1, 1.25, "FFF3D6", "F2D38A");
  txt(s, 0.85, 5.6, 11.6, 1.05, "Pendekatan hibrida: aturan deterministik sebagai pagar pengaman dan bukti yang dapat diaudit, AI untuk membaca konteks (deskripsi, pola riwayat, kombinasi sinyal) yang tidak tertangkap aturan.", { size: 15, color: C.ink, valign: "middle" }); }

// 4 goals & users
{ const s = S("PI_CONTENT", "Tujuan bisnis dan pengguna", "Latar belakang", "Tujuan bisnis dan pemangku kepentingan solusi.");
  SEC.latar.sub.forEach((sub, c) => { const x = 0.6 + c * 6.2;
    txt(s, x, 1.35, 5.9, 0.45, sub.title, { size: 19, bold: true, color: C.ink });
    sub.bullets.forEach((b, i) => { const y = 2.0 + i * 1.12; box(s, x, y, 5.9, 0.98, C.surface, C.border);
      badge(s, x + 0.18, y + 0.27, i + 1, 0.42); txt(s, x + 0.78, y + 0.06, 4.95, 0.86, b, { size: 13.5, color: C.text, valign: "middle" }); }); }); }

// 5 architecture
{ const s = S("PI_CONTENT", "Arsitektur solusi", "Solusi", SEC.arsitektur.paras[0] + " " + SEC.arsitektur.note);
  diagram(s, "architecture", 0.9, 1.35, 11.5); }

// 6 process diagram
{ const s = S("PI_CONTENT", "Proses bisnis end-to-end", "Solusi", SEC.proses.steps.map(([t, d], i) => `${i + 1}. ${t}: ${d}`).join(" "));
  diagram(s, "analyze", 0.9, 1.3, 11.5); }

// 7 process steps grid
{ const s = S("PI_CONTENT", "Sembilan langkah analisis transaksi", "Solusi", "Rincian setiap langkah pada alur Analyze Transaction.");
  SEC.proses.steps.forEach(([t, d], i) => { const x = 0.6 + (i % 3) * 4.1, y = 1.3 + Math.floor(i / 3) * 1.9;
    box(s, x, y, 3.85, 1.72, C.surface, C.border); badge(s, x + 0.18, y + 0.18, i + 1);
    txt(s, x + 0.75, y + 0.16, 2.95, 0.46, t, { size: 14.5, bold: true, color: C.ink, valign: "middle" });
    txt(s, x + 0.18, y + 0.7, 3.5, 0.98, d, { size: 11, color: C.muted }); }); }

// 8 rules chart
{ const s = S("PI_CONTENT", "Decision engine: 13 aturan deterministik", "Decision engine", SEC.decision.paras[0]);
  const maxW = (w) => Math.max(...w.split("/").map((x) => Number(x.trim())));
  const rules = [...RULES].sort((a, b) => maxW(a[1]) - maxW(b[1]));
  chart(s, { kind: "bar", x: 0.6, y: 1.25, w: 7.6, h: 5.55, labels: rules.map((r) => r[0]), values: rules.map((r) => maxW(r[1])), title: "Bobot maksimum per indikator" });
  txt(s, 8.6, 1.35, 4.1, 0.4, "Cara kerja", { size: 18, bold: true, color: C.ink });
  const pts = ["Setiap aturan menghasilkan indikator berbobot (RULE).", "Bobot fraud dan judi dijumlahkan terpisah.", "Total ≥ 40 = bukti kuat yang menentukan klasifikasi rules.", "Indikator AI ditambahkan dari jawaban agen (sumber AI)."];
  pts.forEach((p, i) => { const y = 1.95 + i * 1.12; badge(s, 8.6, y + 0.1, i + 1, 0.4); txt(s, 9.15, y, 3.55, 0.95, p, { size: 13.5, color: C.text, valign: "middle" }); }); }

// 9 fusion + actions
{ const s = S("PI_CONTENT", "Penggabungan AI + rules dan rekomendasi tindakan", "Decision engine", SEC.decision.sub[0].bullets.join(" "));
  box(s, 0.6, 1.3, 12.1, 1.15, C.ink, C.ink);
  txt(s, 0.9, 1.3, 11.5, 1.15, "Skor final = 0,6 × skor AI + 0,4 × skor rules", { size: 26, bold: true, color: C.amber, valign: "middle", align: "center" });
  const rules2 = ["Bukti rules kuat menimpa AI yang lunak", "Payer tak dikenal / AI gagal → REVIEW", "Tidak pernah auto-approve data kurang"];
  rules2.forEach((r, i) => { const x = 0.6 + i * 4.1; box(s, x, 2.65, 3.85, 0.75, C.surface, C.border); txt(s, x + 0.2, 2.65, 3.5, 0.75, r, { size: 13.5, color: C.ink, valign: "middle" }); });
  const col = { APPROVE: C.approve, REVIEW: C.review, FLAG: C.flag, BLOCK: C.block };
  ACTIONS.forEach(([a, c, r], i) => { const x = 0.6 + i * 3.06; box(s, x, 3.65, 2.86, 3.1, C.surface, C.border);
    txt(s, x + 0.2, 3.8, 2.5, 0.5, a, { size: 22, bold: true, color: col[a] });
    txt(s, x + 0.2, 4.45, 2.5, 1.2, c, { size: 14, color: C.text });
    txt(s, x + 0.2, 5.65, 2.5, 1.0, r, { size: 12, color: C.muted }); }); }

// 10 email alert
{ const s = S("PI_CONTENT", "Notifikasi alert lewat email", "Alert & AI", SEC.alert.paras.join(" ") + " " + SEC.alert.note);
  const steps = [["Build email", "MESSAGE, EMAIL_TO, subject, lampiran"], ["Try/Catch + retry 1x", "Send Notifications (Boomi Mail)"], ["Hasil", "SENT / SEND_FAILED"], ["notification_logs", "channel EMAIL, penerima tersamar"]];
  steps.forEach(([t, d], i) => { const x = 0.6 + i * 3.1; box(s, x, 1.4, 2.7, 1.35, i === 1 ? "FDE7DE" : i === 3 ? "DFF3EE" : "FFF3D6", i === 1 ? "D0603A" : i === 3 ? "1F8A70" : "D99A00", 0.1);
    txt(s, x + 0.1, 1.5, 2.5, 0.5, t, { size: 14, bold: true, color: C.ink, align: "center", valign: "middle" });
    txt(s, x + 0.1, 2.0, 2.5, 0.65, d, { size: 11, color: C.muted, align: "center" });
    if (i < 3) line(s, [[x + 2.7, 2.07], [x + 3.1, 2.07]]); });
  txt(s, 0.6, 3.1, 5.9, 0.4, "Contoh isi email", { size: 16, bold: true, color: C.ink });
  box(s, 0.6, 3.55, 5.9, 2.75, C.ink, C.ink);
  txt(s, 0.85, 3.7, 5.4, 2.5, "Subject: [Payment Intelligence] POTENTIAL_FRAUD - TX-…-F (risk 73/100)\n\nPAYMENT INTELLIGENCE ALERT\nRef: INV-20261113-00085\nClassification: POTENTIAL_FRAUD\nAmount: IDR 18,500,000 · Risk score: 73/100\nIndicators: WATCHLIST_HIT, AMOUNT_SPIKE, GEO_MISMATCH\nAction: FLAG (analyst review)", { size: 11.5, color: "E6E8EB", font: "Courier New" });
  txt(s, 6.9, 3.1, 5.8, 0.4, "Mengapa email, bukan WhatsApp", { size: 16, bold: true, color: C.ink });
  txt(s, 6.9, 3.6, 5.8, 1.9, null, { bullets: SEC.alert.sub[0].bullets, size: 13, color: C.text });
  box(s, 6.9, 5.6, 5.8, 1.15, "FFF3D6", "F2D38A");
  txt(s, 7.1, 5.65, 5.4, 1.05, "Deliverability: pengirim @gmail.com via Amazon SES berisiko masuk Spam di Gmail. Produksi: pakai domain bank terverifikasi SES.", { size: 12, color: C.ink, valign: "middle" }); }

// 11 AI assistant
{ const s = S("PI_CONTENT", "AI Assistant untuk analis", "Alert & AI", SEC.assistant.paras[0] + " " + SEC.assistant.bullets.join(" "));
  diagram(s, "assistant", 0.9, 1.2, 11.5);
  SEC.assistant.table.rows.forEach(([t, a, u], i) => { const x = 0.6 + i * 3.06; box(s, x, 4.75, 2.86, 1.0, C.surface, C.border);
    txt(s, x + 0.15, 4.8, 2.6, 0.34, t, { size: 12, bold: true, color: "6B4FC7", font: "Courier New" });
    txt(s, x + 0.15, 5.15, 2.6, 0.56, u, { size: 10.5, color: C.muted }); });
  const pts = ["Wajib memanggil tool sebelum menyebut angka", "Paham konteks 6 giliran terakhir", "Read-only + guardrail topik"];
  pts.forEach((p, i) => { const x = 0.6 + i * 4.1; badge(s, x, 6.05, i + 1, 0.4); txt(s, x + 0.55, 5.97, 3.4, 0.56, p, { size: 13, color: C.text, valign: "middle" }); }); }

// 12 Boomi components
{ const s = S("PI_CONTENT", "Komponen Boomi", "Implementasi", SEC.boomi.paras[0]);
  const rows = [["Process", "Jenis", "Fungsi"], ...SEC.boomi.table.rows.filter((r) => !r[0].startsWith("PI API - Refresh"))];
  table(s, 0.6, 1.3, [3.6, 1.6, 6.9], rows, { size: 11.5, rowH: 0.6 }); }

// 13 data model + API
{ const s = S("PI_CONTENT", "Model data dan API", "Implementasi", SEC.data.note);
  txt(s, 0.6, 1.3, 6.0, 0.4, "Tabel PostgreSQL (Neon)", { size: 17, bold: true, color: C.ink });
  table(s, 0.6, 1.8, [2.2, 3.8], [["Tabel", "Isi utama"], ["payment_identity", "Profil payer ter-tokenisasi, negara asal, perangkat"], ["merchant_registry", "Merchant, MCC, penanda judi, lisensi"],
    ["suspicious_accounts", "Watchlist rekening HIGH / MEDIUM / LOW"], ["payment_transactions", "Transaksi masuk dan statusnya"], ["risk_indicators", "Indikator RULE / AI dengan bobot"],
    ["decision_logs", "Keputusan, skor, override, approval, ref"], ["notification_logs", "Alert: channel, status, error, penerima tersamar"]], { size: 10.5, rowH: 0.62 });
  txt(s, 7.0, 1.3, 5.7, 0.4, "Endpoint (POST, Basic auth)", { size: 17, bold: true, color: C.ink });
  const eps = [["/ws/simple/createPaymentAnalysis", "Analisis satu transaksi → keputusan + status alert"], ["/ws/simple/executePaymentIntelQuery", "dashboard · transactions · investigation · alerts · approve"], ["/ws/simple/executePaymentIntelAssistantChat", "{message, history} → {ok, reply}"]];
  eps.forEach(([e, d], i) => { const y = 1.85 + i * 1.12; box(s, 7.0, y, 5.7, 0.98, C.surface, C.border);
    txt(s, 7.15, y + 0.08, 5.4, 0.36, e, { size: 11.5, bold: true, color: C.ink, font: "Courier New" });
    txt(s, 7.15, y + 0.48, 5.4, 0.44, d, { size: 11.5, color: C.muted }); });
  box(s, 7.0, 5.3, 5.7, 1.4, "FFF3D6", "F2D38A");
  txt(s, 7.2, 5.35, 5.3, 1.3, "Satu pintu masuk: pi_dispatch(fn, payload). Read API hanya meneruskan aksi yang di-whitelist; fungsi internal tidak bisa dipanggil dari luar.", { size: 12.5, color: C.ink, valign: "middle" }); }

// 14 security
{ const s = S("PI_CONTENT", "Keamanan dan kepatuhan", "Implementasi", SEC.keamanan.bullets.join(" "));
  const items = [["Tokenisasi", "payment_id = PID-TKN-…; NIK 16 digit ditolak"], ["Kredensial di server", "Proxy menyuntik Basic auth; konektor terenkripsi di Boomi"], ["Data tersamar", "Nomor telepon dan email di-mask di log dan respons"],
    ["Human-in-the-loop", "BLOCK hanya usulan, wajib approval analis bernama"], ["Audit lengkap", "Keputusan, indikator RULE/AI, override, notifikasi"], ["AI terkendali", "Assistant read-only + guardrail; analyst hanya pakai bukti"]];
  items.forEach(([t, d], i) => { const x = 0.6 + (i % 3) * 4.1, y = 1.4 + Math.floor(i / 3) * 2.45; box(s, x, y, 3.85, 2.2, C.surface, C.border); badge(s, x + 0.22, y + 0.24, i + 1, 0.46);
    txt(s, x + 0.85, y + 0.22, 2.85, 0.5, t, { size: 17, bold: true, color: C.ink, valign: "middle" }); txt(s, x + 0.22, y + 0.92, 3.4, 1.15, d, { size: 15, color: C.text }); });
  box(s, 0.6, 6.3, 12.1, 0.55, "FFF3D6", "F2D38A"); txt(s, 0.8, 6.3, 11.7, 0.55, "Prinsip: data minimal, kredensial tidak pernah di browser, setiap keputusan berdampak tinggi butuh manusia.", { size: 13, color: C.ink, valign: "middle" }); }

// 15 testing
{ const s = S("PI_CONTENT", "Pengujian: 12 dari 12 lulus", "Kualitas", SEC.pengujian.paras[0]);
  chart(s, { kind: "doughnut", x: 0.5, y: 1.25, w: 4.6, h: 4.3, labels: ["Legitimate", "Fraud", "Judi online", "Data kurang"], values: [STATS.legit, STATS.fraud, STATS.gambling, STATS.insufficient],
    colors: ["5B7BA8", "D0603A", "1F8A70", "B37700"], title: `Klasifikasi ${STATS.analyzed} transaksi` });
  txt(s, 0.6, 5.75, 4.4, 1.0, `Nilai berisiko: fraud ${idrJt(STATS.riskFraudIdr)}, judi ${idrJt(STATS.riskGamblingIdr)}`, { size: 13, color: C.muted, align: "center" });
  const rows = [["Skenario", "Hasil diharapkan", "Status"], ...SEC.pengujian.table.rows.map((r) => [r[0], r[2], "✓ Lulus"])];
  table(s, 5.4, 1.3, [2.2, 4.5, 0.95], rows, { size: 11, rowH: 0.6 }); }

// 16 roadmap (dark)
{ const s = S("PI_DARK", "Status dan langkah berikutnya", "Penutup", SEC.roadmap.sub.map((x) => x.title + ": " + x.bullets.join(" ")).join(" "));
  s.titleOverride = { y: 0.55, size: 36 };
  const cols = [["Status saat ini", SEC.roadmap.sub[0].bullets, C.approve], ["Keterbatasan", SEC.roadmap.sub[1].bullets, C.flag], ["Roadmap", SEC.roadmap.sub[2].bullets.slice(0, 4), C.amber]];
  cols.forEach(([t, b, col], i) => { const x = 0.6 + i * 4.1; box(s, x, 1.65, 3.85, 5.1, C.dark2, C.darkLine);
    s.els.push({ t: "circle", x: x + 0.25, y: 1.88, d: 0.3, fill: col });
    txt(s, x + 0.68, 1.82, 3.0, 0.42, t, { size: 18, bold: true, color: C.white, valign: "middle" });
    txt(s, x + 0.25, 2.45, 3.4, 4.2, null, { bullets: b, size: 13, color: "E3E5E9" }); }); }

// ---------------- PPTX writer ----------------
async function writePptx() {
  const pres = new pptxgen(); pres.layout = "LAYOUT_WIDE"; pres.title = `${META.title} - ${META.docName}`; pres.author = META.brand; pres.company = META.brand;
  pres.theme = { headFontFace: THEME.headFontFace, bodyFontFace: THEME.bodyFontFace };
  const footer = (dark) => [{ text: { text: `${META.brand} · ${META.title}`, options: { x: 0.6, y: 7.05, w: 8, h: 0.3, fontSize: 10, color: dark ? C.darkMuted : C.muted } } }];
  pres.defineSlideMaster({ title: "PI_CONTENT_T", background: { color: C.white }, objects: [...footer(false),
    { placeholder: { options: { name: "title", type: "title", x: 0.6, y: 0.35, w: 12.1, h: 0.8, fontSize: 30, bold: true, color: C.ink, fontFace: THEME.headFontFace, valign: "middle", margin: 0 }, text: "Judul" } }],
    slideNumber: { x: 12.2, y: 7.05, w: 0.5, h: 0.3, fontSize: 10, color: C.muted, align: "right" } });
  pres.defineSlideMaster({ title: "PI_DARK_T", background: { color: C.ink }, objects: [...footer(true)],
    slideNumber: { x: 12.2, y: 7.05, w: 0.5, h: 0.3, fontSize: 10, color: C.darkMuted, align: "right" } });
  let lastSec = null;
  for (const sl of slides) {
    if (sl.section !== lastSec) { pres.addSection({ title: sl.section }); lastSec = sl.section; }
    const dark = sl.layout === "PI_DARK";
    const s = pres.addSlide({ masterName: dark ? "PI_DARK_T" : "PI_CONTENT_T", sectionTitle: sl.section });
    if (dark) { const o = sl.titleOverride; s.addText(sl.title, { x: 0.7, y: o.y, w: 11.9, h: o.size > 40 ? 1.1 : 0.8, fontSize: o.size, bold: true, color: C.white, fontFace: THEME.headFontFace, margin: 0, valign: "middle", isTextBox: true }); }
    else s.addText(sl.title, { placeholder: "title" });
    let n = 0;
    for (const e of sl.els) {
      const name = `${e.t}-${++n}`;
      if (e.t === "box") s.addShape(e.r > 0 ? pres.shapes.ROUNDED_RECTANGLE : pres.shapes.RECTANGLE, { x: e.x, y: e.y, w: e.w, h: e.h, fill: { color: e.fill }, line: { color: e.line, width: 1 }, rectRadius: e.r > 0 ? Math.min(0.5, e.r / Math.min(e.w, e.h)) : undefined, objectName: name });
      else if (e.t === "circle") s.addShape(e.square ? pres.shapes.ROUNDED_RECTANGLE : pres.shapes.OVAL, { x: e.x, y: e.y, w: e.d, h: e.d, fill: { color: e.fill }, line: { color: e.fill, width: 0 }, rectRadius: e.square ? 0.22 : undefined, objectName: name });
      else if (e.t === "text") {
        const base = { x: e.x, y: e.y, w: e.w, h: e.h, fontSize: e.size, color: e.color, bold: e.bold, italic: e.italic, align: e.align, valign: e.valign, margin: 0.04, isTextBox: true, objectName: name, fit: "none" };
        if (e.font) base.fontFace = e.font;
        if (e.bullets) s.addText(e.bullets.map((b, i) => ({ text: b, options: { bullet: { indent: 14 }, breakLine: i < e.bullets.length - 1, paraSpaceAfter: 8 } })), base);
        else s.addText(e.text, base);
      } else if (e.t === "line") {
        for (let i = 0; i < e.pts.length - 1; i++) { const [x1, y1] = e.pts[i], [x2, y2] = e.pts[i + 1]; const last = i === e.pts.length - 2;
          s.addShape(pres.shapes.LINE, { x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.abs(x2 - x1), h: Math.abs(y2 - y1), flipH: x2 < x1, flipV: y2 < y1,
            line: { color: e.color, width: e.w, dashType: e.dash ? "dash" : "solid", endArrowType: last && e.arrow ? "triangle" : undefined }, objectName: `${name}-${i}` }); }
      } else if (e.t === "table") {
        const rows = e.rows.map((r, ri) => r.map((c, ci) => ({ text: c, options: { bold: ri === 0 || ci === 0, fill: { color: ri === 0 ? C.surface2 : C.white }, color: c === "✓ Lulus" ? C.approve : ri === 0 || ci === 0 ? C.ink : C.text,
          fontSize: e.size, valign: "middle", margin: [0.04, 0.08, 0.04, 0.08], border: [{ type: "none" }, { type: "none" }, { pt: 0.75, color: C.border }, { type: "none" }] } })));
        s.addTable(rows, { x: e.x, y: e.y, w: e.colW.reduce((a, b) => a + b, 0), colW: e.colW, rowH: e.rowH, objectName: name });
      } else if (e.t === "chart") {
        if (e.kind === "bar") s.addChart(pres.charts.BAR, [{ name: "Bobot", labels: e.labels, values: e.values }], { x: e.x, y: e.y, w: e.w, h: e.h, barDir: "bar",
          chartColors: [C.amber], showValue: true, dataLabelPosition: "outEnd", dataLabelColor: C.ink, dataLabelFontSize: 11, dataLabelFontFace: "+mn-lt",
          catAxisLabelColor: C.text, catAxisLabelFontSize: 11, catAxisLabelFontFace: "+mn-lt", valAxisHidden: true, valGridLine: { style: "none" }, catGridLine: { style: "none" },
          showLegend: false, showTitle: true, title: e.title, titleFontSize: 14, titleColor: C.ink, titleFontFace: "+mn-lt", barGapWidthPct: 45, objectName: name });
        else s.addChart(pres.charts.DOUGHNUT, [{ name: "Klasifikasi", labels: e.labels, values: e.values }], { x: e.x, y: e.y, w: e.w, h: e.h, holeSize: 58, chartColors: e.colors,
          showValue: true, showPercent: false, dataLabelColor: C.white, dataLabelFontSize: 12, dataLabelFontFace: "+mn-lt", showLegend: true, legendPos: "b", legendFontSize: 11, legendColor: C.text, legendFontFace: "+mn-lt",
          showTitle: true, title: e.title, titleFontSize: 14, titleColor: C.ink, titleFontFace: "+mn-lt", objectName: name });
      }
    }
    if (sl.notes) s.addNotes(sl.notes);
  }
  await pres.writeFile({ fileName: OUT });
  await applyTheme(OUT, THEME);
}

// ---------------- preview renderer (QA only) ----------------
function preview() {
  const PX = 96; const fonts = { R: "DejaVu Sans", B: "DejaVu Sans" };
  slides.forEach((sl, idx) => {
    const cv = createCanvas(SW * PX, SH * PX); const g = cv.getContext("2d"); const dark = sl.layout === "PI_DARK";
    g.fillStyle = dark ? "#" + C.ink : "#fff"; g.fillRect(0, 0, cv.width, cv.height);
    const T = (x, y, w, h, text, o) => { // returns overflow flag
      const size = o.size * PX / 72 * 0.92; // Calibri ≈ 8% narrower than DejaVu: scale to approximate widths
      g.font = `${o.italic ? "italic " : ""}${o.bold ? "bold " : ""}${size}px ${o.font === "Courier New" ? "DejaVu Sans Mono" : fonts.R}`; g.fillStyle = "#" + o.color;
      const paras = o.bullets ? o.bullets.map((b) => "• " + b) : String(text).split("\n"); const lines = [];
      const maxW = w * PX - 8;
      paras.forEach((p, pi) => { const words = p.split(" "); let cur = "";
        for (const wd of words) { const t2 = cur ? cur + " " + wd : wd; if (g.measureText(t2).width > maxW && cur) { lines.push(cur); cur = wd; } else cur = t2; }
        lines.push(cur); if (o.bullets && pi < paras.length - 1) lines.push(""); });
      const lh = size * 1.2; const totalH = lines.length * lh;
      let y0 = y * PX + 4; if (o.valign === "middle") y0 = y * PX + (h * PX - totalH) / 2; if (o.valign === "bottom") y0 = y * PX + h * PX - totalH - 4;
      lines.forEach((l, i) => { const tw = g.measureText(l).width; const xx = o.align === "center" ? x * PX + (w * PX - tw) / 2 : x * PX + 4; g.fillText(l, xx, y0 + (i + 0.8) * lh); });
      const over = totalH > h * PX + 2 || lines.some((l) => g.measureText(l).width > maxW + 1);
      if (over) { g.strokeStyle = "red"; g.lineWidth = 3; g.strokeRect(x * PX, y * PX, w * PX, h * PX); console.log(`  overflow slide ${idx + 1}: "${String(text || o.bullets[0]).slice(0, 50)}"`); }
    };
    // title + footer
    if (dark) T(0.7, sl.titleOverride.y, 11.9, sl.titleOverride.size > 40 ? 1.1 : 0.8, sl.title, { size: sl.titleOverride.size, bold: true, color: C.white, valign: "middle" });
    else T(0.6, 0.35, 12.1, 0.8, sl.title, { size: 30, bold: true, color: C.ink, valign: "middle" });
    T(0.6, 7.05, 8, 0.3, `${META.brand} · ${META.title}`, { size: 10, color: dark ? C.darkMuted : C.muted });
    T(12.2, 7.05, 0.5, 0.3, String(idx + 1), { size: 10, color: C.muted, align: "right" });
    for (const e of sl.els) {
      if (e.t === "box") { g.fillStyle = "#" + e.fill; g.strokeStyle = "#" + e.line; g.lineWidth = 1.3; g.beginPath(); g.roundRect(e.x * PX, e.y * PX, e.w * PX, e.h * PX, e.r * PX); g.fill(); g.stroke(); }
      else if (e.t === "circle") { g.fillStyle = "#" + e.fill; g.beginPath(); if (e.square) g.roundRect(e.x * PX, e.y * PX, e.d * PX, e.d * PX, 0.14 * PX); else g.arc((e.x + e.d / 2) * PX, (e.y + e.d / 2) * PX, e.d / 2 * PX, 0, 7); g.fill(); }
      else if (e.t === "text") T(e.x, e.y, e.w, e.h, e.text, e);
      else if (e.t === "line") { g.strokeStyle = "#" + e.color; g.lineWidth = 2; g.setLineDash(e.dash ? [6, 5] : []); g.beginPath(); e.pts.forEach(([x, y], i) => i ? g.lineTo(x * PX, y * PX) : g.moveTo(x * PX, y * PX)); g.stroke(); g.setLineDash([]);
        const [x2, y2] = e.pts[e.pts.length - 1], [x1, y1] = e.pts[e.pts.length - 2]; const a = Math.atan2(y2 - y1, x2 - x1); g.fillStyle = "#" + e.color; g.beginPath(); g.moveTo(x2 * PX, y2 * PX);
        g.lineTo(x2 * PX - 10 * Math.cos(a - 0.4), y2 * PX - 10 * Math.sin(a - 0.4)); g.lineTo(x2 * PX - 10 * Math.cos(a + 0.4), y2 * PX - 10 * Math.sin(a + 0.4)); g.fill(); }
      else if (e.t === "table") { let y = e.y; e.rows.forEach((r, ri) => { let x = e.x; let rowH = e.rowH;
          // estimate needed height
          r.forEach((c, ci) => { g.font = `${ri === 0 || ci === 0 ? "bold " : ""}${e.size * PX / 72 * 0.92}px DejaVu Sans`; const words = String(c).split(" "); let lines = 1, cur = "";
            for (const wd of words) { const t2 = cur ? cur + " " + wd : wd; if (g.measureText(t2).width > e.colW[ci] * PX - 16) { lines++; cur = wd; } else cur = t2; }
            rowH = Math.max(rowH, lines * e.size * 1.25 / 72 + 0.1); });
          if (ri === 0) { g.fillStyle = "#" + C.surface2; g.fillRect(e.x * PX, y * PX, e.colW.reduce((a, b) => a + b) * PX, rowH * PX); }
          r.forEach((c, ci) => { T(x + 0.04, y, e.colW[ci] - 0.08, rowH, c, { size: e.size, bold: ri === 0 || ci === 0, color: c === "✓ Lulus" ? C.approve : C.text, valign: "middle" }); x += e.colW[ci]; });
          y += rowH; g.strokeStyle = "#" + C.border; g.lineWidth = 1; g.beginPath(); g.moveTo(e.x * PX, y * PX); g.lineTo((e.x + e.colW.reduce((a, b) => a + b)) * PX, y * PX); g.stroke(); });
        if (y > 6.95) console.log(`  table overflow slide ${idx + 1}: ends at ${y.toFixed(2)}in`); }
      else if (e.t === "chart") { g.strokeStyle = "#ccc"; g.setLineDash([4, 4]); g.strokeRect(e.x * PX, e.y * PX, e.w * PX, e.h * PX); g.setLineDash([]);
        T(e.x, e.y, e.w, 0.4, e.title, { size: 14, bold: true, color: C.ink, align: "center" });
        if (e.kind === "bar") { const n = e.values.length, bh = (e.h - 0.6) / n; const mx = Math.max(...e.values);
          e.values.forEach((v, i) => { const y = e.y + 0.5 + i * bh; T(e.x, y, 2.9, bh, e.labels[i], { size: 11, color: C.text, align: "left", valign: "middle" });
            g.fillStyle = "#" + C.amber; g.fillRect((e.x + 3.0) * PX, (y + bh * 0.2) * PX, (v / mx) * (e.w - 3.6) * PX, bh * 0.6 * PX); }); }
        else { let a0 = -Math.PI / 2; const tot = e.values.reduce((a, b) => a + b); const cx = (e.x + e.w / 2) * PX, cy = (e.y + e.h / 2) * PX, rr = Math.min(e.w, e.h) * 0.32 * PX;
          e.values.forEach((v, i) => { const a1 = a0 + v / tot * 2 * Math.PI; g.fillStyle = "#" + e.colors[i]; g.beginPath(); g.moveTo(cx, cy); g.arc(cx, cy, rr, a0, a1); g.fill(); a0 = a1; });
          g.fillStyle = "#fff"; g.beginPath(); g.arc(cx, cy, rr * 0.58, 0, 7); g.fill(); } }
    }
    fs.writeFileSync(`${PREVIEW}-${String(idx + 1).padStart(2, "0")}.png`, cv.toBuffer("image/png"));
  });
}

(async () => { preview(); await writePptx(); console.log("slides", slides.length, "->", OUT); })().catch((e) => { console.error(e); process.exit(1); });
