// Single source of truth for the Payment Intelligence documentation (HTML, PDF and PPTX are generated from this file).
// No secrets: no tokens, passwords or full email addresses.
"use strict";

const META = {
  title: "Payment Intelligence",
  brand: "BANK GAK JAGO",
  subtitle: "AI-powered financial crime detection di atas Boomi Integration, Agent Garden, dan PostgreSQL (Neon)",
  docName: "Dokumentasi Solusi & Teknis",
  version: "v1.0",
  date: "13 November 2026",
  env: "Boomi environment TEST · folder PaymentIntelligence-FinCrimeDetection",
};

// Live snapshot from the Query API (dashboard), 13 Nov 2026.
const STATS = {
  transactions: 449, analyzed: 92, analyzedLive: 34, avgRisk: 34.6,
  fraud: 17, gambling: 11, legit: 51, insufficient: 13,
  flag: 28, review: 13, approve: 51,
  riskFraudIdr: 225732000, riskGamblingIdr: 9755000,
  alertsSent: 10, e2ePass: 12, e2eTotal: 12,
};

// Diagrams: abstract canvas 1000 x H; nodes {id,label,sub,x,y,w,h,kind}; edges {from,to,label,dashed}.
// kind: actor | edge | boomi | data | ai | ext
const DIAGRAMS = {
  architecture: {
    title: "Arsitektur solusi",
    h: 470,
    nodes: [
      { id: "user", label: "Analis fraud", sub: "Browser", x: 20, y: 30, w: 170, h: 80, kind: "actor" },
      { id: "portal", label: "Portal BANK GAK JAGO", sub: "Dashboard · Analysis · Investigation · Alerts · AI Assistant", x: 240, y: 30, w: 330, h: 80, kind: "edge" },
      { id: "proxy", label: "Proxy lokal", sub: "127.0.0.1:8080 · auth di server", x: 620, y: 30, w: 230, h: 80, kind: "edge" },
      { id: "wss", label: "Boomi WSS listeners", sub: "Analyze · Query · Assistant Chat", x: 285, y: 185, w: 430, h: 80, kind: "boomi" },
      { id: "neon", label: "Neon PostgreSQL", sub: "pi_dispatch(): validasi, rules, decision, audit", x: 20, y: 360, w: 225, h: 90, kind: "data" },
      { id: "risk", label: "Agent: Risk Analyst", sub: "Agent Garden · structured JSON", x: 265, y: 360, w: 225, h: 90, kind: "ai" },
      { id: "asst", label: "Agent: PI Assistant", sub: "conversational · 4 tool read-only", x: 510, y: 360, w: 225, h: 90, kind: "ai" },
      { id: "mail", label: "Send Notifications", sub: "Boomi Mail · Amazon SES · email", x: 755, y: 360, w: 225, h: 90, kind: "ext" },
    ],
    edges: [
      { from: "user", to: "portal" }, { from: "portal", to: "proxy", label: "/api/*" },
      { from: "proxy", to: "wss", label: "HTTPS + Basic" },
      { from: "wss", to: "neon", label: "SQL over HTTPS" }, { from: "wss", to: "risk" },
      { from: "wss", to: "asst" }, { from: "wss", to: "mail", label: "alert" },
      { from: "asst", to: "wss", label: "tools", dashed: true },
    ],
  },
  analyze: {
    title: "Alur proses Analyze Transaction",
    h: 450,
    nodes: [
      { id: "s1", label: "1. Terima transaksi", sub: "POST createPaymentAnalysis", x: 10, y: 20, w: 170, h: 84, kind: "boomi" },
      { id: "s2", label: "2. Validasi & simpan", sub: "pi_dispatch('ingest')", x: 212, y: 20, w: 170, h: 84, kind: "data" },
      { id: "s3", label: "3. Konteks + rules", sub: "profil, merchant, watchlist, riwayat", x: 414, y: 20, w: 170, h: 84, kind: "data" },
      { id: "dv", label: "Valid?", sub: "NIK / field wajib", x: 616, y: 20, w: 170, h: 84, kind: "boomi" },
      { id: "rej", label: "Tolak", sub: "REJECTED + daftar error", x: 818, y: 20, w: 170, h: 84, kind: "ext" },
      { id: "s4", label: "4. AI Risk Analyst", sub: "Try/Catch + retry 1x", x: 616, y: 185, w: 170, h: 84, kind: "ai" },
      { id: "s5", label: "5. Decision engine", sub: "60% AI + 40% rules", x: 414, y: 185, w: 170, h: 84, kind: "data" },
      { id: "s6", label: "6. Audit log", sub: "decision_logs, indikator", x: 212, y: 185, w: 170, h: 84, kind: "data" },
      { id: "dn", label: "Fraud / judi?", sub: "notify = true", x: 10, y: 185, w: 170, h: 84, kind: "boomi" },
      { id: "s7", label: "7. Kirim alert email", sub: "Send Notifications", x: 10, y: 350, w: 170, h: 84, kind: "ext" },
      { id: "s8", label: "8. Log notifikasi", sub: "notification_logs", x: 212, y: 350, w: 170, h: 84, kind: "data" },
      { id: "s9", label: "9. Respons API", sub: "keputusan + status alert", x: 414, y: 350, w: 170, h: 84, kind: "boomi" },
    ],
    edges: [
      { from: "s1", to: "s2" }, { from: "s2", to: "s3" }, { from: "s3", to: "dv" },
      { from: "dv", to: "rej", label: "tidak", ldy: -24 }, { from: "dv", to: "s4", label: "ya" },
      { from: "s4", to: "s5" }, { from: "s5", to: "s6" }, { from: "s6", to: "dn" },
      { from: "dn", to: "s7", label: "ya" }, { from: "s7", to: "s8" }, { from: "s8", to: "s9" },
      { from: "dn", to: "s9", label: "tidak", dashed: true },
    ],
  },
  assistant: {
    title: "Alur AI Assistant (portal chat)",
    h: 300,
    nodes: [
      { id: "a1", label: "Analis bertanya", sub: "panel AI Assistant", x: 10, y: 20, w: 200, h: 84, kind: "actor" },
      { id: "a2", label: "PI API - Assistant Chat", sub: "WSS listener", x: 256, y: 20, w: 200, h: 84, kind: "boomi" },
      { id: "a3", label: "Susun prompt", sub: "pesan + 6 giliran terakhir", x: 502, y: 20, w: 200, h: 84, kind: "boomi" },
      { id: "a4", label: "PI Assistant (agent)", sub: "conversational · guardrail", x: 748, y: 20, w: 200, h: 84, kind: "ai" },
      { id: "a5", label: "Tool read-only", sub: "dashboard, transaksi, investigasi, alert", x: 748, y: 190, w: 200, h: 84, kind: "data" },
      { id: "a6", label: "Ekstrak balasan", sub: "SSE event: message", x: 502, y: 190, w: 200, h: 84, kind: "boomi" },
      { id: "a7", label: "Jawaban di portal", sub: "teks + rujukan transaksi", x: 256, y: 190, w: 200, h: 84, kind: "actor" },
    ],
    edges: [
      { from: "a1", to: "a2" }, { from: "a2", to: "a3" }, { from: "a3", to: "a4" },
      { from: "a4", to: "a5", label: "panggil" }, { from: "a5", to: "a4", dashed: true },
      { from: "a4", to: "a6", label: "SSE" }, { from: "a6", to: "a7" },
    ],
  },
};

