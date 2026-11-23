"""mitmproxy addon: save every flow, redacted BEFORE it touches the disk.

Usage:
  mitmdump -q -p 8080 -s redact.py --set out=flows/exp-a   # writes exp-a.flows + exp-a.jsonl

The live request is never changed (auth must still work). After the server answers,
a copy of the flow is redacted and only that copy is written:
  * secret headers (authorization, x-api-key, cookie, set-cookie, ...) -> <redacted>
  * JSON keys that hold tokens or identities (access_token, account_uuid, email, device_id, ...) -> <redacted>
  * anything that looks like a UUID, an email, an sk-ant- key, a JWT or a long token -> <redacted>
  * your home path -> /home/user, your login name -> user
Wire sizes (before redaction) are kept in the JSONL so byte counts stay true.
"""
import base64
import json
import os
import re
import getpass

from mitmproxy import ctx, io

SECRET_HEADERS = {
    "authorization", "proxy-authorization", "x-api-key", "cookie", "set-cookie",
    "anthropic-dangerous-direct-browser-access", "x-claude-code-session-id",
    "x-client-request-id", "request-id", "x-request-id", "cf-ray", "x-amz-cf-id",
    "anthropic-organization-id", "dd-api-key", "statsig-api-key",
}
SECRET_KEYS = re.compile(
    r"token|secret|password|api_?key|email|uuid|account|organi[sz]ation|org_?id|user_?id|"
    r"device_?id|session_?id|stable_?id|anonymous_?id|install|machine|hostname|request_?id|"
    r"client_?id|code_?verifier|code_?challenge|state|nonce|signature|ip_?address|phone|sha$|"
    r"(user|host|account|display|full|first|last|org|login)_?name",
    re.I)
KEEP_KEYS = {"type", "name", "role", "model", "event_name", "tool_name"}

