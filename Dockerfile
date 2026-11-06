# ─────────────────────────────────────────────────────────────
# Debian 13 (trixie) + GitHub Actions runner + Rust toolchains + full BuildKit
# ─────────────────────────────────────────────────────────────
FROM debian:13-slim

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=1

# Install the GitHub runner dependencies (small list) and the Docker CLI +
# Buildx plugin (from official Docker repos)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg && \
    \
    # Add Docker's official GPG key and repository
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    \
    # Refresh with Docker repo and install everything. `gcc` supplies the
    # system linker (cc) that rustc requires to link test, bench, and
    # coverage executables, even when the crate contains no C code.
    # `libc6-dev` supplies the C start files and linker scripts that `gcc`
    # only Recommends, and this install runs with --no-install-recommends.
    # `make`, `cmake`, and `pkg-config` drive the C build systems that
    # `-sys` crate build scripts invoke: tikv-jemalloc-sys runs autotools
    # configure and then `make`, and aws-lc-sys (the rustls crypto provider
    # reached through the cruzr graph) drives CMake, whose default
    # generator also runs `make`. `pkg-config` locates preinstalled C
    # libraries so crates link system libs instead of vendoring.
    # `openssl` is the command-line tool used to sign GitHub App JWTs.
    apt-get update && \
    apt-get install -y --no-install-recommends \
        bc \
        ca-certificates \
        cmake \
        containerd.io \
        coreutils \
        docker-ce \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        gcc \
        gh \
        git \
        gnuplot \
        gzip \
        jq \
        libc6-dev \
        libssl3 \
        liblttng-ust1 \
        libkrb5-3 \
        libicu76 \
        libunwind8 \
        libuuid1 \
        make \
        openssh-client \
        openssl \
        pandoc \
        patch \
        pkg-config \
        tar \
        wget \
        unzip \
        util-linux \
        zip && \
    rm -rf /var/lib/apt/lists/*

# Force BuildKit for ALL `docker build` commands (no DOCKER_BUILDKIT=1 needed)
RUN mkdir -p /root/.docker && \
    echo '{ "features": { "buildkit": "true" } }' > /root/.docker/config.json

# Install latest stable yq (mikefarah) — tiny binary, no deps
ENV YQ_VERSION=v4.49.2
RUN arch=$(dpkg --print-architecture) && \
    curl -L --fail -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" && \
    chmod +x /usr/local/bin/yq

# ─────────────────────────────────────────────────────────────
# Rust toolchains for the CI images of cruzr, denyfs, gold-vault,
# and wide-log. stable is the default toolchain and carries the
# rustfmt and clippy components every repo formats and lints with.
# All four repos set rust-version 1.99.1 in their manifests, so the
# 1.99.1 MSRV toolchain is preinstalled here and every CI job compiles
# on the same compiler. wide-log's miri job needs the miri component
# on nightly. The coverage job in every repo runs cargo-llvm-cov, so
# stable also carries llvm-tools-preview, its instrumentation source.
# Toolchain binaries live in the image; build caches live on /srv/cache.
# ─────────────────────────────────────────────────────────────
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl -fsSL "https://sh.rustup.rs" | sh -s -- -y --profile minimal --no-modify-path --default-toolchain stable && \
    rustup component add --toolchain stable rustfmt clippy llvm-tools-preview && \
    rustup toolchain install 1.99.1 --profile minimal && \
    rustup toolchain install nightly --profile minimal --component miri && \
    rustup default stable

# Supply-chain and coverage CLIs: the audit job in every repo runs
# cargo-audit against its lockfiles, wide-log's ci.yml runs cargo-deny
# and cargo-fuzz, and the coverage job in every repo runs cargo-llvm-cov.
RUN cargo install --locked cargo-deny cargo-fuzz cargo-audit cargo-llvm-cov

# Shared compile cache server for all runner containers. The binary ships
# in the image; the cache content itself lives on the host cache mount.
ARG SCCACHE_VERSION=v0.19.0
RUN curl -fsSL \
        "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/cargo/bin \
            "sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" && \
    chmod 0755 /usr/local/cargo/bin/sccache

# GitHub Actions runner (pinned release; bump RUNNER_VERSION to update).
# The entrypoint passes --disableupdate, so the version moves only through
# an image rebuild.
ARG RUNNER_VERSION=2.338.2
WORKDIR /actions-runner

RUN curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" && \
    tar xzf runner.tar.gz && \
    rm runner.tar.gz && \
    ./bin/installdependencies.sh && \
    # Clean up runner's own apt caches
    rm -rf /var/lib/apt/lists/*

# Copy your entrypoint script (ephemeral registration)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
