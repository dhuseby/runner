# multi-runner — Dockerized GitHub Actions runner fleet

This repo runs a self-hosted GitHub Actions runner fleet for the `cryptidtech` Rust crates.
One container runs one repo. The fleet serves ten repos today:

`multi-base`, `multi-cbor`, `multi-cid`, `multi-codec`, `multi-hash`, `multi-key`,
`multi-sig`, `multi-trait`, `multi-util`, `multi-vlad`

`multi-proof` joins on push with a commented service block in `docker-compose.yaml`.
`multi-proof-plans` holds documents only and runs nothing.

## How it works

- Each repo gets one runner container. The name pattern is `multi-<name>-r1`.
  The fixed `-r1` suffix leaves room for an `-r2` replica of a busy repo later.
- The container registers an ephemeral runner, runs one job, exits, and the
  `restart: unless-stopped` policy starts it again for the next job.
- Authentication uses a GitHub App, not a personal access token. The app private
  key is the only long-lived credential. At each registration the entrypoint
  signs a 9-minute JWT that carries the client ID as the issuer and sets the
  issue time 60 seconds in the past for clock drift, exchanges it for a 1-hour
  installation token, and exchanges that for a registration token.
- The app key lives at `/srv/secrets/multi-runner/github-app.pem` on the build
  machine and reaches each container as the compose secret
  `/run/secrets/github_app_key`.
- Four caches live on `/srv/cache` and are shared by all runners:
  the cargo registry at `/srv/cache/cargo`, one build directory per runner at
  `/srv/cache/cargo-target/<runner-name>`, the sccache object cache at
  `/srv/cache/sccache`, and the Docker image cache at `/srv/cache/docker`.
  Dependency compilations run through sccache, so an object compiled for one
  repo serves every other repo.
- Each container holds a 3 GB memory cap and may use swap up to 3 GB more
  (`mem_limit: '3g'`, `memswap_limit: '6g'`). The 128 GB swap partition absorbs
  a rare compile-memory spike. Ten containers are the right fleet size for the
  four-core build machine. Add an eleventh when `multi-proof` is pushed.

## Prerequisites

- A build machine with Debian Trixie, 32 GB RAM, and the Docker data root at
  `/srv/cache/docker` (`daemon.json` already carries this setting).
- `/srv` mounted with the 128 GB swap partition present.
- Docker Engine 24 or newer with the Docker Compose v2 plugin.

Check the Docker and Compose versions:

```bash
docker --version
docker compose version
```

Set the host swappiness to 10, because swap and `/srv/cache` share the same
M.2 device. Low swappiness keeps steady-state work in RAM:

```bash
printf 'vm.swappiness=10\n' | sudo tee /etc/sysctl.d/90-multi-runner-swappiness.conf
sudo sysctl -p /etc/sysctl.d/90-multi-runner-swappiness.conf
sysctl vm.swappiness
```

The last command must print `vm.swappiness = 10`.

You also need `git` with GPG signing configured for the commits in Part 6.

## Part 1 — Create and configure the GitHub App

Do this as a `cryptidtech` organization administrator.

> This part is the prerequisite for everything else. The compose file carries
> placeholder identity numbers until Part 1 is complete.

1. On GitHub, open the organization page, then `Settings`, then
   `Developer settings`, then `GitHub Apps`, then `New GitHub App`.
2. Name the app, for example `cryptidtech-runners`, and set the homepage URL
   to any reachable page, for example the organization page.
3. Clear the callback URL, the webhook URL, and the user authorization options.
   This app is a machine identity. It makes API calls itself and impersonates
   no user.
4. Under `Repository permissions`, set `Administration` to `Read and write`.
   Do not grant any other permission. The runner uses this permission to
   register itself and nothing else.
5. Under `Where can this GitHub App be installed?`, select `Any account`.
   The repo selection happens at installation time, in step 9.
6. Click `Create GitHub App`.
7. On the app page, go to `General`, then `Private keys`, and click
   `Generate a private key`. The browser downloads a `.pem` file. Keep it safe.
8. On the app settings page, record the `Client ID`. The compose file needs it.
   GitHub recommends the client ID, not the numeric `App ID`, as the JWT
   issuer.
9. Click `Install App`, select the `cryptidtech` organization, choose
   `Only select repositories`, and select the ten repos:
   `multi-base`, `multi-cbor`, `multi-cid`, `multi-codec`, `multi-hash`,
   `multi-key`, `multi-sig`, `multi-trait`, `multi-util`, `multi-vlad`.
10. Record the numeric `Installation ID`. It shows in the installation URL:
    `https://github.com/organizations/cryptidtech/settings/installations/<ID>`.

## Part 2 — Place the app key on the build machine

