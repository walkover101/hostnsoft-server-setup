# server-setup.sh — why it does what it does

Companion to `server-setup.sh`. The script keeps short comments saying
*what* each step does; this file holds the *why* — mostly incidents that
cost real downtime, which is why the reasoning is worth more than the
line of bash it explains.

Anchors here are referenced from the script as `server-setup.md#<anchor>`.

---

## <a id="overview"></a>Overview and usage

Provisions a server with Nomad, Docker (+BuildKit), Railpack, Redis,
Traefik (Cloudflare DNS-01 TLS), `deploy-service` and `api-service` (both
under pm2), and applies pending Prisma migrations before starting either.

Target: a fresh Ubuntu 24.04 server. Re-running is safe and expected.

```bash
source prod.set-env.sh
source prod.variables.sh
sudo -E bash server-setup.sh
```

The script takes **no command-line flags**. Every value comes from
environment variables, normally set by sourcing `<env>.set-env.sh` and
`<env>.variables.sh` immediately before. `sudo -E` preserves them.

DNS is **manual** — see `README.md` for the records. This script
configures the server side only and never touches DNS.

### Required variables

| Variable | Notes |
|---|---|
| `APP_ENV` | `test` \| `demo` \| `prod` |
| `DOMAIN` | e.g. `embarko.ai` |
| `CF_DNS_API_TOKEN` | Cloudflare token, "Edit zone DNS" scope. For Traefik's DNS-01 **certificate challenge**, not for creating records |
| `ACME_EMAIL` | real address, for Let's Encrypt expiry notices |
| `DEPLOY_SERVICE_REPO` | git URL |
| `API_SERVICE_REPO` | git URL |

### Optional

