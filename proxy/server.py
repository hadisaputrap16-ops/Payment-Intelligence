#!/usr/bin/env python3
"""Local demo server: serves the frontend and forwards the API routes to the Boomi WSS listeners.

Boomi Basic-auth credentials are read from this process's environment (set by run.sh from the
workspace .env) and added server side, so the browser never sees them. Binds to 127.0.0.1 only.
"""
import base64, http.server, json, os, subprocess, sys, threading, time, urllib.error, urllib.request
from collections import defaultdict, deque
from pathlib import Path

BASE = os.environ["PI_BOOMI_BASE_URL"].rstrip("/")
AUTH = "Basic " + base64.b64encode(f'{os.environ["PI_BOOMI_USER"]}:{os.environ["PI_BOOMI_TOKEN"]}'.encode()).decode()
ROUTES = {  # the only upstream paths reachable through the proxy
    "/api/analyze": "/ws/simple/createPaymentAnalysis",
    "/api/query": "/ws/simple/executePaymentIntelQuery",
    "/api/refresh-alerts": "/ws/simple/executePaymentIntelAlertRefresh",
    "/api/assistant": "/ws/simple/executePaymentIntelAssistantChat",
    "/api/snap/v1.0/transfer-intrabank": "/ws/simple/executePaymentIntelSnapTransfer",
}
SNAP_IN = ("X-TIMESTAMP", "X-SIGNATURE", "X-PARTNER-ID", "X-EXTERNAL-ID", "CHANNEL-ID")  # forwarded on SNAP routes only
SNAP_OUT = ("X-TIMESTAMP", "X-SIGNATURE")
MAX_BODY = 64 * 1024
FRONTEND = Path(__file__).resolve().parent.parent / "frontend"
SNAP_CLIENT = Path(__file__).resolve().parent.parent / "tools" / "snap_client.js"

# Public hosting guard: every call costs Boomi runs, Agent Garden tokens and (for fraud/gambling) an alert email.
COSTLY = {"/api/analyze", "/api/transfer", "/api/assistant", "/api/refresh-alerts"}
LIMITS = {  # route class -> (max requests per IP, window seconds)
    "costly": (int(os.environ.get("RL_COSTLY_PER_10MIN", "10")), 600),
    "read": (int(os.environ.get("RL_READ_PER_10MIN", "120")), 600),
}
DAILY_CAP = int(os.environ.get("RL_COSTLY_PER_DAY", "300"))  # all visitors combined; 0 = unlimited
TRUST_PROXY = os.environ.get("TRUST_PROXY") == "1"  # behind Render/other LB: client IP is the first X-Forwarded-For hop


