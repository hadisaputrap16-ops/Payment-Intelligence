# SNAP Transfer Intrabank API

SNAP-style (Standar Nasional Open API Pembayaran, Bank Indonesia) entry point to Payment Intelligence. Every transfer is risk-analysed before the response is returned. Requests and responses are **signed (SHA256withRSA)** and **encrypted** with RSA-OAEP-SHA256 + AES-256-GCM.

| | |
|---|---|
| Boomi process | `PI API - SNAP Transfer Intrabank` (folder *PaymentIntelligence-FinCrimeDetection*) |
| WSS operation | `WSS - Payment Intel SNAP Transfer Intrabank` → `POST /ws/simple/executePaymentIntelSnapTransfer` |
| Gateway route (local proxy) | `POST /api/snap/v1.0/transfer-intrabank` |
| Core logic | Process Call to `[SUB] PI - Analyze Transaction` (the same analysis the portal uses) |
| Generator | `tools/gen_processes.py` → `snap_proc()` |
| Test client | `node tools/snap_client.js '<plaintext request JSON>' [--tamper] [--raw] [--trace]` (or `--stdin`) |
| Portal page | `frontend/transfer.html` → `POST /api/transfer` (proxy acts as partner backend: signs/encrypts server side, returns decrypted response + security trace) |

## Flow

1. **Verify and decrypt**: check headers, partner, timestamp and signature, then decrypt the body (Boomi, `G_SNAP_OPEN`).
2. **Store the request**: `pi_ingest` writes the transaction to `payment_transactions`. It also writes the SNAP request to `snap_requests`, which holds:
   - partner, external ID and channel headers
   - the decrypted body and the pattern evidence
   - status `RECEIVED`
3. **Decide**: the AI agent and the rules evaluate the transfer, then the pattern guard is applied (below). `pi_decide` stores the decision and updates `snap_requests` with status `DECIDED`, the method, classification, action, investigation ref and SNAP `responseCode`.
4. **Respond**: Boomi encrypts and signs the response.
5. **Check later**: on **Transaction Analysis → Check a SNAP transaction**, enter the Payment ID and source account. The page calls `transactions` with `payment_id` and `source_account` and returns every stored SNAP request with its decision and pattern.

## Decision method: AI + rules + pattern guard (`AI_RULES_PATTERN_GUARD`)

The decision has three layers:
1. **AI agent** (Agent Garden *Payment Intelligence Risk Analyst*): judges the full context. That includes payer profile, merchant, watchlist, history, rule signals, and now the `pattern` block.
2. **Deterministic rules**: weighted signals such as watchlist, gambling merchant or keywords, amount spike, new device, geo mismatch and velocity. They are combined with the AI as before (override, insufficient data, 60/40 blend).
3. **Pattern guard (SNAP only)**: *one occurrence is not a pattern.* The guard looks at the same source account over the last 30 days.

