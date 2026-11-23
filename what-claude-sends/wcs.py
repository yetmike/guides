#!/usr/bin/env python3
"""wcs: read redacted Claude Code captures (the .jsonl files redact.py writes). Python stdlib only.

  wcs.py list   cap.jsonl              every request: kind, method, host, path, bytes up/down
  wcs.py totals cap1.jsonl cap2.jsonl  requests and bytes per kind, one row per capture
  wcs.py shape  cap.jsonl [N]          what is inside model request N (default: first): system, tools, messages
  wcs.py body   cap.jsonl N [chars]    pretty JSON body of request N (cut at chars, default 1500)
  wcs.py events cap.jsonl              telemetry event names and counts
  wcs.py fields cap.jsonl EVENT        one telemetry event, all fields
  wcs.py grep   cap.jsonl TEXT         which requests carry TEXT (e.g. a canary secret)
  wcs.py find   cap.jsonl TEXT [lines] the first request with TEXT (body text or headers), a few lines from there
  wcs.py split  cap.jsonl [...]         bytes up by source: your files, command output, prompts, system prompt + tools, telemetry...
  wcs.py usage  [--total] cap.jsonl ... per model request (or one total line per capture): bytes up vs tokens (input, cache write, cache read, output)
  (N for shape can be m2: the second model request)
"""
import json
import sys

Y, R, G, D, B, X = "\033[1;33m", "\033[1;31m", "\033[1;32m", "\033[2m", "\033[1m", "\033[0m"


def kind(e):
    p, h = e["path"], e["host"]
    if p.startswith("/v1/messages"):
        return "model"
    if "event_logging" in p or "datadoghq" in h:
        return "telemetry"
    if p.startswith("/api/eval"):
        return "flags"
    if "CHANGELOG" in p:
        return "changelog"
    if "domain_info" in p:
        return "fetch-check"
    if "anthropic.com" not in h and "claude" not in h:
        return "web"
    return "config"


def load(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def kb(n):
    return f"{n / 1024:.1f} KB" if n < 1024 * 1024 else f"{n / 1048576:.2f} MB"


def jbody(e):
    try:
        return json.loads(e["req_body"])
    except ValueError:
        return None


def cmd_list(path):
    rows = load(path)
    print(f"{B}{'#':>2}  {'kind':<11} {'method':<5} {'host':<22} {'path':<38} {'up':>9} {'down':>9}{X}")
    for i, e in enumerate(rows, 1):
        k = kind(e)
        c = Y if k == "model" else R if k == "telemetry" else ""
        p = e["path"].split("?")[0]
        p = p if len(p) <= 38 else p[:35] + "..."
        print(f"{i:>2}  {c}{k:<11}{X} {e['method']:<5} {e['host'][:22]:<22} {p:<38} {kb(e['req_bytes']):>9} {kb(e['resp_bytes']):>9}")
    print(f"{D}{len(rows)} requests, {kb(sum(e['req_bytes'] for e in rows))} up{X}")


def cmd_totals(*paths):
    caps = [(p.rsplit("/", 1)[-1].removesuffix(".jsonl"), load(p)) for p in paths]
    kinds = [k for k in ["model", "telemetry", "flags", "config", "changelog", "fetch-check", "web"]
             if any(kind(e) == k for _, rows in caps for e in rows)]   # only columns that have data
    print(f"{B}{'capture':<22}{'reqs':>5}" + "".join(f"{k:>12}" for k in kinds) + f"{'total up':>11}{X}")
    for name, rows in caps:
        up = {k: sum(e["req_bytes"] for e in rows if kind(e) == k) for k in kinds}
        cells = "".join(f"{(kb(up[k]) if up[k] else '-'):>12}" for k in kinds)
        print(f"{name[:22]:<22}{len(rows):>5}{cells}{Y}{kb(sum(up.values())):>11}{X}")


def model_req(path, n):
    rows = load(path)
    if n and n.startswith("m"):   # m2 = the second model request
        ms = [(i, e) for i, e in enumerate(rows, 1) if kind(e) == "model"]
        return ms[int(n[1:]) - 1]
    if n:
        return int(n), rows[int(n) - 1]
    for i, e in enumerate(rows, 1):
        if kind(e) == "model":
            return i, e
    sys.exit("no model request in this capture")


def text_of(c):
    if isinstance(c, str):
        return c
    return " ".join(text_of(x.get("text") or x.get("content") or json.dumps(x.get("input", ""))) for x in c)


def cmd_shape(path, n=None):
    i, e = model_req(path, n)
    b = jbody(e)
    print(f"{B}request {i}: POST {e['host']}{e['path'].split('?')[0]}  model={b.get('model')}  {kb(e['req_bytes'])} on the wire{X}")
    if "thread" in b:
        print(f"{Y}thread:{X} {json.dumps(b['thread'])}")
    sysb = b.get("system") or []
    print(f"{Y}system prompt:{X} {len(sysb)} blocks, {sum(len(s.get('text', '')) for s in sysb):,} chars")
    for s in sysb:
        t = s.get("text", "").replace("\n", " ")
        print(f"   {D}{len(t):>6,} chars{X}  {t[:80]}")
    tools = b.get("tools") or []
    if tools:
        names = ", ".join(t.get("name", "?") for t in tools)
        print(f"{Y}tools:{X} {len(tools)} definitions, {len(json.dumps(tools)):,} chars")
        print(f"   {names[:100] + ('...' if len(names) > 100 else '')}")
    print(f"{Y}messages:{X} {len(b.get('messages', []))}")
    for m in b.get("messages", []):
        parts = m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": m["content"]}]
        for c in parts:
            t = text_of([c]).replace("\n", " | ")
            print(f"   {m['role']:<7} {c.get('type', ''):<12} {D}{len(t):>6,} chars{X}  {t[:62]}")


def cmd_body(path, n, chars=1500):
    e = load(path)[int(n) - 1]
    b = jbody(e)
    out = json.dumps(b, indent=2, ensure_ascii=False) if b is not None else e["req_body"]
    print(out[: int(chars)] + (f"\n{D}... {len(out) - int(chars):,} more chars{X}" if len(out) > int(chars) else ""))


def all_events(path):
    for e in load(path):
        if kind(e) == "telemetry":
            b = jbody(e) or {}
            for ev in b.get("events", []):
                yield ev.get("event_data", {})


def cmd_events(path):
    counts = {}
    for d in all_events(path):
        counts[d.get("event_name", "?")] = counts.get(d.get("event_name", "?"), 0) + 1
    for name, c in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"{c:>4}  {name}")
    print(f"{D}{sum(counts.values())} events{X}")


