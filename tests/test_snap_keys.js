// Run: node tests/test_snap_keys.js — snap_client must load keys from env in every supported format.
// Uses a throwaway key pair; the network call is expected to fail (nothing listens on port 9).
const assert = require("assert");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const path = require("path");

const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});
const formats = {
  plain: (s) => s,
  escaped: (s) => s.replace(/\n/g, "\\n"),
  base64: (s) => Buffer.from(s).toString("base64"),
};
for (const [name, f] of Object.entries(formats)) {
  const r = spawnSync("node", [path.join(__dirname, "..", "tools", "snap_client.js"), "{}"], {
    env: { PATH: process.env.PATH, SNAP_URL: "http://127.0.0.1:9/x", SNAP_KEY_DIR: "/nonexistent",
      SNAP_PARTNER_PRIVATE_PEM: f(privateKey), SNAP_BOOMI_PUBLIC_PEM: f(publicKey) },
    encoding: "utf8",
  });
  const err = r.stderr || "";
  assert.ok(!/ENOENT|DECODER|asn1|PEM/i.test(err), `${name}: key load failed: ${err.slice(0, 200)}`);
  assert.ok(/fetch failed|ECONNREFUSED/.test(err), `${name}: expected only a network error, got: ${err.slice(0, 200)}`);
}
console.log("test_snap_keys.js: all checks passed");