| Variable | Default | Notes |
|---|---|---|
| `INTERNAL_API_SECRET` | generated | Shared secret between the two services. Must be named exactly this — it is written into each `.env` under the key both repos actually read |
| `DEPLOY_SUBDOMAIN` | `ship` | |
| `APPS_SUBDOMAIN_BASE` | `app` | apps live at `<name>.<base>.[<env>.]<DOMAIN>` |
| `APP_USER` | `ubuntu` | runs both services and pm2; shared across environments, not env-prefixed |
| `IDLE_THRESHOLD_MIN` | `360` | see [idle threshold](#idle-threshold) |
| `IMAGE_RETAIN_COUNT` | `3` | images kept per app by `deploy-service` on deploy |

---

## <a id="naming"></a>Environment-aware naming

Driven entirely by `$APP_ENV`, no exceptions.

- **prod**: bare names and domain — `deploy-service`, `api-service`,
  `ship.<DOMAIN>`
- **test/demo**: `<env>-` prefix on service names, `<env>.` inserted
  before the base domain — `test-deploy-service`, `ship.test.<DOMAIN>`

Ports are offset per environment (prod +0, test +1000, demo +2000) so
several environments can share a host without colliding.

`DOMAIN_ENV_SEGMENT` can be exported as `""` before sourcing to serve a
non-prod environment off the bare domain — useful when a domain already
had DNS and a certificate before this naming scheme existed. Directory
names, pm2 process names and the port offset are unaffected. It uses
bash's `-` rather than `:-`, so an explicitly-empty override is honoured
and only a genuinely unset value falls back to `<env>.`.

**pm2 process names always carry the `APP_ENV` prefix, even for prod**,
unlike directory/domain/Traefik names which stay bare for prod. Those are
already deployed with bare names and changing them would mean
re-provisioning working infrastructure. The prefix only affects labels in
`pm2 list`.

---

## <a id="architecture"></a>Architecture

- **deploy-service** — public. Does the build and deploy work. Auth on
  every request calls api-service's token-introspection endpoint. There is
  no bypass: every deploy request must present a token api-service
  recognises.
- **api-service** — internal only, never exposed through Traefik.
- Both repos are pulled from git. This script assumes **nothing** about
  their internals beyond "has a `package.json` with a `start` script".
  Token storage, company/project logic and so on are each repo's own
  concern.

---

## <a id="apt-lock"></a>apt lock contention

Ubuntu's `unattended-upgrades` holds the dpkg lock on its own schedule,
unrelated to anything this script does. This has actually happened here,
not theoretically. The script waits it out with a bounded retry rather
than hard-failing, since it can occur at unpredictable times on any box.

---

## <a id="direct-binaries"></a>Why Nomad and Railpack are direct binary downloads

**Nomad**: `apt.releases.hashicorp.com` does not reliably publish packages
for every Ubuntu codename — confirmed missing for 20.04/focal. apt then
silently falls back to whatever ancient version Ubuntu's `universe` repo
bundles, which is incompatible with the `nomad.hcl` this script generates.
A direct download has no dependency on OS version at all.

**Railpack**: `railpack.com/install.sh` is unusable here for two separate
confirmed reasons.

1. It uses `curl --retry-all-errors` in its actual download step, a flag
   curl gained in 7.71; Ubuntu 20.04 ships 7.68. Pre-supplying
   `RAILPACK_VERSION` only skips one *other* use of the flag — the
   download fails regardless.
2. It uses bash-only `[[ ]]` while `curl | sh` runs `dash` on Ubuntu,
   giving `sh: [[: not found` on top of the curl problem.

Downloading the release asset directly avoids both, same as Nomad.

---

## <a id="nomad-image-gc"></a>Nomad's docker image GC is disabled

`gc { image = false }` in the docker plugin config.

Nomad's docker driver garbage collects images by default (`gc.image =
true`, `image_delay = "3m"`): once the last allocation referencing an
image is collected, it deletes the image.

**That is fatal to scale-to-zero.** App images are built locally by
railpack, pushed to no registry, and referenced with `force_pull = false`
— so an image Nomad deletes is gone for good. Stopping an idle app
destroyed the only copy of its image three minutes later, and waking it
failed with `pull access denied ... repository does not exist`, which
reads like a registry auth problem and is nothing of the sort. Diagnosed
that way on 2026-09-18 against `scale-to-zero-test-1`.

Turned **off** rather than given a longer `image_delay`, because
deploy-service already owns image lifecycle end to end: `pruneOldImages()`
keeps `IMAGE_RETAIN_COUNT` versions per app after each deploy, and
teardown removes an app's images when it is deleted. Nomad's GC was a
second, uncoordinated policy on top of that — which is also why rollback
to an older `imageTag` could find its image missing.

**The gap this leaves**: `pruneOldImages()` runs only as part of a deploy,
so an app deployed once and never again keeps every image it ever had.
Use `prune-app-images.sh` (dry-run by default) to apply retention across
every app.

---

## <a id="oversubscription"></a>Memory oversubscription

A **cluster-wide scheduler setting**, not part of `nomad.hcl` and not
something a job spec can enable for itself.

deploy-service's job specs declare both `memory` (the low number Nomad
bin-packs against) and `memory_max` (the ceiling a task may burst to) —
see `hostnsoft-deploy/nomad-job-spec.js` and
`docs/Memory-oversubscription-req.md`. With this setting **off**, Nomad
still accepts those jobs but ignores `memory_max` entirely, so every app
gets its low floor as a hard cap and starts OOM-killing.

It fails quiet, not loud, which is exactly why it belongs in this script
rather than a command someone once ran by hand. `set-config` only
overrides the flags passed, so re-running is safe.

Verify: `nomad operator scheduler get-config | grep -i memory`

---

## <a id="redis"></a>Redis is not version-pinned

Installed via apt, so the version depends on the Ubuntu release (22.04
ships 6.0.x, 24.04 ships 7.0.x). Bound to `127.0.0.1` only, so no ufw
rule is needed.

Confirmed in practice: api-service's `connectorPendingLogin.ts` originally
used `GETDEL` (Redis 6.2+) and failed in prod with ``ERR unknown command
`GETDEL` `` against an older apt Redis. Fixed in that repo with
`MULTI GET+DEL`. **Keep app code Redis-version-agnostic** rather than
assuming whatever apt installs here.

---

## <a id="buildkit"></a>BuildKit: the version pin and the cache volume

### Pinned to v0.30.0, not `:latest`

BuildKit v0.31.0+ (through at least v0.32.2) bundles a runc with a
masked-paths hardening regression (CVE-2025-31133 / 52881 / 52565):
runc's `maskDir()` mounts masked paths like `/proc/acpi` with a tmpfs
option (`nr_inodes=1`) that several kernels reject with `EINVAL` —
confirmed on Ubuntu 20.04's 5.4 kernel and seen on various cloud/KVM
guest kernels. Every build-step container then fails at init with
`can't mask dir ... invalid argument`.

v0.30.0 is the last release before the regression (runc 1.3.5). Bump the
pin once BuildKit ships runc >= 1.4.4; check
<https://github.com/moby/moby/issues/52972> before assuming a newer tag
is safe.

### `--restart unless-stopped`

Caught in a 2026-09-12 reboot-resilience review, before production had
ever actually rebooted. A bare `docker run -d` does **not** come back
after a host reboot, unlike the Nomad jobs and systemd services elsewhere
here. Without it, builds would silently fail after any reboot until
someone noticed. `unless-stopped` rather than `always` so a deliberate
`docker stop buildkit` is respected.

### `-v buildkit-cache:/var/lib/buildkit`

BuildKit's entire layer cache lives in that path **inside** the container,
so the `docker rm -f` above used to destroy it on every run of this
script, making the next build of every app cold. Measured 2026-09-18: app
build times roughly doubled, to 4–5 minutes, immediately after a
re-provision with nothing else changed.

A **named volume** survives container removal, so the container stays
disposable — which is what makes this script re-runnable — while the cache
does not. Not a bind mount: the cache is BuildKit's private format,
nothing else reads it, and a named volume needs no host path created or
chowned. BuildKit runs its own GC inside the volume, so it stays bounded.

---

## <a id="traefik"></a>Traefik

One Traefik job regardless of environment — it is the shared reverse proxy
for the host, not per-environment. Router and service names carry the
env-prefixed service names so several environments' config could coexist
in one `dynamic.yml` without collisions.

### <a id="router-priorities"></a>Platform router priorities (10000 / 10100)

Traefik gives a router with no explicit priority a priority equal to its
rule's **length**. Every customer app's router (generated by
`nomad-job-spec.js`) has none, so each sits around 25–40.

The two platform routers used to be 100 and 1 — numbers chosen only to
order them against each other, which left the deploy service at priority
1, *below every app router on the host*. That stayed safe only because an
app's hostname is always `<slug>.app.<domain>` and can never equal
`$DEPLOY_HOST`. The moment apps are served at `<slug>.<domain>`, an app
named after the deploy host would emit ``Host(`$DEPLOY_HOST`)`` at ~25 and
outrank the real deploy service — taking over the endpoint agents POST
source and deploy tokens to. Traefik matches on the Host header, so DNS
does not protect this.

They are now set far above any rule-length-derived value. This is the
floor; the reserved-name list is a second, independent guard. The gap
between 10000 and 10100 preserves the original intent: `/api` must still
beat the bare host.

### <a id="access-log"></a>Access log

JSON, written to a file (not stdout) and mounted out to the host, because
every environment's deploy-service reads it directly off disk — Nomad's
captured stdout is not something another process can tail. See
`analytics/access-log-tailer.js`. One Traefik instance means one shared
log, with each environment tracking its own read position.

One request header is kept, `User-Agent`, which `analytics/bot-filter.js`
uses to tell a real visit from a credential scanner. Without it every scan
counts as traffic and an app would be woken to serve a bot probing for its
`.env`. Named explicitly rather than keeping all headers — the rest are
not needed and some (`Cookie`, `Authorization`) must never be written to
disk.

The log **directory** is world-readable and executable because Traefik's
container writes as root while deploy-service reads as `APP_USER`. The
file itself is not chmod'd here (it does not exist until Traefik's first
write); this relies on Traefik creating it with the ordinary 644 a root
process gets under a standard umask. That is the common case but has not
been independently confirmed against this exact image — if deploy-service
logs permission-denied on this path, chmod the file itself rather than
loosening the directory further.

