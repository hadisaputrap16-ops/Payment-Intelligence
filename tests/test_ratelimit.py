# Run: python3 tests/test_ratelimit.py
import os, sys
os.environ.update(PI_BOOMI_BASE_URL="http://x", PI_BOOMI_USER="u", PI_BOOMI_TOKEN="t")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "proxy"))
from server import RateLimiter

now = [1000.0]
rl = RateLimiter({"costly": (2, 600), "read": (3, 600)}, daily_cap=3, clock=lambda: now[0])
assert rl.allow("a", "costly") is None and rl.allow("a", "costly") is None
assert rl.allow("a", "costly"), "3rd costly call in window is refused"
assert rl.allow("b", "costly") is None, "other IPs have their own bucket"
assert rl.allow("a", "read") is None, "read bucket is separate"
now[0] += 601
assert rl.allow("c", "costly") and "Daily" in rl.allow("c", "costly"), "global daily cap (3) reached"
now[0] += 86400
assert rl.allow("a", "costly") is None, "window and daily cap reset"
print("test_ratelimit.py: all checks passed")