| Evidence | Confirms a pattern when |
|---|---|
| `same_beneficiary_30d` | ≥ 1 earlier transfer to the same beneficiary (this is transfer #2 or later) |
| `source_transactions_24h` | ≥ 3 earlier transfers from the source account in 24 h (velocity) |
| `prior_flagged_30d` | ≥ 1 earlier fraud or gambling decision on the source account |
| `payer_gambling_90d` | ≥ 3 gambling payments by the payer in 90 days |

If the AI and rules say fraud or gambling but **no pattern is confirmed** (a first occurrence):
- **Strong rule evidence** (rule score ≥ 40 or a HIGH watchlist hit) gives `INSUFFICIENT_DATA` / **REVIEW** (`2021700`). The score is capped at 59 and nothing is blocked.
- **Soft signals only** give `LEGITIMATE` / **APPROVE** (`2001700`) with monitoring. The score is capped at 29.
- In both cases:
  - no alert is sent;
  - the `FIRST_OCCURRENCE` indicator is added;
  - the explanation states the original verdict (`pattern.unguarded_classification` / `unguarded_risk_score`).

Once the pattern is confirmed, for example on the second transfer to the same beneficiary, the AI and rules verdict applies in full: FLAG, an email alert, or a BLOCK proposal. The response's `additionalInfo.riskAssessment` carries `decisionMethod` and `pattern`.

## Request

**Headers**

| Header | Purpose |
|---|---|
| `X-TIMESTAMP` | ISO-8601 with offset, e.g. `2026-11-14T10:15:00+07:00`. Must be within ±5 minutes of the server clock. |
| `X-SIGNATURE` | `Base64(SHA256withRSA(partnerPrivateKey, stringToSign))` |
| `X-PARTNER-ID` | Must equal the configured partner ID |
| `X-EXTERNAL-ID` | Unique per request |
| `CHANNEL-ID` | SNAP channel code (forwarded; not validated) |

The string to sign is:

```
stringToSign = "POST:/v1.0/transfer-intrabank:" + lowercase(hex(SHA-256(body exactly as sent))) + ":" + X-TIMESTAMP
```

**Body (as sent)**: `{"encryptedKey": "...", "iv": "...", "encryptedData": "..."}`
- `encryptedKey`: a random 32-byte AES key, wrapped with **Boomi's public key** using RSA-OAEP. SHA-256 is used for both the OAEP digest and MGF1.
- `iv`: 12 random bytes. `encryptedData`: AES-256-GCM ciphertext followed by the 16-byte tag.
- All three fields are Base64-encoded.

**Plaintext (after decryption)**: a SNAP Transfer Intrabank body:

```json
{"partnerReferenceNo":"SNAP20261114-001","amount":{"value":"18500000.00","currency":"IDR"},
 "beneficiaryAccountNo":"8881234567","sourceAccountNo":"1234567890","transactionDate":"2026-11-14T10:15:00+07:00",
 "remark":"...","additionalInfo":{"paymentId":"PID-TKN-2B6N8D","deviceId":"DEV-NEW-9931","ipCountry":"KH","merchantId":"MRC-SMB001"}}
```

Mandatory fields: `partnerReferenceNo`, `amount.value`, `amount.currency` (must be `IDR`), `beneficiaryAccountNo`, `sourceAccountNo`, `additionalInfo.paymentId` (a tokenized ID; raw NIK is rejected). Field mapping to the analysis:
- `partnerReferenceNo` → `transaction_id` (gets a `TX-` prefix)
- `beneficiaryAccountNo` → `counterparty_account`
- `remark` → `description`
- channel is `BANK_TRANSFER`
- headers and the decrypted body → `snap_requests` (migration `db/migrations/004_snap_requests_pattern_guard.sql`)

## Response

**Headers**: `X-TIMESTAMP` and `X-SIGNATURE`, signed with **Boomi's private key** over the same string-to-sign format, computed on the response body.

**Body**: `{"responseCode","responseMessage","encryptedKey","iv","encryptedData"}`, encrypted for the **partner's public key**. `responseCode` and `responseMessage` stay in clear text so gateways can route on them. The decrypted payload echoes the request fields and adds:
- `referenceNo`
- `latestTransactionStatus`
- `additionalInfo.riskAssessment`: classification, riskScore, confidence, recommendedAction, indicators, explanation
- `additionalInfo.notification`

| responseCode | Meaning |
|---|---|
| `2001700` Successful / status `00` | Analysis recommended **APPROVE** |
| `2021700` Request In Progress / status `03` | **REVIEW** or **FLAG**: held for manual review (an email alert is sent for fraud and gambling cases) |
| `4031703` Suspected Fraud / status `06` | **BLOCK** |
| `4001701` Invalid Field Format | Body cannot be decrypted, wrong currency, or rejected by validation (details in `additionalInfo.errors`) |
| `4001702` Invalid Mandatory Field `<field>` | Required field missing |
| `4011700` Unauthorized. `<reason>` | Missing header, unknown partner, invalid or expired timestamp, or a bad signature |
| `4091701` Conflict. Duplicate partnerReferenceNo | Replay of an existing reference |
| `5001700` General Error | Unexpected error, or keys not configured. This one is returned unencrypted and unsigned when the keys are missing. |

## Keys

- **Demo keys:** RSA-2048 pairs in `secrets/snap/` (`boomi_*`, `partner_*`). The folder is mode 0700 and excluded by `.gitignore`.
- **What Boomi holds:** its own private key and the partner's public key only. They are stored as Environment Extensions on the TEST environment, never in component XML:

| Extension | Content |
|---|---|
| `DPP_SNAP_PARTNER_ID` | `PI-PARTNER-001` |
| `DPP_SNAP_PARTNER_PUBLIC_KEY` | Base64 X.509 SubjectPublicKeyInfo (PEM body) |
| `DPP_SNAP_BOOMI_PRIVATE_KEY` | Base64 PKCS#8 (PEM body) |

- **Rotating keys:** replace the extension values (Atom Management → Environment Extensions → Process Properties, or `boomi-extensions.sh set` from a file). No redeploy is needed. Give partners the matching `boomi_public.pem`.

## Portal

The **Transfer (SNAP)** tab (`transfer.html`) sends a plaintext transfer to `POST /api/transfer`. The local proxy acts as the partner bank's backend: it runs `tools/snap_client.js --stdin --trace`, which signs and encrypts the request with the partner key, calls the SNAP route, then verifies and decrypts Boomi's reply.

The page shows:
- the outcome (approved, held for review, or blocked)
- the AI decision: AI agent verdict, rule score, indicators, explanation and a link to the investigation
- a step-by-step security trail, using truncated signatures and ciphertext only

The browser never sees a key. Besides the fields listed above, the response's `additionalInfo.riskAssessment` also carries `aiVerdict`, `ruleScore`, `ruleOverride`, `requiresHumanApproval`, `investigationRef` and `transactionStatus`.

## Platform notes and limits

- **Custom headers are dropped by Boomi Cloud.** The shared web server only passes standard headers (`Content-Type`, `Accept-Encoding`) to the process as `inheader_*`. Custom `X-*` headers are dropped, and that setting cannot be changed on the public cloud.
  - The gateway (here `proxy/server.py`; in production, an API gateway) forwards the SNAP headers together with the untouched raw body as `{"snapHeaders":{...},"snapBody":"<raw>"}`.
  - The gateway holds no keys and does no crypto. Boomi verifies the signature over the original bytes.
  - If a runtime does pass `inheader_X-*`, those values take precedence and the gateway wrapper is optional.
- **Response headers do work.** They are set through the `outheader_X-TIMESTAMP` and `outheader_X-SIGNATURE` document properties.
- **The HTTP status is always 200.** Use `responseCode` as the outcome.
- **Not enforced:**
  - `X-EXTERNAL-ID` uniqueness. Replay protection relies on the ±5-minute timestamp window plus the unique `partnerReferenceNo`.
  - The SNAP B2B access-token endpoint (`/v1.0/access-token/b2b`). Transport auth is Boomi Basic auth through the gateway.
