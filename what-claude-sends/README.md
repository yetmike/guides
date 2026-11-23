# Claude Code privacy: I read every request it sends

Companion files for the video. Put Claude Code behind a local mitmproxy, save every request with secrets
redacted, and read the result with a small viewer. Most of it works without an account (the fake key trick).

| File | What it does |
|---|---|
| `capture.sh` | Runs one `claude` command behind mitmproxy, with an empty environment and a throwaway config folder |
| `redact.py` | mitmproxy addon: saves each request and response to `flows/<name>.jsonl` (and `.flows`), redacted before it touches the disk |
| `wcs.py` | Viewer for the `.jsonl` files (Python standard library only) |

## Needs

- Linux or macOS, `bash`, Python 3.9+
- [uv](https://docs.astral.sh/uv/) (`uvx` runs mitmproxy without installing it)
- Claude Code (`claude` on your `PATH`)

## Run it

Work in an empty folder. Everything (CA, config, captures) stays inside it.

```sh
mkdir ~/cc-lab && cd ~/cc-lab && export LAB=$PWD
git clone https://github.com/yetmike/guides && G=$PWD/guides/what-claude-sends

# 1. The fake key trick: Claude Code builds and sends the full first request, then gets a 401.
$G/capture.sh hi ANTHROPIC_API_KEY=sk-ant-api03-FAKE-not-a-real-key -- -p "Reply with one word: hi"

# 2. Same prompt with each switch
$G/capture.sh no-telemetry ANTHROPIC_API_KEY=sk-ant-api03-FAKE-not-a-real-key DISABLE_TELEMETRY=1 -- -p "Reply with one word: hi"
$G/capture.sh switch ANTHROPIC_API_KEY=sk-ant-api03-FAKE-not-a-real-key CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 -- -p "Reply with one word: hi"

# 3. Read the captures
python3 $G/wcs.py totals flows/hi.jsonl flows/no-telemetry.jsonl flows/switch.jsonl
python3 $G/wcs.py list flows/hi.jsonl
python3 $G/wcs.py shape flows/hi.jsonl m1          # what is inside the model request
python3 $G/wcs.py events flows/hi.jsonl            # telemetry event names
python3 $G/wcs.py fields flows/hi.jsonl tengu_input_prompt
python3 $G/wcs.py split flows/hi.jsonl             # bytes up by source: files, command output, prompts, telemetry...
python3 $G/wcs.py usage flows/hi.jsonl             # bytes on the wire vs tokens (input, cache write, cache read)
```

Expected (Claude Code 2.1.330, your numbers will differ a little):

```
capture                reqs       model   telemetry       flags      config   total up
hi                       10     50.5 KB    245.5 KB      0.6 KB      1.4 KB   298.1 KB
no-telemetry              6     49.8 KB           -           -      1.2 KB    51.0 KB
switch                    3     49.8 KB           -           -      0.5 KB    50.4 KB
```

The first run prints `Invalid API key`: that is the point. The request was still built and sent.

## With a real login (file reads, tool loops, WebFetch)

The throwaway config needs its own login once. Do it in the lab folder, so your real `~/.claude` (memory,
CLAUDE.md, plugins, MCP servers) never ends up in a capture:

```sh
HOME=$LAB/home CLAUDE_CONFIG_DIR=$LAB/home/.claude claude    # then /login, then /exit
```

Then add a canary secret and test when a file leaves your machine:

```sh
mkdir $LAB/demo-app && cd $LAB/demo-app && git init -q
printf 'print("hello")\n' > app.py
printf 'DB_PASSWORD=FAKE-hunter2-not-a-real-password-42\n' > .env
$G/capture.sh read-app -- -p "Read app.py and tell me in one sentence what it does." --allowedTools Read
$G/capture.sh read-env -- -p "What is DB_PASSWORD in .env? Value only." --allowedTools Read
$G/capture.sh deny-env -- -p "What is DB_PASSWORD in .env? Value only." --allowedTools Read \
  --settings '{"permissions":{"deny":["Read(./.env)"]}}'
python3 $G/wcs.py grep $LAB/flows/read-app.jsonl FAKE-hunter2     # 0 requests
python3 $G/wcs.py grep $LAB/flows/read-env.jsonl FAKE-hunter2     # 1 request, inside a tool_result
python3 $G/wcs.py grep $LAB/flows/deny-env.jsonl FAKE-hunter2     # 0 requests
```

`capture.sh` keeps everything in `$LAB` (`flows/`, `home/`, `mitm/`) and runs `claude` in the folder you call it from.

Tool loop and WebFetch:

```sh
$G/capture.sh loop -- -p "Add the line '# demo' at the top of app.py, then run python3 app.py." --allowedTools "Read,Edit,Bash"
python3 $G/wcs.py shape $LAB/flows/loop.jsonl m2      # turn 2: "thread": continue, only the new tool result
$G/capture.sh web -- -p "Use WebFetch on https://example.com and tell me the page title only." --allowedTools WebFetch
python3 $G/wcs.py list $LAB/flows/web.jsonl          # domain check, then your machine fetches the page
```

Optional proof that nothing goes around the proxy (Linux): run `claude` under
`strace -f -e trace=connect -o connect.log` and check that every `inet_addr` is `127.0.0.1` port 18080.

A real session: run several prompts through one process with `--input-format stream-json --output-format stream-json --verbose`
(one JSON user message per line on stdin, wait for each `result` event), then `wcs.py split` and `wcs.py usage --total` on the capture.
Run it once more with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and compare: in my test (Claude Code 2.1.330) the switch removed
all telemetry, but requests lost the `thread` field and resent the whole conversation every turn (about 4 MB vs 23 MB up).

## Caveats

- `redact.py` removes what it recognises: auth headers, cookies, token-like strings, UUIDs, emails, JSON keys
  that hold ids, your home path and login name. Read your captures before you share them anyway.
- Byte counts are request bytes on the wire, headers included. Claude Code 2.1.330 sent request bodies
  uncompressed in my tests; if yours are gzipped, mitmproxy decodes them for reading.
- `DISABLE_TELEMETRY` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` count as on for any value, even `0`.
- The CA in `mitm/` can read your TLS traffic. It is only trusted by the `claude` process started by
  `capture.sh` (through `NODE_EXTRA_CA_CERTS`). Delete the lab folder when you are done.
- Claude Code changes often. Endpoints, sizes and fields will move between versions.

## Sources

- Data usage: https://code.claude.com/docs/en/data-usage
- Environment variables: https://code.claude.com/docs/en/env-vars
- Network and proxy config: https://code.claude.com/docs/en/network-config