The key file is the single long-lived credential on the runner path. Keep it
off the repo and off any disk where it can land in a backup or a commit.
A committed key is a security incident. If it ever happens, rotate the key
(see Operations) and remove the credential from git history.

1. Create the secret directory on the build machine:
   ```bash
   sudo mkdir -p /srv/secrets/multi-runner
   ```
2. Copy the downloaded `.pem` into it and set owner and mode:
   ```bash
   sudo cp ~/Downloads/<app>.<DATE>.private-key.pem /srv/secrets/multi-runner/github-app.pem
   sudo chown root:root /srv/secrets/multi-runner/github-app.pem
   sudo chmod 0600 /srv/secrets/multi-runner/github-app.pem
   ls -l /srv/secrets/multi-runner/github-app.pem
   ```
   The last line must show `-rw-------` with owner `root root`. Then delete
   the downloaded copy from `~/Downloads`, so the key exists only at the
   secret path.
3. Set the app identity values in `docker-compose.yaml`. Find this block:
   ```yaml
   x-runner-env: &runner-env
     RUNNER_SCOPE: 'repo'
     CLIENT_ID: 'Iv1.0000000000000000'
     INSTALLATION_ID: '0000000'
     LABELS: 'self-hosted,linux,x64,ephemeral'
   ```
   Replace `Iv1.0000000000000000` with the Client ID and `0000000` with the
   Installation ID from Part 1. Both are identifiers, not secrets, and stay in
   plain compose text. A wrong Client ID makes registration fail with HTTP 401.
   A wrong Installation ID fails with HTTP 404. Both failures name the
   mismatch in the container log.

## Part 3 — Build and upload the image

The image push needs a separate personal access token. This token never enters
the runner path. It exists only for the push steps here.

1. On GitHub, create a token that can write org packages, and put it in the
   `GHCR_TOKEN` environment variable for the session only. Never place it in
   the repo or an `.env` file. Two token kinds work:
   - A classic PAT with the `write:packages` scope. Check the token and its
     scope with:
     ```bash
     curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${GHCR_TOKEN}" https://api.github.com/user
     curl -sI -H "Authorization: Bearer ${GHCR_TOKEN}" https://api.github.com/ | grep -i x-oauth-scopes
     ```
     The first call must return `200`; the second must show `write:packages`
     in the list. Fine-grained tokens print no scope list.
   - A fine-grained PAT with `cryptidtech` as the resource owner and
     `Packages` set to Read and write. The org must allow fine-grained tokens
     under org `Settings`, then `Personal access token policy`. Fine-grained
     tokens authenticate only with the `Bearer` scheme; the `token` scheme
     returns 401.
   Tokens are user-owned. Your membership in `cryptidtech` lets the push
   create the org package.
2. From the repo directory, log in from the environment variable and build:
   ```bash
   echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-username> --password-stdin
   docker build -t ghcr.io/cryptidtech/multi-runner:latest .
   ```
   The username is the GitHub account that owns the token. Always pass the
   token through `--password-stdin`: a password on the command line lands in
   the shell history and the process list. The build takes a few minutes. It
   compiles the pinned Rust toolchains, `cargo-llvm-cov`, and `cargo-audit`
   into image layers.
3. Push the image:
   ```bash
   docker push ghcr.io/cryptidtech/multi-runner:latest
   ```
   The first push creates the `multi-runner` package under `cryptidtech`. If
   the push is denied, an org owner must allow package creation for members
   under org `Settings`, then `Packages`.
4. If other machines must pull the image, change the package visibility to
   public in the org `Settings` under `Packages`, or run
   `docker login ghcr.io` there first.
5. Log out when the push is done:
   ```bash
   docker logout ghcr.io
   ```
   This clears the stored credential from `~/.docker/config.json`.

## Part 4 — Start the fleet with docker compose

Before the first start, make sure Part 2 is complete: the key file exists and
the two identity values hold real values.

1. From the repo directory, start all ten containers:
   ```bash
   docker compose up -d
   ```
2. Check that ten containers are up:
   ```bash
   docker compose ps
   ```
3. Follow one runner's registration output:
   ```bash
   docker compose logs -f multi-base
   ```
   Expect these lines in order: `Minting the App JWT (9-minute window)...`,
   `Requesting the installation access token...`,
   `Requesting the runner registration token from GitHub...`, and
   `Runner configured successfully. Launching.`
4. Watch live memory against the caps:
   ```bash
   docker stats
   ```
5. Stop the fleet when needed:
   ```bash
   docker compose down
   ```

Ten idle containers use almost no CPU. Each sits near zero use under its
3 GB limit. After a job finishes, the container exits and compose starts a
fresh copy, which registers again with a fresh token.

A quick `docker compose down` followed by `docker compose up -d` can print
`A session for this runner already exists.` on some runners: the down killed
a container that held a live session, and GitHub keeps the orphaned session
for a short time. The entrypoint deletes the stale same-name registration
at each start, so the next cycle clears the conflict without any manual
step in the GitHub UI.