const RULES = [
  ["WATCHLIST_HIT", "40 / 25 / 10", "Rekening penerima atau payer ada di suspicious_accounts (risiko HIGH / MEDIUM / LOW); kategori fraud"],
  ["WATCHLIST_GAMBLING_COLLECTOR", "40 / 25 / 10", "Rekening penerima tercatat sebagai penampung dana judi; kategori judi"],
  ["GAMBLING_MERCHANT", "40", "Merchant MCC 7995 atau ditandai sebagai merchant judi"],
  ["AMOUNT_SPIKE", "25 / 15", "Nominal > 10x / > 5x rata-rata 90 hari payer (minimal 3 transaksi riwayat)"],
  ["GAMBLING_KEYWORDS", "20", "Deskripsi: slot, gacor, judi, togel, casino, betting, taruhan, maxwin, jackpot, depo, chip"],
  ["UNLICENSED_MERCHANT", "15", "Merchant berstatus UNLICENSED, REVOKED atau UNREGISTERED"],
  ["GEO_MISMATCH", "15", "Negara IP berbeda dengan negara domisili payer"],
  ["GAMBLING_HISTORY", "15", "≥ 3 transaksi judi dalam 90 hari"],
  ["VELOCITY_1H", "15", "≥ 5 pembayaran dalam 1 jam sebelumnya"],
  ["HIGH_VALUE", "10", "Nominal ≥ IDR 50.000.000"],
  ["NEW_DEVICE", "10", "Perangkat yang belum pernah dipakai payer"],
  ["SOCIAL_ENGINEERING_KEYWORDS", "10", "Kata khas penipuan: segera, verifikasi, hadiah, undian, refund, OTP, blokir"],
  ["ODD_HOURS", "5", "Transaksi pukul 00:00–04:59 WIB"],
];

