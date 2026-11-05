# runner — Dockerized GitHub Actions runner fleet

This repo runs a self-hosted GitHub Actions runner fleet for the `dhuseby` Rust
repos. One container runs one repo. The fleet serves four repos today:

`cruzr`, `denyfs`, `gold-vault`, `wide-log`

## How it works

- Each repo gets one runner container. The name pattern is `<name>-r1`.
  The fixed `-r1` suffix leaves room for an `-r2` replica of a busy repo later.
- The container registers an ephemeral runner, runs one job, exits, and the
  `restart: unless-stopped` policy starts it again for the next job.
- Authentication uses a GitHub App, not a personal access token. The app private
  key is the only long-lived credential. At each registration the entrypoint
  signs a 9-minute JWT that carries the client ID as the issuer and sets the
  issue time 60 seconds in the past for clock drift, exchanges it for a 1-hour
  installation token, and exchanges that for a registration token.
- The app key lives at `/srv/secrets/runner/github-app.pem` on the build
  machine and reaches each container as the compose secret
  `/run/secrets/github_app_key`.
- Each container mounts the host Docker socket at `/var/run/docker.sock`, so
  jobs can run `docker` commands against the host daemon. Jobs must not run
  `docker compose down` or `docker rm`: the daemon they reach is the one that
  runs the runner fleet itself (see Part 6).
- Four caches live on `/srv/cache` and are shared by all runners:
  the cargo registry at `/srv/cache/cargo`, one build directory per runner at
  `/srv/cache/cargo-target/<runner-name>`, the sccache object cache at
  `/srv/cache/sccache`, and the Docker image cache at `/srv/cache/docker`.
  Dependency compilations run through sccache, so an object compiled for one
  repo serves every other repo. All caches start empty on the new server:
  the registry, the build directories, sccache, and the Docker layer cache
  warm up from the first jobs.
- Each container holds a 2 GB memory cap and may use swap up to 4 GB more
  (`mem_limit: '2g'`, `memswap_limit: '6g'`). The 128 GB swap partition absorbs
  a rare compile-memory spike. Four containers are the right fleet size for
  the four-core build machine, with room for replicas up to the
  about-twelve cap.

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
printf 'vm.swappiness=10\n' | sudo tee /etc/sysctl.d/90-runner-swappiness.conf
sudo sysctl -p /etc/sysctl.d/90-runner-swappiness.conf
sysctl vm.swappiness
```

The last command must print `vm.swappiness = 10`.

You also need `git` with GPG signing configured for the commits in Part 6.

## Part 1 — Create and configure the GitHub App

This fleet runs under your personal `dhuseby` account, so the app is a
user-owned GitHub App. Do this from that account's GitHub session.

> This part is the prerequisite for everything else. The compose file carries
> placeholder identity numbers until Part 1 is complete.

1. On GitHub, open your account `Settings`, then `Developer settings`, then
   `GitHub Apps`, then `New GitHub App` (direct link:
   `https://github.com/settings/apps/new`).
2. Name the app, for example `dhuseby-runners`, and set the homepage URL
   to any reachable page, for example your profile page.
3. Clear the callback URL, the webhook URL and its `Active` flag, and the
   user authorization options. This app is a machine identity. It makes API
   calls itself and impersonates no user.
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
9. Click `Install App`, select the `dhuseby` account, choose
   `Only select repositories`, and select the four repos:
   `cruzr`, `denyfs`, `gold-vault`, `wide-log`.
10. Record the numeric `Installation ID`. For a user installation it shows in
    the installation URL:
    `https://github.com/settings/installations/<ID>`.

## Part 2 — Place the app key on the build machine

The key file is the single long-lived credential on the runner path. Keep it
off the repo and off any disk where it can land in a backup or a commit.
A committed key is a security incident. If it ever happens, rotate the key
(see Operations) and remove the credential from git history.

1. Create the secret directory on the build machine:
   ```bash
   sudo mkdir -p /srv/secrets/runner
   ```