def cmd_fields(path, name):
    for d in all_events(path):
        if d.get("event_name") == name:
            print(json.dumps(d, indent=2, ensure_ascii=False))
            return
    sys.exit(f"no event {name}")


def cmd_find(path, text, lines=6):
    for i, e in enumerate(load(path), 1):
        blob = e["req_body"] if text in e["req_body"] else "\n".join(f"{k}: {v}" for k, v in e["req_headers"].items())
        try:
            blob = "\n".join(text_of([c]) for m in json.loads(blob)["messages"] for c in (m["content"] if isinstance(m["content"], list) else [{"text": m["content"]}]))
        except (ValueError, KeyError, TypeError):
            pass
        if text in blob:
            at = blob.index(text)
            start = blob.rfind("\n", 0, at) + 1
            print(f"{B}request {i}: {e['method']} {e['host']}{e['path'].split('?')[0]}{X}")
            for l in blob[start:].split("\n")[: int(lines)]:
                print(l[:105].replace(text, Y + text + X))
            return
    sys.exit(f"'{text}' is in no request")


def usage(e):
    """Token usage from the streamed response (message_start + message_delta events)."""
    u = {}
    for line in (e.get("resp_body") or "").split("\n"):
        if line.startswith("data: {"):
            try:
                ev = json.loads(line[6:])
            except ValueError:
                continue
            u.update((ev.get("message") or {}).get("usage") or {})
            u.update({k: v for k, v in (ev.get("usage") or {}).items() if v is not None})
    return u


