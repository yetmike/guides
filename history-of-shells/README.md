# The history of Unix shells: the terminal demos

Companion to the video **Why Bash Still Speaks 1979 (50 Years of Unix Shells)**.
Every terminal shot in the film ran in one Docker container. The [Dockerfile](Dockerfile) here builds the same set of shells,
so you can run each demo yourself.

## Needs

- Docker (any recent version), about 1.5 GB of disk, x86_64 or arm64.
- A few minutes for the first build: it compiles an old bash 4.3 from the GNU sources.

## Build and start

```bash
docker build -t shells .
docker run --rm -it --hostname laptop shells
```

You land in bash as the user `demo`, home `/home/demo`. Versions inside (Debian 13 trixie):
bash 5.2.37, dash, zsh 5.9, fish 4.0.2, tcsh 6.24.13, ksh 93u+m/1.0.10, BusyBox 1.37.0, Nushell 0.117.0,
and bash 4.3.0 with no patches in `/opt/bash-4.3` (vulnerable to Shellshock on purpose).

## 1. if ends in fi

```bash
printf '%s\n' '#!/bin/sh' '# check.sh: do we have a login profile?' 'if [ -f "$HOME/.profile" ]; then' '    echo "found: $HOME/.profile"' 'else' '    echo "no profile yet"' 'fi' > check.sh
cat check.sh
sh check.sh
```

Expected: the 7-line script, then `found: /home/demo/.profile`.

## 2. The square bracket is a program

```bash
ls -l /usr/bin/[
type [
[ 1 -lt 2 ] && echo yes
```

Expected:

```
-rwxr-xr-x 1 root root 55720 Jun  4  2025 '/usr/bin/['
[ is a shell builtin
yes
```

There is a real file called `[` on disk. Shells also build it in for speed, which is why `type [` says builtin.
`ls` puts quotes around the name only when it prints to a terminal.

## 3. Who is /bin/sh?

```bash
ls -l /bin/sh
readlink -f /bin/sh
```

Expected on Debian (and Ubuntu): `/bin/sh -> dash` and `/usr/bin/dash`. On Alpine, try
`docker run --rm alpine ls -l /bin/sh`: it points to `/bin/busybox`.

## 4. csh history and aliases (tcsh)

```bash
exec tcsh
echo hello
!!
alias hi 'echo hello'
hi
echo ~
exit
```

`!!` repeats the last command (tcsh first prints the expanded `echo hello`). `echo ~` prints `/home/demo`.
Both ideas came from the C shell. `exit` closes the container, because `exec` replaced bash; start it again for the next demo.

## 5. vi mode in bash (from ksh)

```bash
bind 'set show-mode-in-prompt on'
set -o vi
```

Type `ehco hello world`, press Esc, `0` (start of line), `cw`, type `echo`, Esc, Enter. Output: `hello world`.
The prompt shows `(ins)` or `(cmd)` for the current mode.

## 6. fish: colours, suggestions, completions from man pages

```bash
fish
```

- Type `eho`: it turns red (no such command). Fix it to `echo` and it turns back.
- Run `ls -l /usr/bin | wc -l` once, then type `ls -l /u`: the rest appears in grey. Right arrow accepts it.
- Type `shred --` and press Tab: a list of options with descriptions. fish built it from the `shred` man page
  (`~/.cache/fish/generated_completions/shred.fish`, made when the image was built).

## 7. Nushell: tables instead of text

```bash
mkdir -p demo && cd demo
printf '# Shell notes\n' > README.md
head -c 48213 /dev/urandom > app.log
head -c 2348 /dev/urandom > backup.sh
head -c 640 /dev/urandom > config.toml
head -c 9500000 /dev/urandom > photo.jpg
printf '[\n {"name": "web-1", "region": "eu-west", "cpus": 4, "up": true},\n {"name": "web-2", "region": "eu-west", "cpus": 4, "up": false},\n {"name": "db-1", "region": "us-east", "cpus": 16, "up": true}\n]\n' > servers.json
nu
```

Then inside Nushell:

```
ls
ls | sort-by size
ls | where size > 1kb
open servers.json
```

Expected for the last two:

```
╭───┬───────────┬──────┬─────────┬──────────╮
│ # │   name    │ type │  size   │ modified │
├───┼───────────┼──────┼─────────┼──────────┤
│ 0 │ app.log   │ file │ 48.2 kB │ now      │
│ 1 │ backup.sh │ file │  2.3 kB │ now      │
│ 2 │ photo.jpg │ file │  9.5 MB │ now      │
╰───┴───────────┴──────┴─────────┴──────────╯
╭───┬───────┬─────────┬──────┬───────╮
│ # │ name  │ region  │ cpus │  up   │
├───┼───────┼─────────┼──────┼───────┤
│ 0 │ web-1 │ eu-west │    4 │ true  │
│ 1 │ web-2 │ eu-west │    4 │ false │
│ 2 │ db-1  │ us-east │   16 │ true  │
╰───┴───────┴─────────┴──────┴───────╯
```

`where size > 1kb` compares numbers, not text: no `awk`, no `cut`. `open` reads JSON straight into a table.
The video also set the file dates with `touch -d '3 days ago' README.md` and so on; here the `modified` column says "now".

## 8. Shellshock (CVE-2014-6271)

```bash
/opt/bash-4.3/bin/bash --version | head -1
env x='() { :;}; echo vulnerable' /opt/bash-4.3/bin/bash -c 'echo test'
bash --version | head -1
env x='() { :;}; echo vulnerable' bash -c 'echo test'
```

Expected:

```
GNU bash, version 4.3.0(1)-release (x86_64-unknown-linux-gnu)
vulnerable
test
GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
test
```

The old bash runs the code hidden after the function definition in the environment variable. The patched bash does not.
Keep the old bash inside this container. Never install it on a real machine.

## 9. dash starts faster than bash

```bash
time for i in $(seq 1000); do bash -c true; done
time for i in $(seq 1000); do dash -c true; done
```

On the laptop in the video: 2.35 s for bash, 1.78 s for dash (1000 starts each, container capped at 4 CPUs).
A later run on the same laptop gave 1.37 s and 0.72 s. Your numbers will differ; dash should still win.
Most of the time is the kernel starting processes, so do not expect a big multiplier.

## Caveats

- The video shows these in a VHS recording with a coloured prompt. Here the prompt is the plain Debian one.
- The Nushell download picks `x86_64` or `aarch64` from `uname -m`. Other CPUs are not covered.
- Change `NU=0.117.0` in the Dockerfile for a newer Nushell. Commands may change between 0.x releases.
- The bash 4.3 build uses `-fpermissive -std=gnu89` because modern GCC rejects the 2014 code otherwise.