2. Copy the downloaded `.pem` into it and set owner and mode:
   ```bash
   sudo cp ~/Downloads/<app>.<DATE>.private-key.pem /srv/secrets/runner/github-app.pem
   sudo chown root:root /srv/secrets/runner/github-app.pem
   sudo chmod 0600 /srv/secrets/runner/github-app.pem
   ls -l /srv/secrets/runner/github-app.pem
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

1. On GitHub, create a token that can write packages, and put it in the
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
   - A fine-grained PAT with `dhuseby` as the resource owner and `Packages`
     set to Read and write. Fine-grained tokens authenticate only with the
     `Bearer` scheme; the `token` scheme returns 401.
   Tokens are user-owned. The push with this token creates the package under
   your account.
2. From the repo directory, log in from the environment variable and build:
   ```bash
   echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-username> --password-stdin
   docker build -t ghcr.io/dhuseby/runner:latest .
   ```
   The username is the GitHub account that owns the token. Always pass the
   token through `--password-stdin`: a password on the command line lands in
   the shell history and the process list. The build takes tens of minutes.
   It compiles the pinned Rust toolchains and the `cargo-deny`, `cargo-fuzz`,
   and `cargo-audit` binaries into image layers.
3. Push the image:
   ```bash
   docker push ghcr.io/dhuseby/runner:latest
   ```
   The first push creates the `runner` package under `dhuseby`. If the push
   is denied, re-check the token scope and that `docker login ghcr.io` used
   the token's account.
4. If other machines must pull the image, change the package visibility to
   public on the package page, or run `docker login ghcr.io` there first.
5. Log out when the push is done:
   ```bash
   docker logout ghcr.io
   ```
   This clears the stored credential from `~/.docker/config.json`.

## Part 4 — Start the fleet with docker compose

Before the first start, make sure Part 2 is complete: the key file exists and
the two identity values hold real values.

1. From the repo directory, start all four containers:
   ```bash
   docker compose up -d
   ```
2. Check that four containers are up:
   ```bash
   docker compose ps
   ```
3. Follow one runner's registration output:
   ```bash
   docker compose logs -f cruzr
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

Four idle containers use almost no CPU. Each sits near zero use under its
2 GB limit. After a job finishes, the container exits and compose starts a
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
Look for `<name>-r1`, for example `cruzr-r1`, with the status `Idle` or
`Online`, and the labels `self-hosted`, `linux`, `x64`, `ephemeral`.

The entrypoint registers with `--replace`. On every restart the new
registration replaces any stuck old registration, so a restarted runner does
not strand an `Offline` entry in the UI.

### Add a repo

1. Push the new repo to the `dhuseby` account.
2. On the app installation page, add the repo to `Repository access`. The
   existing Installation ID stays valid.
3. Add a service block in `docker-compose.yaml`, following the
   `x-runner-common` and `x-runner-env` anchor shape of the existing blocks.
   Set a unique `container_name` and `RUNNER_NAME`, and set `REPO_URL` to the
   new repo. The name pattern is `<name>-r1`.
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

The image carries the toolchains and binaries the workflows use: `stable` as
the default with `rustfmt` and `clippy`, the pinned `1.99.1`, `nightly` with
`miri`, and the `cargo-deny`, `cargo-fuzz`, and `cargo-audit` binaries. A
job-time `rustup toolchain install 1.99.1` is a no-op. When a toolchain
release drifts past the image, the first affected job downloads the new one
(see Operations).

Guard any `cargo install` step. The image already carries the tools, so the
guard turns a minute-long compile into a fast check:

```diff
-        run: cargo install <tool>
+        run: command -v <tool> >/dev/null 2>&1 || cargo install <tool>
```

> Every `docker` command in a job acts on the host daemon through the mounted
> socket. Never run `docker compose down` or `docker rm` from inside a runner
> job: the daemon it reaches also runs the runner fleet itself.

### Case A — repos without CI: cruzr, denyfs, gold-vault

These three repos currently return public HTTP 404: push them to
`github.com/dhuseby` or change their visibility first. The app installation
and the runner registration both need a reachable repo.

Create `.github/workflows/rust.yml` in each repo from this template:

```yaml
name: rust

on:
  push:
  pull_request:

jobs:
  fmt:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: cargo fmt --all -- --check
  clippy:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: cargo clippy --all-targets --all-features -- -D warnings
  build:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: cargo build --workspace --all-features --locked
  test:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: cargo test --all-features --locked
  audit:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: command -v cargo-audit >/dev/null 2>&1 || cargo install cargo-audit --locked
      - run: cargo audit
```

Add an MSRV job only to `denyfs` and `gold-vault` — their manifests pin
`rust-version = "1.99.1"`:

```yaml
  msrv:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - run: cargo +1.99.1 check --all-features --locked
```

The template needs no toolchain install or setup steps: the image already
carries everything the jobs call, and every job runs on the shared caches.

### Case B — wide-log: edit the existing workflows

`wide-log` already carries `.github/workflows/ci.yml` and
`.github/workflows/rust.yml`. Edit both:

1. Switch the runner selection in every job:

   ```diff
   -    runs-on: ubuntu-latest
   +    runs-on: [self-hosted, linux, x64]
   ```

2. Change the `on:` trigger branches from `main` to `master`. The default
   branch is `master`, so the current `main` triggers never fire.
3. Keep the miri, fuzz, deny, and msrv jobs. The image supports them
   natively: `nightly` with `miri`, `cargo-fuzz`, `cargo-deny`, and
   `cargo-audit` are baked in, and the guarded `cargo install` steps become
   no-ops.
4. Point the msrv job at `1.99.1`: change
   `rustup toolchain install 1.88.0 --profile minimal --component clippy`
   and the `cargo +1.88.0` invocations to `1.99.1`, matching the
   `rust-version = "1.99.1"` in the manifests. The baked toolchain makes the
   install a no-op; only the `clippy` component still downloads once on the
   first run, because the image installs `1.99.1` minimal without clippy.

### First-run check

1. Push one workflow change to a small repo, for example `denyfs`.
2. In the Actions tab, open the run and check the job page. The runner name
   must show `denyfs-r1`, not a GitHub-hosted runner.
3. Run the job a second time. The guarded install steps now skip, and the
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
   docker build -t ghcr.io/dhuseby/runner:latest .
   docker push ghcr.io/dhuseby/runner:latest
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
   sudo install -o root -g root -m 0600 ~/Downloads/<app>.<DATE>.private-key.pem /srv/secrets/runner/github-app.pem
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
docker exec cruzr-r1 sccache --show-stats
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

Jobs that use the baked toolchains download nothing: `nightly` and `miri`
ship in the image, which removes the old source of writable-layer growth
from job-time installs. A job that requests a toolchain version the image
lacks — a new stable, or a future MSRV bump — still downloads it into the
container writable layer, which also grows slowly from other writes. Both
fix the same way:

```bash
docker compose up -d --force-recreate
```

To stop the drift permanently, pin the new version in the image: change the
toolchain line in the `Dockerfile`, rebuild, and push as in Part 3.

### Memory capacity

If a job reaches its swap allowance and slows down, raise that one service.
Set `mem_limit: '4g'` and `memswap_limit: '8g'` on that service, then run
`docker compose up -d <service>` to recreate it. Watch the totals with
`docker stats` and keep the fleet near 12 containers or fewer.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Jobs queue forever | The job `runs-on` labels do not match the runner labels | Compare the job `runs-on` with the `LABELS` value and the four labels in the Runners UI |
| `HTTP 401 from the access-token endpoint` | The key does not match the Client ID | Re-download the key and repeat the Part 2 steps, and check `CLIENT_ID` |
| `HTTP 401 from the registration-token endpoint` | The installation token was rejected; rare and usually transient | Run `docker compose up -d <service>` again; if it repeats, check the app installation and `INSTALLATION_ID` |
| `HTTP 404 from the access-token endpoint` | Wrong `INSTALLATION_ID`, or the app is not installed on that repo | Check the Installation ID and the app `Repository access` |
| `HTTP 404 from the registration-token endpoint` | The repo does not exist under `github.com/dhuseby` yet, or the app is not installed on it | Push the repo or unhide it, and check the app `Repository access` |
| `HTTP 403 from the access-token endpoint` | The app lacks the `Administration` permission | Set `Administration` to `Read and write` in the app settings |
| `HTTP 403 from the registration-token endpoint` | The app lacks the `Administration` permission | Set `Administration` to `Read and write` in the app settings |
| Containers exit in a loop with a missing-key message | The key file is missing, empty, or unreadable | Repeat the Part 2 steps, then `docker compose down` and `docker compose up -d` |
| A job slows down or dies | The job hit its swap allowance | Raise `mem_limit` and `memswap_limit` for that service |
| One job misbehaves only under sccache | A compile is not cache-safe | Set `RUSTC_WRAPPER: ''` in that step's `env:` so cargo skips the wrapper for that job |
| `rust-lld: cannot open crtn.o` or `linker 'cc' not found` | The image lost its linker packages | Run `gcc --version` in a fresh container; if it fails, rebuild the image |
| A runner shows `Offline` in the UI | The container stopped | `docker compose logs <service>`, then `docker compose up -d <service>`. The `--replace` registration clears the stale entry |
| `A session for this runner already exists.` | A compose down killed a container that held a live session, and the orphaned session was minutes from expiry | Nothing manual: the entrypoint deletes the stale same-name registration at each start, and the runner retries its session every 30 seconds |