def cmd_usage(*paths):
    if paths[0] == "--total":   # one line per capture: bytes up vs tokens processed
        print(f"{B}{'capture':<18}{'model reqs':>11}{'bytes up':>11}{'tokens in':>12}{'from cache':>12}{'tokens/byte':>12}{X}")
        for path in paths[1:]:
            ms = [e for e in load(path) if kind(e) == "model"]; us = [usage(e) for e in ms]
            up = sum(e["req_bytes"] for e in ms)
            tin = sum(u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0) for u in us)
            cr = sum(u.get("cache_read_input_tokens", 0) for u in us)
            name = path.rsplit("/", 1)[-1].removesuffix(".jsonl")
            print(f"{name[:18]:<18}{len(ms):>11}{kb(up):>11}{tin:>12,}{G}{100 * cr / max(tin, 1):>11.1f}%{X}{Y}{tin / max(up, 1):>12.1f}{X}")
        return
    print(f"{B}{'capture':<16}{'#':>3} {'model':<17}{'thread':<9}{'tools':>6}{'up':>10}{'input':>8}{'cache write':>12}{'cache read':>11}{'output':>8}{X}")
    for path in paths:
        name = path.rsplit("/", 1)[-1].removesuffix(".jsonl")
        for i, e in enumerate(load(path), 1):
            if kind(e) != "model":
                continue
            b, u = jbody(e) or {}, usage(e)
            print(f"{name[:16]:<16}{i:>3} {str(b.get('model', ''))[:16]:<17}{(b.get('thread') or {}).get('type', '-'):<9}{len(b.get('tools') or []):>6}"
                  f"{kb(e['req_bytes']):>10}{u.get('input_tokens', 0):>8,}{Y}{u.get('cache_creation_input_tokens', 0):>12,}{X}"
                  f"{G}{u.get('cache_read_input_tokens', 0):>11,}{X}{u.get('output_tokens', 0):>8,}")


def tool_names(rows):
    """tool_use id -> tool name, read from the streamed model responses."""
    names = {}
    for e in rows:
        for line in (e.get("resp_body") or "").split("\n"):
            if '"tool_use"' in line and line.startswith("data: {"):
                try:
                    cb = json.loads(line[6:]).get("content_block") or {}
                except ValueError:
                    continue
                if cb.get("type") == "tool_use":
                    names[cb.get("id")] = cb.get("name")
    return names


SPLIT = ["your files (Read/Grep/Glob)", "command output (Bash)", "other tool results", "your prompts",
         "system prompt + tools", "context (env, skills, reminders)", "request metadata + headers",
         "telemetry", "flags + config + updates", "web (WebFetch)"]


def split(rows):
    """Bytes up per source. Model request bodies are cut into their parts; the rest is counted per request kind."""
    names, out = tool_names(rows), dict.fromkeys(SPLIT, 0)
    J = lambda x: len(json.dumps(x, ensure_ascii=False).encode())
    for e in rows:
        k = kind(e)
        if k != "model":
            out["telemetry" if k == "telemetry" else "web (WebFetch)" if k in ("web", "fetch-check") else "flags + config + updates"] += e["req_bytes"]
            continue
        b = jbody(e) or {}
        parts = J(b.get("system", [])) + J(b.get("tools", []))
        out["system prompt + tools"] += parts
        for m in b.get("messages", []):
            blocks = m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": m["content"]}]
            for c in blocks:
                n = J(c); parts += n
                if c.get("type") == "tool_result":
                    t = names.get(c.get("tool_use_id"), "")
                    out["your files (Read/Grep/Glob)" if t in ("Read", "Grep", "Glob") else "command output (Bash)" if t == "Bash" else "other tool results"] += n
                elif m["role"] == "user" and c.get("type") == "text" and not c.get("text", "").lstrip().startswith("<"):
                    out["your prompts"] += n
                else:
                    out["context (env, skills, reminders)"] += n
        out["request metadata + headers"] += e["req_bytes"] - parts
    return out


def cmd_split(*paths):
    for path in paths:
        rows = load(path); out = split(rows); tot = sum(out.values())
        down = sum(e["resp_bytes"] for e in rows)
        print(f"{B}{path.rsplit('/', 1)[-1].removesuffix('.jsonl')}: {len(rows)} requests, {kb(tot)} up, {kb(down)} down{X}")
        for k in SPLIT:
            if out[k]:
                bar = "#" * round(40 * out[k] / tot)
                c = Y if k.startswith(("your", "command")) else R if k == "telemetry" else ""
                print(f"  {c}{k:<34}{X}{kb(out[k]):>10} {100 * out[k] / tot:5.1f}%  {c}{bar}{X}")


def cmd_grep(path, text):
    hit = 0
    for i, e in enumerate(load(path), 1):
        n = e["req_body"].count(text)
        mark = f"{R}YES  x{n}{X}" if n else f"{G}no{X}"
        hit += bool(n)
        print(f"{i:>2}  {kind(e):<11} {e['path'].split('?')[0][:38]:<38}  {mark}")
    print(f"{B}'{text}' left the machine in {hit} request(s){X}")


if __name__ == "__main__":
    cmds = {"list": cmd_list, "totals": cmd_totals, "shape": cmd_shape, "body": cmd_body,
            "events": cmd_events, "fields": cmd_fields, "grep": cmd_grep, "find": cmd_find, "usage": cmd_usage, "split": cmd_split}
    if len(sys.argv) < 3 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](*sys.argv[2:])