## Part 5 — Runner registration and adding repos

Registration is automatic. After Part 4, each repo shows one runner in the
GitHub UI: open the repo, then `Settings`, then `Actions`, then `Runners`.
Look for `multi-<name>-r1` with the status `Idle` or `Online`, and the labels
`self-hosted`, `linux`, `x64`, `ephemeral`.

The entrypoint registers with `--replace`. On every restart the new
registration replaces any stuck old registration, so a restarted runner does
not strand an `Offline` entry in the UI.

### Add a repo

1. Push the new repo to the `cryptidtech` org.
2. On the app installation page, add the repo to `Repository access`. The
   existing Installation ID stays valid.
3. Add or uncomment a service block in `docker-compose.yaml`. Copy the shape
   of an existing block. Set a unique `container_name` and `RUNNER_NAME`, and
   set `REPO_URL` to the new repo. The commented `multi-proof` block shows the
   full shape.
4. Run `docker compose up -d`.
5. Add the workflow file from Part 6.

### Add a replica for a busy repo

1. Copy the repo's service block in `docker-compose.yaml`.
2. Change the name suffix from `-r1` to `-r2` in the service key,
   `container_name`, and `RUNNER_NAME`. Keep `REPO_URL` the same.
   The name also gives the replica its own build directory under
   `/srv/cache/cargo-target/`.
3. Run `docker compose up -d`.
   Keep the total fleet at about 12 containers or fewer.

## Part 6 — Point the workflows at the runners

Do not merge workflow changes until the runners are online. A workflow job
with no matching runner queues forever.

In each sibling repo, open `.github/workflows/rust.yml` and change the runner
selection:

```diff
-    runs-on: ubuntu-latest
+    runs-on: [self-hosted, linux, x64]
```

Leave the `dtolnay/rust-toolchain` steps unchanged. The image carries the
toolchains the workflows request: `stable` with `rustfmt`, `clippy`, and
`llvm-tools-preview`, the pinned `1.99.0`, and `nightly` with the
`thumbv6m-none-eabi` target. When a toolchain release drifts past the image,
the first affected job downloads the new one (see Operations). Keep the
`cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features
-- -D warnings`, and `cargo test --verbose --all-features` steps unchanged.

Guard the two `cargo install` steps. The image already carries both tools, so
the guard turns a minute-long compile into a fast check:

```diff
-        run: cargo install cargo-llvm-cov
+        run: command -v cargo-llvm-cov >/dev/null 2>&1 || cargo install cargo-llvm-cov
```

```diff
-        run: cargo install cargo-audit
+        run: command -v cargo-audit >/dev/null 2>&1 || cargo install cargo-audit
```

### A workflow for a repo without CI

Use the `multi-base` `.github/workflows/rust.yml` as the template, and name
the file `rust.yml`. Its five jobs:

- a build job with the fmt, clippy, build, and test steps
- an MSRV job that runs `cargo check --all-features` on the pinned `1.99.0`
  toolchain
- an `ensure_no_std` job that builds for `thumbv6m-none-eabi` on nightly
- a coverage job that runs `cargo llvm-cov --workspace` with
  `llvm-tools-preview` and uploads `lcov.info` through Codecov
- an audit job

Keep `runs-on: [self-hosted, linux, x64]` on every job.

### The multi-proof steps

1. Create `.github/workflows/rust.yml` in `multi-proof` from the `multi-base`
   template with the build, MSRV, coverage, and audit jobs. Omit the
   `ensure_no_std` job, because the crates that the `multi-proof` workspace
   builds carry no `no_std` markers. The coverage job uses `--workspace`,
   because `multi-proof` is a workspace itself.
2. Install the app on `multi-proof` through `Repository access`.
3. Uncomment the `multi-proof` service block in `docker-compose.yaml`.
4. Run `docker compose up -d`.

### First-run check

1. Push one workflow change to a small repo, for example `multi-util`.
2. In the Actions tab, open the run and check the job page. The runner name
   must show `multi-util-r1`, not a GitHub-hosted runner.
3. Run the job a second time. The two `cargo install` steps now skip, and the
   build reuses the persistent build directory.

## Operations

### Image update

The image pins the runner release in `ARG RUNNER_VERSION` and sccache in
`ARG SCCACHE_VERSION`. A dynamic version in the build would break layer
caching, so the pin moves only through a deliberate rebuild.

1. Read the latest runner release tag:
   ```bash
   curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name
   ```
2. Edit `Dockerfile` and set `ARG RUNNER_VERSION` to the tag without the
   leading `v`.
3. Build and push:
   ```bash
   docker build -t ghcr.io/cryptidtech/multi-runner:latest .
   docker push ghcr.io/cryptidtech/multi-runner:latest
   ```