HOME = os.path.expanduser("~")
USER = getpass.getuser()
PATTERNS = [
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]+"), "<redacted>"),
    (re.compile(r"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"), "<redacted>"),      # JWT
    (re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"), "<redacted>"),
    (re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"), "<redacted>"),          # email
    (re.compile(r"\b[0-9a-f]{32,}\b"), "<redacted>"),                                             # hex ids
    (re.compile(r"(?<![A-Za-z0-9/._\-])[A-Za-z0-9_\-+]{40,}={0,2}(?![A-Za-z0-9/._\-])"), "<redacted>"),  # long tokens
]
if HOME and HOME != "/":
    PATTERNS.append((re.compile(re.escape(HOME)), "/home/user"))
if USER and len(USER) > 2:
    PATTERNS.append((re.compile(r"\b%s\b" % re.escape(USER)), "user"))


def scrub_text(s: str) -> str:
    for rx, rep in PATTERNS:
        s = rx.sub(rep, s)
    return s


def b64json(v):
    if len(v) < 16 or not re.fullmatch(r"[A-Za-z0-9+/_\-]+={0,2}", v):
        return None
    try:
        out = json.loads(base64.b64decode(v + "=" * (-len(v) % 4), altchars=b"-_" if ("-" in v or "_" in v) else None))
    except (ValueError, UnicodeDecodeError):
        return None
    return out if isinstance(out, (dict, list)) else None


def scrub_json(v, key=""):
    if isinstance(v, dict):
        return {scrub_text(k): scrub_json(x, k) for k, x in v.items()}   # ids also show up as keys
    if isinstance(v, list):
        return [scrub_json(x, key) for x in v]
    if isinstance(v, str):
        inner = b64json(v)
        if inner is not None:  # telemetry packs fields as base64 JSON: open it so you can read (and redact) it
            return {"decoded_from_base64": scrub_json(inner, key)}
        if key and key not in KEEP_KEYS and SECRET_KEYS.search(key) and v:
            return "<redacted>"
        if v[:1] in "{[":   # JSON packed inside a string
            try:
                return json.dumps(scrub_json(json.loads(v), key), ensure_ascii=False)
            except ValueError:
                pass
        return scrub_text(v)
    return v


def scrub_body(text: str) -> str:
    try:
        return json.dumps(scrub_json(json.loads(text)), ensure_ascii=False)
    except ValueError:
        pass
    # form bodies and SSE streams: scrub line by line, JSON lines as JSON
    out = []
    for line in text.split("\n"):
        head, sep, rest = line.partition("data: ")
        if sep and rest.startswith("{"):
            try:
                line = head + sep + json.dumps(scrub_json(json.loads(rest)), ensure_ascii=False)
                out.append(line)
                continue
            except ValueError:
                pass
        line = re.sub(r"((?:^|&)(?:[^=&]*(?:token|code|secret|state|verifier)[^=&]*)=)[^&]*", r"\1<redacted>", line, flags=re.I)
        out.append(scrub_text(line))
    return "\n".join(out)


def scrub_message(m):
    if m is None:
        return
    for k in list(m.headers.keys()):
        if k.lower() in SECRET_HEADERS:
            m.headers[k] = "<redacted>"
        else:
            m.headers[k] = scrub_text(m.headers[k])
    if m.raw_content:
        try:
            text = m.get_text(strict=True)
        except ValueError:
            text = None
        if text is not None:
            m.text = scrub_body(text)
        else:  # binary (protobuf, gzip we cannot read): byte-level scrub of what we can see
            raw = m.get_content(strict=False) or b""
            for rx, rep in PATTERNS:
                raw = re.sub(rx.pattern.encode(), rep.encode(), raw, flags=rx.flags & re.I)
            m.content = raw


def entry(f, wire_req, wire_resp):
    r, s = f.request, f.response
    return {
        "t": round(r.timestamp_start, 3),
        "method": r.method, "host": r.pretty_host, "path": scrub_text(r.path),
        "status": s.status_code if s else None,
        "req_bytes": wire_req, "resp_bytes": wire_resp,
        "req_headers": dict(r.headers.items(multi=False)),
        "req_body": r.get_text(strict=False) if r.raw_content else "",
        "resp_headers": dict(s.headers.items(multi=False)) if s else {},
        "resp_body": (s.get_text(strict=False) or "") if s and s.raw_content else "",
        "error": f.error.msg if f.error else None,
        # timings (s): request sent by the client, response headers in, response fully in (mitmproxy buffers the body)
        "t_req_end": round(r.timestamp_end, 3) if r.timestamp_end else None,
        "t_resp_start": round(s.timestamp_start, 3) if s and s.timestamp_start else None,
        "t_resp_end": round(s.timestamp_end, 3) if s and s.timestamp_end else None,
    }


class Redact:
    def load(self, loader):
        loader.add_option("out", str, "flows/capture", "output prefix (.flows and .jsonl)")

    def running(self):
        os.makedirs(os.path.dirname(ctx.options.out) or ".", exist_ok=True)
        self.fh = open(ctx.options.out + ".flows", "ab")
        self.writer = io.FlowWriter(self.fh)
        self.jl = open(ctx.options.out + ".jsonl", "a")

    def _save(self, flow):
        wire_req = len(flow.request.raw_content or b"") + sum(len(k) + len(v) + 4 for k, v in flow.request.headers.items(multi=True))
        wire_resp = 0
        if flow.response:
            wire_resp = len(flow.response.raw_content or b"") + sum(len(k) + len(v) + 4 for k, v in flow.response.headers.items(multi=True))
        c = flow.copy()
        self.n = getattr(self, "n", 0) + 1
        c.id = "flow-%04d" % self.n                     # mitmproxy's random ids look like UUIDs: replace them
        c.client_conn.id, c.server_conn.id = "client-%04d" % self.n, "server-%04d" % self.n
        c.client_conn.sockname = c.server_conn.sockname = ("0.0.0.0", 0)   # your local IPs stay out of the file
        c.client_conn.peername = ("127.0.0.1", 0)
        scrub_message(c.request)
        scrub_message(c.response)
        c.request.url = scrub_text(c.request.url)
        self.writer.add(c)
        self.fh.flush()
        self.jl.write(json.dumps(entry(c, wire_req, wire_resp), ensure_ascii=False) + "\n")
        self.jl.flush()

    def response(self, flow):
        self._save(flow)

    def error(self, flow):
        self._save(flow)


addons = [Redact()]


if __name__ == "__main__":  # self-check: python3 redact.py
    s = scrub_body(json.dumps({"account_uuid": "x", "email": "a@b.co", "model": "claude",
                               "metadata": {"user_id": "user_abc_account_123"},
                               "text": "key sk-ant-oat01-AAAA path %s/x id 123e4567-e89b-12d3-a456-426614174000" % HOME}))
    assert "a@b.co" not in s and "sk-ant" not in s and "123e4567" not in s and HOME not in s, s
    assert '"model": "claude"' in s and '"account_uuid": "<redacted>"' in s, s
    assert "code=<redacted>" in scrub_body("grant_type=authorization_code&code=abc&state=zzz")
    b = base64.b64encode(json.dumps({"rss": 1, "email": "x@y.z"}).encode()).decode()
    d = json.loads(scrub_body(json.dumps({"process": b})))
    assert d["process"]["decoded_from_base64"] == {"rss": 1, "email": "<redacted>"}, d
    k = json.loads(scrub_body(json.dumps({"s": json.dumps({"123e4567-e89b-12d3-a456-426614174000": True})})))
    assert "123e4567" not in json.dumps(k), k
    print("redact self-check ok")