### <a id="refresh-interval"></a>`--providers.nomad.refreshInterval=5s`

Default is 15s. That interval was a **blackout window** for scale-to-zero:
between an app being stopped and Traefik noticing, Traefik still held the
app's own router pointing at a dead allocation, so requests got a fast 502
instead of reaching the activator. Measured 2026-09-18 — ten requests sent
seconds after a stop all failed without the activator being invoked.

5s shortens the window; it cannot close it, because Traefik's view of a
stopped job can never be instantaneous. **It is closed instead by
[always-front routing](#s2z-routers).** The poll is against Nomad's local
API and is cheap, so the shorter interval is kept anyway.

### <a id="http01"></a>HTTP-01 resolver

For **client custom domains** — see api-service's
`docs/Customdomain-req.md` constraint #1. DNS-01 only works for domains in
this platform's own Cloudflare zone; HTTP-01 works for any domain pointed
at this server regardless of who controls its DNS.

Traefik natively excludes its own ACME challenge path from the
web→websecure redirect, so both coexist on `:80`. Confirmed against a real
externally-pointed test domain — don't take this on trust, re-verify per
server (README.md has the procedure).

### <a id="s2z-routers"></a>Scale-to-zero wake-on-request routers

A **stopped** app has no Traefik router at all: app routers come from the
Nomad provider, which only sees running services, so its hostname would
404. These routers hand those hostnames to the activator
(`deploy-service/activator.js`), which starts the job, waits for it, and
forwards the original request.

`priority: 500` puts the activator **permanently** in front of these apps
rather than only catching them once stopped. It was `1` — below the ~44
Traefik derives from an app router's rule length — so a running app was
reached directly, which left the blackout window described above
(roughly one request in three returned 502 when issued right after a stop,
measured 2026-09-19; zero after this change).

500 beats any rule-length-derived value (a hostname cannot exceed 253
characters) while staying far below the platform's 10000/10100, so it can
never capture `ship.<domain>` or its `/api` prefix.

**One router per app, by exact hostname, never a wildcard.** That is what
makes "no other app's traffic can reach the activator" a property of this
file rather than a hope about the activator's code.

**The list must match `deploy-service/scale-to-zero-apps.js`.** It cannot
read that file — `dynamic.yml` is generated before the repo is pulled — so
it is kept in step by hand. An app listed there but not here is never
woken, because nothing reaches the activator; listed here but not there
gets a 404 instead of a wake. Step 7 of the plan replaces this with
routers generated from that single list.

**Only covers `<app>.<APPS_DOMAIN_SUFFIX>`.** An app with a custom domain
would still 404 on that domain while stopped. `focus` was removed from the
list for exactly this reason — it also serves `focus.walkover.uk`. Check
before adding:

```bash
nomad job inspect <app> | grep -o 'Host(`[^`]*`)' | sort -u
```

---

## <a id="clean-pull"></a>Clean pull of both repos

If the code directory exists, discard **any** local drift and reset it to
exactly match the remote branch named `$APP_ENV` — never merge, never
leave stale files. Otherwise clone fresh. Either way the directory ends up
byte-for-byte what is on that branch.

This is also why `APP_DATA_ROOT` and the analytics directory live outside
any checkout: `git reset --hard && git clean -fd` runs on every re-run.

---

## <a id="env-exports"></a>Environment exports, and the `PORT` rule

Values are exported here (not just passed to pm2) so `hydrate_env_file`'s
indirect lookup `${!key}` picks them up and bakes them into each service's
`.env`. Both services load `.env` via dotenv, so that is what they see at
runtime — not whatever is on pm2's command line.

**`PORT` is exported separately per service, immediately before that
service's own `hydrate_env_file` call.** The two need different ports, so
a single shared export would leak the wrong value into whichever hydrates
second.

### <a id="unset-port"></a>Why `PORT` is unset before pm2 starts

After the hydrations, the last exported `PORT` (api-service's) is still in
scope. The pm2 ecosystem file deliberately sets no `PORT`, leaving each
service to read its own `.env` — but **dotenv does not override a variable
already present in the environment**, and `pm2 start` inherits this shell.

Left set, deploy-service comes up on api-service's port: Traefik finds
nothing on 4000 (502 on the deploy host), routes `/api` to the wrong
process, and api-service crash-loops unable to bind. That is exactly the
outage of 2026-09-17, reproducible by provisioning alone.

---

## <a id="platform-domain"></a>`PLATFORM_DOMAIN`

The platform's own zone. api-service refuses to register any custom domain
that is, or sits under, it — such a name resolves to this origin, so it
would pass DNS verification on the IP-match fallback and then take a
Traefik router for a platform hostname.

`$DOMAIN` (the bare registrable domain) is the right value. An explicit
setting in `variables.sh` deliberately wins over anything computed here:
it is a security control, so an operator stating it outright should
override inference.

---

## <a id="app-data-root"></a>`APP_DATA_ROOT`

Per-app persistent storage. Each app's `DATA_DIR` is a subdirectory,
bind-mounted into its container at `/data`.

This exists so an app's data is **not owned by its Nomad allocation**.
`DATA_DIR` used to be `/alloc/data`, which Nomad garbage collects along
with a stopped job (`job_gc_threshold`, 4h) — fine while every app ran
forever, fatal the moment anything stops one. A SQLite database would come
back empty, and silently, because an app that finds no database usually
creates a fresh one and looks healthy. **This is the prerequisite for
scale-to-zero.**

Per-environment, so prod/test/demo can never collide on an app name.
Created here rather than left to the app so it exists with the right owner
before deploy-service starts. Never under a git checkout — see
[clean pull](#clean-pull).

deploy-service chmods each app's own subdirectory to `0777` as it creates
it: Railpack images do not all run as root, and a container that cannot
write its data directory fails at runtime rather than at deploy time.

---

## <a id="npm-install"></a>Dependency install

`npm ci`, not `npm install`: a fully clean `node_modules` every run at the
exact versions pinned in `package-lock.json`. Unlike
`rm -rf node_modules package-lock.json && npm install`, which discards
those pins and lets npm resolve newer, untested versions. Falls back to
`npm install` only for a repo with no committed lockfile.

`npm ci` also always fires `@prisma/client`'s postinstall, so the Prisma
client is regenerated every run — which is why this script needs no
explicit `npx prisma generate`, while `redeploy.sh` does (its
`npm install` can be a complete no-op on a schema-only change).

**2026-09-21 — `--include=dev` made explicit.** `NODE_ENV=production` makes
npm omit devDependencies, stripping typescript so the build dies with
`tsc: not found`. That is exactly how `redeploy.sh` broke on 2026-09-17.
It had never bitten this script, but only because `sudo -u` drops the
environment, so the `NODE_ENV` exported by `variables.sh` never reached
those subshells — an accident of sudo, not a decision, which would stop
protecting us the day anyone adds `-E`.

---

## <a id="syntax-check"></a>JavaScript syntax check

A service with a `build` script gets its errors from the compiler.
`deploy-service` is plain JavaScript with no build step, so nothing caught
a parse error until pm2 restarted into it and crash-looped — with the
service already down by the time anyone saw it.

Both scripts now run `node --check` over every `.js` file outside
`node_modules` BEFORE restarting anything. Under `set -e` a failure aborts
the deploy with the service still running on its previous, working code.

**2026-09-22.** `scale-to-zero-registry.js` shipped with `\\\`` inside a
template literal — a literal backslash followed by a backtick that
terminates the literal, so the file would not parse at all. Caught by a
manual `node --check` before deploying, which is the only reason it did not
reach prod. The same class of mistake took deploy-service down once before,
via a backtick inside an HCL comment in a generated job spec. Relying on
someone remembering to run the check by hand is not a control.

---

## <a id="prisma"></a>Prisma migrations

Applied for whichever service actually uses Prisma, detected generically
(a `prisma/schema.prisma` file) rather than hardcoded to api-service —
same "no built-in knowledge of either repo" philosophy as the build-script
check.

`migrate deploy`, not `migrate dev`: it only applies already-committed
migrations and never prompts or generates. **Must run before pm2 starts
anything** — a service whose schema is newer than its database fails
confusingly at the first request that touches the gap, rather than at a
clear startup step. `DATABASE_URL` is already in that service's `.env`,
which Prisma's CLI reads the same way the app does.

---

## <a id="firewall"></a>Firewall

22, 80 and 443 are public. Neither service's own port is opened: both bind
`127.0.0.1` and are reachable only through Traefik on 443.

**SSH must be allowed before `ufw --force enable` runs.** Confirmed the
hard way — an earlier version enabled ufw without explicitly allowing 22,
which immediately cut off all new inbound SSH. Already-established
sessions survive, which is why the script kept running, but reconnecting
afterwards was impossible without console access. **Do not reorder those
lines.**

On OpenStack-based clouds, ufw only controls the firewall *inside* the VM.
The provider's security group must also allow 80/443 in **both** ingress
and egress.

---

## <a id="pm2"></a>pm2

An ecosystem file at `$APP_HOME/ecosystem.config.js`, not ad-hoc
`pm2 start npm --name ...` calls — a discoverable, re-runnable definition.

Per-environment secrets and URLs are **not** duplicated there; they are
already baked into each service's `.env`, which each service loads itself.
Only `BUILDKIT_HOST` goes in `env`, since it is not an app secret, just
something deploy-service's child `railpack`/buildkit invocations expect to
inherit.

The activator runs from the deploy-service checkout but as its **own**
process: it sits in the path of real visitor traffic and holds connections
open for the length of a cold start, which must never be able to take
deploy-service's API down with it. `script: 'activator.js'`, not
`npm start` — that would run deploy-service itself.

---

## <a id="idle-watcher"></a>Scale-to-zero idle watcher timer

Step 5 of `docs/scale-to-zero-gated-plan.md`: idle detection has to run on
a schedule. A systemd timer rather than cron because the output lands in
the journal where it can be read afterwards, and a run missed while the
box was down happens at boot rather than being silently skipped.

Runs as `APP_USER`, **never root**. `idle-report.js` opens the analytics
database read-write (it sets WAL mode), so a root run leaves root-owned
`-wal`/`-shm` files beside a ubuntu-owned database and breaks the running
service's ability to write.

**Safety**: the timer can only ever stop an app named in
`SCALE_TO_ZERO_APPS`, a frozen list in `deploy-service/scale-to-zero-apps.js`.
Scheduling it does not widen what it may touch — every other idle app is
reported and left running.

### <a id="timer-directives"></a>`OnActiveSec`, not `OnBootSec`

`OnBootSec` is measured from **boot**, so on a box that booted days ago
its deadline is permanently in the past and yields no future trigger. A
freshly installed timer then has nothing to anchor `OnUnitActiveSec` to
either, and ends up with no next elapse at all — `systemctl list-timers`
shows `n/a` and it silently never fires. Hit exactly that on 2026-09-18.

`OnActiveSec` is relative to when the **timer** starts, so installing it
always produces a first run, now or at boot.

For a long-running `Type=oneshot` (the soak's curl can last 150s), use
`OnUnitInactiveSec` rather than `OnUnitActiveSec` — measuring from when
the last run *finished* both computes reliably and gives the interval its
intended meaning.

### <a id="idle-threshold"></a>`IDLE_THRESHOLD_MIN` = 360

Six hours, a conservative **starting point** for Step 6, not a tuned
value.

Originally chosen because stopping used to be genuinely harmful: for a few
seconds afterwards a request got a hard 502, so what mattered was how
*often* an app stopped. Six hours pushed almost every stop past working
hours, where nobody was around to hit that window.

That window is now closed ([always-front routing](#s2z-routers)), so a
stop costs nothing but a ~5s cold start on the next request. The case for
a long threshold is weaker than it was and should be revisited with real
Step 6 data rather than left at six hours by inertia. Kept conservative
for now because Step 6 is the first time real users are behind it.

The Step 5 soak overrides this to 15 minutes via a systemd drop-in
installed by `scale-to-zero-soak.sh`, to force many cycles per day. Its
`--remove` restores the production value without re-provisioning.

---

## <a id="docker-gc"></a>Docker GC timer

An image that declares `VOLUME` in its Dockerfile gets a fresh
**anonymous** volume every time a container is created from it. Nothing
reuses the old one: a redeploy, a reschedule, or a scale-to-zero
stop-and-wake all produce a new container and orphan the previous volume.
Nomad's docker driver collects containers but not these.

Left alone this is unbounded and quiet. On 2026-09-21 it reached
**74.66GB across 25 orphaned volumes** — one of them 40.3GB — and took the
disk to 91% of 124GB. The box was days from every app failing at once and
nothing in any log said so; `df` was the only symptom.

**Scale-to-zero makes this worse, not better**: every sleep/wake cycle is
another container, hence another orphan. Which is why it belongs on a
timer rather than in a runbook.

**Why it is safe**: app data is not in Docker volumes. Every app's `/data`
is a **bind mount** of `$APP_DATA_ROOT/<app>`, and bind mounts never
appear in `docker volume ls`. `prune -f` removes only volumes no container
references, leaving `buildkit-cache` alone (it has a live link). Anonymous
volumes never survived their container being replaced anyway, so nothing
could have relied on one to persist.

Images are **dangling-only** — untagged, so no saved job spec can name one
and no scale-to-zero app can need it to wake. Tagged images are untouched
here; per-app retention is `prune-app-images.sh`, deliberately manual
because getting it wrong leaves an app that cannot start and cannot be
rebuilt without its source.