class RateLimiter:
    def __init__(self, limits, daily_cap, clock=time.time):
        self.limits, self.daily_cap, self.clock = limits, daily_cap, clock
        self.hits, self.lock = defaultdict(deque), threading.Lock()
        self.day, self.day_count = None, 0

    def allow(self, ip, kind):
        """Returns None when allowed, else the error message for a 429."""
        now = self.clock()
        limit, window = self.limits[kind]
        with self.lock:
            if kind == "costly" and self.daily_cap:
                day = int(now // 86400)
                if day != self.day:
                    self.day, self.day_count = day, 0
                if self.day_count >= self.daily_cap:
                    return "Daily demo quota reached. Please try again tomorrow."
            q = self.hits[(ip, kind)]
            while q and q[0] <= now - window:
                q.popleft()
            if len(q) >= limit:
                return f"Too many requests: limit {limit} per {window // 60} minutes. Please wait a moment."
            q.append(now)
            if kind == "costly":
                self.day_count += 1
            if len(self.hits) > 10000:  # drop idle buckets so memory stays bounded
                for k in [k for k, v in self.hits.items() if not v]:
                    del self.hits[k]
        return None


LIMITER = RateLimiter(LIMITS, DAILY_CAP)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(FRONTEND), **kw)

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _client_ip(self):
        fwd = self.headers.get("X-Forwarded-For") if TRUST_PROXY else None
        return fwd.split(",")[0].strip() if fwd else self.client_address[0]

    def do_POST(self):
        # the SNAP route is called by our own snap client from localhost (and is signature-checked by Boomi anyway)
        if not (self.path.startswith("/api/snap/") and self.client_address[0] == "127.0.0.1"):
            err = LIMITER.allow(self._client_ip(), "costly" if self.path in COSTLY else "read")
            if err:
                return self._json(429, json.dumps({"ok": False, "error": err}).encode())
        if self.path == "/api/transfer":
            return self._transfer()
        upstream = ROUTES.get(self.path)
        if not upstream:
            return self._json(404, b'{"ok":false,"error":"unknown route"}')
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            return self._json(413, b'{"ok":false,"error":"request body too large"}')
        body = self.rfile.read(length) if length else b""
        headers = {"Authorization": AUTH, "Content-Type": "application/json"}
        snap = self.path.startswith("/api/snap/")
        if snap:  # Boomi Cloud drops custom X-* headers: forward them with the untouched raw body (crypto stays in Boomi)
            headers.update({h: self.headers[h] for h in SNAP_IN if self.headers.get(h)})
            body = json.dumps({"snapHeaders": {h: self.headers[h] for h in SNAP_IN if self.headers.get(h)},
                               "snapBody": body.decode("utf-8", "replace")}).encode()
        req = urllib.request.Request(BASE + upstream, data=body, method="POST", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                extra = {h: r.headers[h] for h in SNAP_OUT if snap and r.headers.get(h)}
                return self._json(r.status, r.read(), extra)
        except urllib.error.HTTPError as e:  # pass Boomi's status through, never its auth details
            payload = e.read()[:4000]
            return self._json(e.code, payload or b'{"ok":false,"error":"upstream error"}')
        except Exception as e:
            self.log_message("upstream failure: %s", type(e).__name__)
            return self._json(502, b'{"ok":false,"error":"Boomi runtime unreachable"}')

    def _transfer(self):
        """Portal transfer form -> SNAP Transfer Intrabank. This server plays the partner bank's backend: the SNAP client
        signs + encrypts with the partner key from secrets/snap and verifies + decrypts Boomi's reply. Keys never reach the browser."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY:
            return self._json(400, b'{"ok":false,"error":"invalid request body"}')
        body = self.rfile.read(length)
        try:
            json.loads(body)
        except ValueError:
            return self._json(400, b'{"ok":false,"error":"request body must be JSON"}')
        port = self.server.server_address[1]
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "SNAP_URL": f"http://127.0.0.1:{port}/api/snap/v1.0/transfer-intrabank"}
        for k in ("SNAP_KEY_DIR", "SNAP_PARTNER_PRIVATE_PEM", "SNAP_BOOMI_PUBLIC_PEM"):
            if os.environ.get(k):
                env[k] = os.environ[k]
        try:
            r = subprocess.run(["node", str(SNAP_CLIENT), "--stdin", "--trace"], input=body, capture_output=True, timeout=200, env=env)
        except subprocess.TimeoutExpired:
            return self._json(504, b'{"ok":false,"error":"SNAP call timed out"}')
        if r.returncode != 0:
            self.log_message("snap client failed: %s", r.stderr.decode(errors="replace")[:300])
            return self._json(502, b'{"ok":false,"error":"SNAP client failed (see server log)"}')
        return self._json(200, r.stdout)

    def _json(self, code, data, extra=None):
        self.send_response(code)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    port = int(os.environ.get("PORT") or os.environ.get("PROXY_PORT", "8080"))  # PORT is set by hosting platforms
    host = os.environ.get("HOST", "127.0.0.1")  # set HOST=0.0.0.0 only when deployed behind a hosting platform
    print(f"Payment Intelligence demo on http://{host}:{port}", file=sys.stderr)
    http.server.ThreadingHTTPServer((host, port), Handler).serve_forever()
