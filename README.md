# Payment Intelligence — AI-Powered Financial Crime Detection

Real-time fraud and illegal-gambling detection for a fictional bank ("BANK GAK JAGO"), built on **Boomi Integration**, **Boomi Agent Garden** and **Neon PostgreSQL**.

Each payment gets a classification (LEGITIMATE, POTENTIAL_FRAUD, POTENTIAL_ILLEGAL_GAMBLING or INSUFFICIENT_DATA), a 0–100 risk score, explainable indicators and an action (APPROVE, REVIEW, FLAG or BLOCK). The final score blends 60% AI and 40% from 13 weighted deterministic rules. A BLOCK is only a proposal until a named analyst approves it.

- **Integration:** Boomi WSS listeners, processes and subprocesses with Try/Catch and retry
- **Data & rules:** PostgreSQL functions behind `pi_dispatch(fn, payload)`, called over Neon's SQL-over-HTTPS endpoint
- **AI:** Agent Garden *Risk Analyst* (structured JSON) and *PI Assistant* (conversational, read-only tools)
- **SNAPShield:** SNAP-style intrabank transfer API with SHA256withRSA signatures, RSA-OAEP + AES-256-GCM encryption and a 30-day pattern guard ([docs/SNAP_API.md](docs/SNAP_API.md))
- **Alerts:** email via Boomi Mail / Amazon SES
- **Tests:** `tests/e2e.sh`, 12/12 end-to-end checks passing (13 Nov 2026)

Full documentation: [docs/Payment_Intelligence_Dokumentasi.pdf](docs/Payment_Intelligence_Dokumentasi.pdf)

## Layout

| Path | What it is |
|---|---|
| `frontend/` | Analyst portal: dashboard, analysis, SNAP transfer, investigation, alerts, AI assistant |
| `proxy/server.py` | Serves the portal and forwards `/api/*` to Boomi, adding auth server side and enforcing rate limits |
| `db/` | Schema, rules and decision engine (`init.sql`) plus migrations |
| `tools/` | Boomi component generators, Agent Garden setup and the SNAP partner client |
| `tests/` | End-to-end and unit tests |

## Run locally

```bash
export PI_BOOMI_BASE_URL=https://<your-boomi-cloud-host> PI_BOOMI_USER=<user> PI_BOOMI_TOKEN=<token>
python3 proxy/server.py   # http://127.0.0.1:8080
```

The SNAP transfer page needs `partner_private.pem` and `boomi_public.pem` in `secrets/snap/` (or set `SNAP_KEY_DIR`).

## Hosted demo

`Dockerfile` + `render.yaml` deploy the portal and proxy as one web service. Set the three `PI_BOOMI_*` variables and upload the two PEM files as Secret Files in the hosting dashboard. Costly routes (analyze, transfer, assistant) are rate-limited per IP and capped per day: see `RL_*` in `proxy/server.py`.
