# Every shell from the video in one Debian 13 container, plus an old, unpatched bash 4.3 for the Shellshock demo.
#   docker build -t shells .
#   docker run --rm -it --hostname laptop shells
# The bash 4.3 build takes a few minutes. It is vulnerable on purpose: it lives only in /opt/bash-4.3, use it for the demo only.

FROM debian:trixie AS bash43
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc make libc6-dev bison curl ca-certificates >/dev/null \
 && curl -fsSL https://ftp.gnu.org/gnu/bash/bash-4.3.tar.gz | tar -xz -C /tmp \
 && cd /tmp/bash-4.3 && CFLAGS="-O2 -fpermissive -std=gnu89" ./configure -q --prefix=/opt/bash-4.3 --without-bash-malloc >/dev/null \
 && make -s -j4 >/dev/null 2>&1 && make -s install >/dev/null 2>&1 && /opt/bash-4.3/bin/bash --version | head -1

FROM debian:trixie
ARG NU=0.117.0
# man pages are off in the Debian image: turn them back on so fish can build completions from them
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker \
 && apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      bash dash zsh fish tcsh ksh busybox man-db manpages coreutils procps xz-utils curl ca-certificates >/dev/null \
 && apt-get install -y -qq --reinstall coreutils >/dev/null \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://github.com/nushell/nushell/releases/download/$NU/nu-$NU-$(uname -m)-unknown-linux-gnu.tar.gz | tar -xz -C /opt \
 && ln -s /opt/nu-$NU-$(uname -m)-unknown-linux-gnu/nu /usr/local/bin/nu \
 && useradd -m -s /bin/bash demo
COPY --from=bash43 /opt/bash-4.3 /opt/bash-4.3
USER demo
WORKDIR /home/demo
RUN fish -c 'set -U fish_greeting ""; fish_update_completions >/dev/null' \
 && mkdir -p ~/.config/nushell && echo '$env.config.show_banner = false' > ~/.config/nushell/config.nu && touch ~/.config/nushell/env.nu
CMD ["bash"]
