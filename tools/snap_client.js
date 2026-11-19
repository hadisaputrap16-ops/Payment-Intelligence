#!/usr/bin/env node
// SNAP Transfer Intrabank test client (acts as the partner).
//   node tools/snap_client.js '<plaintext SNAP request JSON>' [--tamper] [--raw]
// Encrypts the body for Boomi (RSA-OAEP-SHA256 + AES-256-GCM), signs it (SHA256withRSA), posts it through the
// local proxy, verifies Boomi's response signature and decrypts the response. Prints JSON:
//   {http, responseCode, responseMessage, signatureValid, response}
// Keys: env SNAP_PARTNER_PRIVATE_PEM / SNAP_BOOMI_PUBLIC_PEM (PEM text, "\n"-escaped PEM, or base64 of the PEM; used on
// hosts that only offer secret env vars), else secrets/snap/{partner_private,boomi_public}.pem (override dir with SNAP_KEY_DIR).
"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const DIR = process.env.SNAP_KEY_DIR || path.join(__dirname, "..", "secrets", "snap");
const URL_ = process.env.SNAP_URL || `http://127.0.0.1:${process.env.PROXY_PORT || 8080}/api/snap/v1.0/transfer-intrabank`;
const PATH = "/v1.0/transfer-intrabank";
const PARTNER_ID = process.env.SNAP_PARTNER_ID || "PI-PARTNER-001";
function pemFromEnv(v) {
  if (!v) return null;
  const s = v.trim().replace(/\\n/g, "\n");
  return Buffer.from(s.includes("-----BEGIN") ? s : Buffer.from(s, "base64").toString("utf8"));
}
const partnerPriv = pemFromEnv(process.env.SNAP_PARTNER_PRIVATE_PEM) || fs.readFileSync(path.join(DIR, "partner_private.pem"));
const boomiPub = pemFromEnv(process.env.SNAP_BOOMI_PUBLIC_PEM) || fs.readFileSync(path.join(DIR, "boomi_public.pem"));

const sha256hex = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const toSign = (body, ts) => `POST:${PATH}:${sha256hex(body)}:${ts}`;
const OAEP = { padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" };

function timestamp() { // yyyy-MM-ddTHH:mm:ss+07:00
  const d = new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 19);
  return `${d}+07:00`;
}

function seal(plain) {
  const key = crypto.randomBytes(32), iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", key, iv);
  const ct = Buffer.concat([c.update(plain, "utf8"), c.final(), c.getAuthTag()]);
  return JSON.stringify({
    encryptedKey: crypto.publicEncrypt({ key: boomiPub, ...OAEP }, key).toString("base64"),
    iv: iv.toString("base64"), encryptedData: ct.toString("base64"),
  });
}

function open(env) {
  const key = crypto.privateDecrypt({ key: partnerPriv, ...OAEP }, Buffer.from(env.encryptedKey, "base64"));
  const buf = Buffer.from(env.encryptedData, "base64");
  const d = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(env.iv, "base64"));
  d.setAuthTag(buf.subarray(buf.length - 16));
  return JSON.parse(Buffer.concat([d.update(buf.subarray(0, buf.length - 16)), d.final()]).toString("utf8"));
}

async function main() {
  const args = process.argv.slice(2);
  const input = args.includes("--stdin") ? fs.readFileSync(0, "utf8") : args.find((a) => !a.startsWith("--"));
  const plain = JSON.stringify(JSON.parse(input || "{}")); // minified
  const body = seal(plain), ts = timestamp();
  let sig = crypto.sign("sha256", Buffer.from(toSign(body, ts)), partnerPriv).toString("base64");
  if (args.includes("--tamper")) sig = crypto.sign("sha256", Buffer.from(toSign(body + " ", ts)), partnerPriv).toString("base64");
  const headers = { "Content-Type": "application/json", "X-TIMESTAMP": ts, "X-SIGNATURE": sig, "X-PARTNER-ID": PARTNER_ID,
    "X-EXTERNAL-ID": String(Date.now()) + String(Math.floor(Math.random() * 1e6)), "CHANNEL-ID": "95221" };
  const t0 = Date.now();
  const res = await fetch(URL_, { method: "POST", body, headers });
  const text = await res.text();
  let env; try { env = JSON.parse(text); } catch { env = null; }
  const out = { http: res.status, responseCode: env?.responseCode, responseMessage: env?.responseMessage };
  const rts = res.headers.get("x-timestamp"), rsig = res.headers.get("x-signature");
  out.signatureValid = !!(rts && rsig) &&
    crypto.verify("sha256", Buffer.from(toSign(text, rts)), fs.readFileSync(path.join(DIR, "boomi_public.pem")), Buffer.from(rsig, "base64"));
  if (env?.encryptedData) { try { out.response = open(env); } catch (e) { out.decryptError = e.message; } }
  if (args.includes("--raw") || !env) out.raw = text.slice(0, 2000);
  if (args.includes("--trace")) { // public material only: no keys, no plaintext beyond what the caller sent
    const cut = (v, n = 44) => (v && v.length > n ? v.slice(0, n) + "…" : v);
    const reqEnv = JSON.parse(body);
    out.trace = {
      ms: Date.now() - t0, endpoint: "POST " + PATH,
      request: { headers: { ...headers, "X-SIGNATURE": cut(sig) }, stringToSign: cut(toSign(body, ts), 90),
        body: { encryptedKey: cut(reqEnv.encryptedKey), iv: reqEnv.iv, encryptedData: cut(reqEnv.encryptedData), bytes: body.length } },
      response: { headers: { "X-TIMESTAMP": rts, "X-SIGNATURE": cut(rsig) }, signatureValid: out.signatureValid,
        body: env ? { responseCode: env.responseCode, encryptedKey: cut(env.encryptedKey), iv: env.iv, encryptedData: cut(env.encryptedData), bytes: text.length } : null },
    };
  }
  console.log(JSON.stringify(out, null, 2));
}
main().catch((e) => { console.error(e.message); process.exit(1); });