const ACTIONS = [
  ["APPROVE", "LEGITIMATE dan skor < 30", "Transaksi diteruskan, tanpa alert"],
  ["REVIEW", "INSUFFICIENT_DATA, sinyal bertentangan, atau skor 30–59", "Antrian manual review analis"],
  ["FLAG", "Fraud / judi dengan skor ≥ 60", "Alert email otomatis + investigasi"],
  ["BLOCK", "Skor ≥ 85 dan watchlist HIGH", "Hanya usulan; wajib approval manusia bernama"],
];

const SECTIONS = [
  {
    id: "ringkasan", title: "Ringkasan eksekutif",
    paras: [
      "Payment Intelligence adalah solusi deteksi kejahatan finansial untuk BANK GAK JAGO. Setiap transaksi pembayaran dianalisis secara real time oleh kombinasi aturan deterministik dan agen AI, diberi klasifikasi (LEGITIMATE, POTENTIAL_FRAUD, POTENTIAL_ILLEGAL_GAMBLING, INSUFFICIENT_DATA), skor risiko 0–100, indikator yang bisa dijelaskan, dan rekomendasi tindakan (APPROVE, REVIEW, FLAG, BLOCK).",
      "Seluruh orkestrasi berjalan di Boomi Integration: listener web service menerima transaksi, logika data dan aturan berjalan di PostgreSQL (Neon), penilaian kontekstual dilakukan agen Agent Garden 'Payment Intelligence Risk Analyst', dan alert fraud/judi dikirim via email melalui process Boomi 'Send Notifications'. Analis memakai portal web untuk memantau dashboard, menginvestigasi kasus, dan bertanya dalam bahasa natural ke 'Payment Intelligence Assistant'.",
      "Per 13 November 2026 seluruh 12 pengujian end-to-end lulus di environment TEST: analisis AI, alert email, validasi data sensitif, read API, dan AI Assistant.",
    ],
    bullets: [
      "Keputusan dapat dijelaskan: setiap skor disertai indikator RULE dan AI beserta bobotnya.",
      "Aman secara default: data identitas di-tokenisasi, NIK mentah ditolak, BLOCK wajib persetujuan manusia.",
      "Tangguh: kegagalan AI atau email tidak memutus respons; sistem jatuh ke rules + manual review.",
      "Teraudit penuh: decision_logs, risk_indicators, notification_logs.",
    ],
  },
  {
    id: "latar", title: "Latar belakang bisnis",
    paras: [
      "Pertumbuhan pembayaran digital (transfer instan, QRIS, e-wallet, virtual account) membuat bank menghadapi dua pola kejahatan finansial yang dominan dan cepat berubah:",
    ],
    cards: [
      ["Fraud transfer", "Scam berkedok hadiah/undian atau kurir, account takeover dengan perangkat baru dan IP luar negeri, serta rekening penampung (money mule) yang menerima transfer berulang dalam waktu singkat."],
      ["Judi online", "Deposit ke merchant atau rekening penampung judi, sering bernominal kecil tapi berulang, dengan kata kunci khas (slot, gacor, depo, maxwin) dan pola riwayat yang konsisten."],
      ["Tantangan operasional", "Volume transaksi tinggi, keputusan harus dalam hitungan detik, false positive mengganggu nasabah, dan setiap keputusan harus bisa dipertanggungjawabkan ke auditor dan regulator."],
    ],
    after: [
      "Pendekatan murni berbasis aturan mudah diaudit tetapi kaku dan lambat beradaptasi; pendekatan murni AI adaptif tetapi sulit dijelaskan dan berisiko 'halusinasi'. Payment Intelligence menggabungkan keduanya: aturan deterministik sebagai pagar pengaman dan bukti yang dapat diaudit, AI untuk membaca konteks (deskripsi, pola riwayat, kombinasi sinyal) yang tidak tertangkap aturan.",
    ],
    sub: [
      { title: "Tujuan bisnis", bullets: [
        "Mendeteksi fraud dan judi online sebelum dana berpindah, dengan rekomendasi tindakan yang jelas.",
        "Mengurangi beban analis: transaksi jelas-legitimate di-APPROVE otomatis, analis fokus pada FLAG dan REVIEW.",
        "Mempercepat investigasi dengan berkas kasus lengkap dan asisten AI yang menjawab dari data.",
        "Menjaga kepatuhan: audit trail lengkap, perlindungan data pribadi, dan kontrol manusia pada keputusan berdampak tinggi.",
      ] },
      { title: "Pengguna & pemangku kepentingan", bullets: [
        "Analis fraud / AML: memantau alert, menginvestigasi, menyetujui usulan BLOCK.",
        "Tim kepatuhan & audit: menelusuri dasar setiap keputusan dari log.",
        "Tim operasional & IT: menjalankan integrasi Boomi, memantau eksekusi dan deployment.",
        "Nasabah: terlindungi dari scam tanpa banyak gangguan pada transaksi normal.",
      ] },
    ],
  },
  {
    id: "lingkup", title: "Ruang lingkup & kapabilitas",
    table: { head: ["Kapabilitas", "Deskripsi"], rows: [
      ["Analisis transaksi real time", "API menerima satu transaksi, memvalidasi, memperkaya konteks, menjalankan rules dan AI, lalu mengembalikan keputusan."],
      ["Decision engine hibrida", "Skor final = 60% AI + 40% rules; bukti rules kuat menimpa AI yang lunak; payer tak dikenal tidak pernah auto-approve."],
      ["Alert email", "Fraud dan judi memicu email berisi ref investigasi, klasifikasi, nominal, skor, indikator dan penjelasan."],
      ["Investigasi kasus", "Berkas lengkap per transaksi: profil payer, riwayat, indikator, keputusan, audit, notifikasi."],
      ["Approval manusia", "Usulan BLOCK menunggu persetujuan analis bernama sebelum dieksekusi."],
      ["AI Assistant", "Chat bahasa natural (Indonesia/Inggris) untuk ringkasan, pencarian transaksi, dan penjelasan keputusan."],
      ["Dashboard", "KPI, nilai berisiko fraud vs judi, distribusi klasifikasi/aksi, tren, transaksi terbaru."],
    ] },
  },
  { id: "arsitektur", title: "Arsitektur solusi", diagram: "architecture",
    paras: [
      "Arsitektur mengikuti pola API-led: portal tidak pernah berbicara langsung dengan Boomi. Proxy lokal menyuntikkan kredensial Basic auth di sisi server sehingga browser tidak pernah melihat kredensial. Boomi menjadi satu-satunya lapisan orkestrasi; setiap panggilan ke sistem luar (Agent Garden, email) dibungkus subprocess dengan Try/Catch agar kegagalan terisolasi.",
    ],
    table: { head: ["Lapisan", "Teknologi", "Peran"], rows: [
      ["Presentasi", "Portal HTML/JS + proxy Python", "UI analis, AI Assistant, injeksi auth sisi server"],
      ["Integrasi", "Boomi Integration (WSS listener, process, subprocess)", "Orkestrasi, validasi alur, retry, logging"],
      ["Data & aturan", "Neon PostgreSQL via SQL-over-HTTPS (REST connector)", "Validasi, konteks, rules, decision engine, audit"],
      ["Kecerdasan", "Boomi Agent Garden", "Risk Analyst (structured) dan PI Assistant (conversational + tools)"],
      ["Notifikasi", "Process 'Send Notifications' (Boomi Mail → Amazon SES)", "Email alert fraud/judi"],
    ] },
    note: "Neon dipakai lewat endpoint SQL-over-HTTPS karena runtime cloud Boomi tidak menyediakan driver JDBC PostgreSQL. Semua logika SQL lewat satu fungsi pintu masuk pi_dispatch(fn, payload).",
  },
  { id: "proses", title: "Proses bisnis end-to-end", diagram: "analyze",
    steps: [
      ["Terima transaksi", "Kanal (portal atau sistem lain) mengirim JSON transaksi ke POST /ws/simple/createPaymentAnalysis."],
      ["Validasi & simpan", "PostgreSQL memvalidasi field wajib, kanal, nominal, dan menolak NIK 16 digit mentah; transaksi valid disimpan ke payment_transactions."],
      ["Bangun konteks & jalankan rules", "Profil payer (payment_identity), merchant (merchant_registry), watchlist (suspicious_accounts), dan agregat 90 hari dihitung; 10 aturan menghasilkan indikator berbobot."],
      ["Tanya AI Risk Analyst", "Konteks lengkap dikirim ke agen structured; balasan berupa klasifikasi, skor, confidence, indikator dan penjelasan. Gagal transport → retry 1x → amplop gagal."],
      ["Decision engine", "AI dan rules digabung (60/40), override bila bukti rules kuat, aturan konservatif untuk data kurang; tindakan ditentukan dari klasifikasi + skor."],
      ["Audit log", "Keputusan, indikator RULE dan AI, serta ref investigasi (INV-YYYYMMDD-NNNNN) disimpan."],
      ["Kirim alert email", "Untuk POTENTIAL_FRAUD dan POTENTIAL_ILLEGAL_GAMBLING, subprocess email memanggil 'Send Notifications' di dalam Try/Catch."],
      ["Log notifikasi", "Hasil kirim (SENT / SEND_FAILED, channel EMAIL, penerima tersamar) dicatat di notification_logs."],
      ["Respons API", "Klien menerima keputusan lengkap beserta status notifikasi; kegagalan tak terduga menghasilkan pesan aman tanpa stack trace."],
    ],
  },
  { id: "decision", title: "Decision engine",
    paras: ["Aturan deterministik berjalan di PostgreSQL dan menghasilkan indikator berbobot. Bobot fraud dan judi dijumlahkan terpisah untuk menentukan klasifikasi rules (≥ 40 dianggap bukti kuat)."],
    rules: true,
    sub: [
      { title: "Penggabungan AI dan rules", bullets: [
        "Skor final = round(0,6 × skor AI + 0,4 × skor rules); jika AI tidak tersedia, skor rules dipakai untuk keduanya.",
        "Bukti rules kuat (≥ 40) menimpa AI yang menyatakan LEGITIMATE atau INSUFFICIENT_DATA (override tercatat).",
        "Payer tidak dikenal, penerima tidak jelas, atau AI gagal → INSUFFICIENT_DATA → REVIEW (tidak pernah auto-approve).",
        "Klasifikasi AI di luar 4 nilai resmi diabaikan.",
      ] },
    ],
    actions: true,
  },
  { id: "alert", title: "Notifikasi alert (email)",
    paras: [
      "Alert dikirim melalui process Boomi 'Send Notifications' (folder Agent Studio Processes) yang sudah ter-deploy, sehingga memakai ulang koneksi Mail yang ada tanpa menambah lisensi konektor. Subprocess [SUB] PI - Send Email Alert mengisi properti MESSAGE (isi email) dan EMAIL_TO, mengatur subject '[Payment Intelligence] <klasifikasi> - <transaksi> (risk N/100)' dan lampiran <ref>.txt.",
      "Pola Branch memastikan respons selalu kembali: cabang 1 mengirim email di dalam Try/Catch (retry 1x, gagal → SEND_FAILED), cabang 2 melaporkan hasilnya. Kegagalan email tidak pernah membatalkan keputusan.",
    ],
    sub: [{ title: "Mengapa email, bukan WhatsApp", bullets: [
      "Rancangan awal memakai WhatsApp via Twilio. Akun Twilio berstatus Trial: pesan teks bebas selalu ditolak (error 21654), Content API diblokir, dan template yang tersedia tidak memiliki placeholder, sehingga isi alert tidak bisa dikirim.",
      "Subprocess WhatsApp tetap tersedia di generator dan dapat diaktifkan kembali setelah akun Twilio di-upgrade dan template alert disetujui.",
    ] }],
    note: "Deliverability: pengirim email saat ini memakai alamat @gmail.com melalui Amazon SES. Gmail dapat menolak atau memasukkan email semacam ini ke Spam karena gagal SPF/DKIM/DMARC. Untuk produksi gunakan alamat pengirim pada domain yang terverifikasi di SES.",
  },
  { id: "assistant", title: "AI Assistant", diagram: "assistant",
    paras: [
      "'Payment Intelligence Assistant' adalah agen conversational di Boomi Agent Garden yang dibekali empat tool OpenAPI read-only ke Query API. Agen wajib memanggil tool sebelum menyebut angka, mengutip transaction_id dan ref investigasi, menjawab dalam bahasa analis, dan menolak topik di luar analisis risiko pembayaran melalui guardrail.",
    ],
    table: { head: ["Tool", "Aksi Query API", "Kegunaan"], rows: [
      ["get_dashboard_summary", "dashboard", "KPI, nilai berisiko, distribusi klasifikasi/aksi, transaksi terbaru"],
      ["search_transactions", "transactions", "Daftar transaksi dengan filter klasifikasi dan pencarian ID"],
      ["get_investigation", "investigation", "Berkas kasus lengkap untuk menjelaskan alasan keputusan"],
      ["list_alerts", "alerts", "Status pengiriman alert dan error"],
    ] },
    bullets: [
      "Agen bersifat read-only: tidak dapat approve, block, atau mengubah data.",
      "Konteks percakapan: portal mengirim 6 giliran terakhir; agen dapat merujuk 'transaksi yang pertama' dari jawaban sebelumnya.",
      "Guardrail menolak permintaan cara menghindari deteksi fraud/AML dan topik di luar ruang lingkup.",
    ],
  },
  { id: "boomi", title: "Komponen Boomi",
    paras: ["Semua komponen berada di folder PaymentIntelligence-FinCrimeDetection (kecuali 'Send Notifications' yang dipakai bersama). Process XML dihasilkan dari satu generator (tools/gen_processes.py) agar konsisten dan dapat diulang."],
    table: { head: ["Process", "Jenis", "Fungsi"], rows: [
      ["PI API - Analyze Transaction", "API (WSS)", "POST createPaymentAnalysis → [SUB] PI - Analyze Transaction"],
      ["[SUB] PI - Analyze Transaction", "Subprocess", "Alur inti: ingest, rules, agen, decision, audit, alert, log"],
      ["[SUB] PI - Invoke Risk Analyst Agent", "Subprocess", "Agent step structured + Try/Catch retry 1x"],
      ["[SUB] PI - Send Email Alert", "Subprocess", "Bangun email, panggil Send Notifications, laporkan SENT/SEND_FAILED"],
      ["PI API - Query", "API (WSS)", "POST executePaymentIntelQuery (whitelist aksi read + approve)"],
      ["PI API - Assistant Chat", "API (WSS)", "POST executePaymentIntelAssistantChat → [SUB] PI - Assistant Chat"],
      ["[SUB] PI - Assistant Chat", "Subprocess", "Prompt + riwayat → agen conversational → ekstrak SSE"],
      ["Send Notifications", "Shared process", "Set Mail body/to dari DPP → Boomi Mail connector"],
      ["PI API - Refresh Alert Status", "API (WSS)", "Polling status Twilio (tidak di-deploy sejak beralih ke email)"],
    ] },
  },
  { id: "data", title: "Model data",
    table: { head: ["Tabel", "Isi utama"], rows: [
      ["payment_identity", "Profil payer ter-tokenisasi (PID-TKN-…), negara asal, perangkat dikenal"],
      ["merchant_registry", "Merchant, MCC, penanda merchant judi"],
      ["suspicious_accounts", "Watchlist rekening (HIGH / MEDIUM / LOW) dan jumlah laporan"],
      ["payment_transactions", "Transaksi masuk (nominal, kanal, merchant, rekening tujuan, device, IP, deskripsi, status)"],
      ["risk_indicators", "Indikator per transaksi: kode, sumber (RULE / AI), bobot, detail"],
      ["decision_logs", "Keputusan final, skor AI/rules, override, aksi, status approval, ref investigasi, respons"],
      ["notification_logs", "Alert: channel (EMAIL/WHATSAPP), penerima tersamar, status, error, isi pesan"],
    ] },
    note: "Fungsi pi_dispatch(fn, payload) adalah satu-satunya pintu masuk dari Boomi: ingest, decide, log_notification, dashboard, transactions, investigation, alerts, approve. Read API publik hanya meneruskan aksi yang di-whitelist; fungsi internal (mis. ingest) tidak dapat dipanggil dari luar.",
  },
  { id: "api", title: "Referensi API",
    table: { head: ["Endpoint (Boomi shared web server)", "Request", "Response"], rows: [
      ["POST /ws/simple/createPaymentAnalysis", "transaction_id, payment_id (token), amount, channel, merchant_id / counterparty_account, device_id, ip_country, description, transaction_time", "classification, risk_score, confidence, detected_indicators, explanation, recommended_action, investigation_ref, ai, notification"],
      ["POST /ws/simple/executePaymentIntelQuery", "{action: dashboard | transactions | investigation | alerts | approve, …}", "{ok, …} sesuai aksi"],
      ["POST /ws/simple/executePaymentIntelAssistantChat", "{message, history:[{role, content}]}", "{ok, reply, session_id}"],
    ] },
    code: '// contoh respons (dipersingkat)\n{\n  "transaction_id": "TX-…-F",\n  "classification": "POTENTIAL_FRAUD",\n  "risk_score": 73, "confidence": 0.92,\n  "detected_indicators": ["WATCHLIST_HIT","AMOUNT_SPIKE","GEO_MISMATCH"],\n  "recommended_action": "FLAG",\n  "investigation_ref": "INV-20261113-00085",\n  "ai": {"status": "OK", "classification": "POTENTIAL_FRAUD"},\n  "notification": {"channel": "EMAIL", "status": "SENT", "recipient": "h***@…"}\n}',
  },
  { id: "portal", title: "Portal analis",
    cards: [
      ["Dashboard", "KPI transaksi, nilai berisiko fraud vs judi, distribusi klasifikasi dan aksi, tren, transaksi terbaru."],
      ["Transaction Analysis", "Form transaksi dengan skenario demo; menampilkan klasifikasi, skor, indikator, penjelasan dan status alert."],
      ["Investigation", "Berkas kasus: detail transaksi, profil & riwayat payer, indikator RULE/AI, keputusan, audit, notifikasi, panel approval BLOCK."],
      ["Alert Monitoring", "Daftar alert dengan channel, status, penerima tersamar, percobaan, error dan isi pesan."],
      ["✦ AI Assistant", "Panel chat di setiap halaman untuk bertanya ke Payment Intelligence Assistant."],
    ],
  },
  { id: "keamanan", title: "Keamanan & kepatuhan",
    bullets: [
      "Tokenisasi: payment_id berupa token (PID-TKN-…); NIK 16 digit mentah ditolak di validasi.",
      "Kredensial tidak pernah sampai ke browser: proxy menyuntikkan Basic auth di server; kredensial konektor tersimpan terenkripsi di Boomi.",
      "Data pribadi tersamar di log dan respons (nomor telepon dan email di-mask).",
      "Human-in-the-loop: BLOCK hanya usulan dan wajib approval analis bernama.",
      "Audit lengkap untuk setiap keputusan, indikator dan notifikasi; override AI oleh rules tercatat.",
      "Respons error aman tanpa stack trace; detail hanya di log proses Boomi.",
      "AI Assistant read-only dengan guardrail topik; agen risk analyst hanya memakai bukti yang diberikan.",
    ],
  },
  { id: "pengujian", title: "Pengujian",
    paras: ["Pengujian otomatis tests/e2e.sh berjalan melalui proxy → Boomi → Neon → Agent Garden → email. Exit code = jumlah cek yang gagal."],
    table: { head: ["Skenario", "Input", "Hasil diharapkan", "Status"], rows: [
      ["Legitimate", "PID-TKN-7Q2M9A, IDR 420.000, QRIS, MRC-SMB001", "LEGITIMATE → APPROVE, tanpa alert", "Lulus"],
      ["Fraud", "PID-TKN-2B6N8D, IDR 18.500.000 ke ACC-SCAM-0099, IP KH", "POTENTIAL_FRAUD → FLAG + email", "Lulus"],
      ["Judi online", "PID-TKN-9X3L5C, IDR 500.000 ke MRC-GCR088, 'depo slot gacor'", "POTENTIAL_ILLEGAL_GAMBLING → FLAG + email", "Lulus"],
      ["Data kurang", "PID-TKN-ZZ00QX (tidak dikenal)", "INSUFFICIENT_DATA → REVIEW", "Lulus"],
      ["Validasi NIK", "payment_id = NIK 16 digit", "Ditolak (REJECTED)", "Lulus"],
      ["Read API", "dashboard, alerts, investigation", "ok = true; indikator AI + RULE + notifikasi", "Lulus"],
      ["Proteksi fungsi internal", "action = ingest via Query API", "Ditolak", "Lulus"],
      ["AI Assistant", "Pertanyaan jumlah POTENTIAL_FRAUD", "Jawaban dari tool", "Lulus"],
    ] },
  },
  { id: "operasional", title: "Operasional & deployment",
    bullets: [
      "Environment: Boomi TEST; listener di shared web server cloud (Basic auth).",
      "Menjalankan portal: bash payment-intelligence/proxy/run.sh lalu buka http://127.0.0.1:8080.",
      "Regenerasi process: tools/gen-processes.sh (set ALERT_EMAIL_TO di .env) → push subprocess → deploy ulang parent API.",
      "Setelah mengubah subprocess, parent 'PI API - …' wajib di-deploy ulang agar perubahan ikut.",
      "Agen Agent Garden dibuat/diperbarui lewat Design API (tools/ag-assistant-setup.sh); operation boomiai hanya bisa dibuat via GUI (Generate Configuration).",
      "Lisensi: kuota konektor Standard di TEST penuh; gunakan ulang koneksi yang sudah ter-deploy (seperti Send Notifications) sebelum menambah koneksi baru.",
      "Perubahan skema DB dijalankan di Neon SQL Editor (contoh: db/migrations/002_email_alert_channel.sql).",
      "Log: boomi-execution-query.sh --process-id <id>, lalu --execution-id <id> --logs.",
    ],
  },
  { id: "roadmap", title: "Status, keterbatasan & roadmap",
    sub: [
      { title: "Status saat ini", bullets: [
        "12/12 pengujian end-to-end lulus (13 Nov 2026).",
        "Analisis AI, decision engine, alert email, investigasi dan AI Assistant berjalan di TEST.",
      ] },
      { title: "Keterbatasan", bullets: [
        "Deliverability email: pengirim @gmail.com via SES berisiko masuk Spam/ditolak di Gmail.",
        "WhatsApp nonaktif karena batasan akun Twilio Trial.",
        "Kuota lisensi konektor Standard di TEST sudah penuh.",
        "Portal berjalan lokal via proxy; belum ada SSO/peran pengguna.",
      ] },
      { title: "Roadmap", bullets: [
        "Pengirim email pada domain bank yang terverifikasi SES (SPF/DKIM/DMARC).",
        "Aktifkan kembali WhatsApp dengan akun Twilio berbayar dan template alert yang disetujui.",
        "Hosting portal di belakang SSO dengan peran analis/supervisor.",
        "Feedback loop: hasil investigasi analis dipakai untuk kalibrasi bobot rules dan instruksi agen.",
        "Promosi ke environment produksi dengan environment extensions untuk koneksi dan kredensial.",
      ] },
    ],
  },
];

module.exports = { META, STATS, DIAGRAMS, RULES, ACTIONS, SECTIONS };