4. Recreate the fleet on the new image:
   ```bash
   docker compose up -d --force-recreate
   ```

App key rotation — two-key overlap:

1. On the app page, `General`, then `Private keys`, click `Generate a private
   key`. Both keys work during the overlap.
2. Install the new key over the old file:
   ```bash
   sudo install -o root -g root -m 0600 ~/Downloads/<app>.<DATE>.private-key.pem /srv/secrets/multi-runner/github-app.pem
   ```
   Then delete the downloaded copy from `~/Downloads`, as in Part 2.
3. Recreate the fleet:
   ```bash
   docker compose up -d --force-recreate
   ```
4. After every runner shows `Idle` again, wait one registration cycle and
   remove the old key on the app page.

Renew the ghcr PAT before it expires. It is separate from the runner path.

### Cache inventory

| Path | Set by | Holds |
|------|--------|-------|
| `/srv/cache/cargo` | `CARGO_HOME` | The crate registry, downloads, and runtime-installed tools |
| `/srv/cache/cargo-target/<runner>` | `CARGO_TARGET_DIR` | One persistent build directory per runner |
| `/srv/cache/sccache` | `SCCACHE_DIR` | The shared compile-object cache, capped at 50 GB |
| `/srv/cache/docker` | `daemon.json` data-root | The Docker image layer cache |

Read the sccache hit rate from any runner:

```bash
docker exec multi-base-r1 sccache --show-stats
```

Read the stats right after a job. A freshly restarted container reports zero.

Check cache disk use:

```bash
du -sh /srv/cache/*
```

### Disk growth and the build-dir prune

Each runner start prunes build directories that sat idle for over 14 days:

```bash
find /srv/cache/cargo-target -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
```

A pruned directory rebuilds mostly from the sccache cache, so the prune costs
little re-work. If disk still grows, look at the Docker image cache under
`/srv/cache/docker` and prune unused images.

### Toolchain drift and writable-layer growth

`dtolnay/rust-toolchain@nightly` resolves the nightly of the day. A drifted
download lands in the container writable layer, which also grows slowly from
other writes. Both fix the same way:

```bash
docker compose up -d --force-recreate
```

To keep nightly stable across rebuilds, pin it with a dated toolchain spec in
the image, or accept the one-time download on the first affected job.

### Memory capacity

If a coverage job reaches its swap allowance and slows down, raise that one
service. Set `mem_limit: '4g'` and `memswap_limit: '8g'` on that service, then
run `docker compose up -d <service>` to recreate it. Watch the totals with
`docker stats` and keep the fleet near 12 containers or fewer.

### Codecov on public repos

The sibling repos are public. The `codecov/codecov-action@v4` upload runs
without a token for public repos, so no token setup exists on this path.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Jobs queue forever | The job `runs-on` labels do not match the runner labels | Compare the job `runs-on` with the `LABELS` value and the four labels in the Runners UI |
| `HTTP 401 from the access-token endpoint` | The key does not match the Client ID | Re-download the key and repeat the Part 2 steps, and check `CLIENT_ID` |
| `HTTP 401 from the registration-token endpoint` | The installation token was rejected; rare and usually transient | Run `docker compose up -d <service>` again; if it repeats, check the app installation and `INSTALLATION_ID` |
| `HTTP 404 from the access-token endpoint` | Wrong `INSTALLATION_ID`, or the app is not installed on that repo | Check the Installation ID and the app `Repository access` |
| `HTTP 403 from the access-token endpoint` | The app lacks the `Administration` permission | Set `Administration` to `Read and write` in the app settings |
| `HTTP 403 from the registration-token endpoint` | The app lacks the `Administration` permission | Set `Administration` to `Read and write` in the app settings |
| Containers exit in a loop with a missing-key message | The key file is missing, empty, or unreadable | Repeat the Part 2 steps, then `docker compose down` and `docker compose up -d` |
| A coverage job slows down or dies | The job hit its swap allowance | Raise `mem_limit` and `memswap_limit` for that service |
| One job misbehaves only under sccache | A compile is not cache-safe | Set `RUSTC_WRAPPER: ''` in that step's `env:` so cargo skips the wrapper for that job |
| `rust-lld: cannot open crtn.o` or `linker 'cc' not found` | The image lost its linker packages | Run `gcc --version` in a fresh container; if it fails, rebuild the image |
| A runner shows `Offline` in the UI | The container stopped | `docker compose logs <service>`, then `docker compose up -d <service>`. The `--replace` registration clears the stale entry |
| `A session for this runner already exists.` | A compose down killed a container that held a live session, and the orphaned session was minutes from expiry | Nothing manual: the entrypoint deletes the stale same-name registration at each start, and the runner retries its session every 30 seconds |
