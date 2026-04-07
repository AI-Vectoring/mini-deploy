# Tricycler — Design Document

This document captures every architectural decision, philosophy, and open question
agreed upon during the design of the new tricycler. It is the authoritative reference
for why things are the way they are. It is intentionally over-complete — easier to
remove what is not needed than to recover what was forgotten.

---

## Origin and Context

### What was tried before

The original tricycler used VS Code Dev Containers as its development environment
mechanism. The flow was:

1. Create a new GitHub repo from the tricycler template
2. Open VS Code
3. `Ctrl+Shift+P` → "Dev Containers: Clone Repository in Container Volume"
4. VS Code builds the container and runs `onCreateCommand` (templateInit.sh)
5. Developer is inside the container

After two and a half days of attempting to make this work reliably, it was abandoned.
Dev Containers is a Microsoft-backed project with significant adoption but high
operational complexity. It is heavily VS Code-specific, relies on a JSON configuration
system that must anticipate all possible scenarios in advance, and breaks in ways that
are difficult to diagnose.

### What replaced it

A minimal experiment called **mini-deploy**: a Dockerfile, an entrypoint script, and
a setup script. Three files. It works perfectly. SSH access to a container, key-based
auth, no passwords, no VS Code dependency, no configuration system. Any editor that
supports Remote-SSH works. Any terminal works.

### What this repo is

This repo started as mini-deploy (the proof of concept) and is being evolved into
the new tricycler. When development is complete it will be renamed tricycler.

---

## Core Philosophy

### Configuration as imperative code

Tricycler explicitly rejects declarative configuration systems (JSON, YAML, DSLs) for
defining stacks. Devcontainers uses a JSON schema that must enumerate all possible
options in advance. Every new option requires a project update. Every unusual
requirement is either unsupported or requires workarounds.

Tricycler's answer: the stack is defined with code. Dockerfiles, shell scripts,
Makefiles, Python, Go, whatever the implementer wants. This means:

- There is nothing that cannot be expressed
- No dependency on tricycler to add support for new options
- The implementer owns the implementation completely
- Each stack is independent — changes to one do not affect others

This is especially important for non-standard stacks (C + Lua + Scheme, embedded
systems, unusual language combinations) where no configuration system would ever
have first-class support.

### Nothing on the host

The goal is a developer workstation with only Docker and a one-time setup script.
No language runtimes, no package managers, no build tools, no project dependencies
installed on the host. Everything lives inside the container. When you are done,
delete the container and nothing remains. Clean machine, always.

### Simplicity over completeness

Every design decision favors the simpler path. Mini-deploy proved this: three files
that work perfectly beat two and a half days of fighting a sophisticated system.
If the simpler approach covers the common case, it is the right approach. Edge cases
can be handled in stack-specific code without requiring framework changes.

---

## Architecture: Three Layers

```
┌─────────────────────────────────────────────────────┐
│  Layer 3: Stack Implementations                     │
│  (tricycler-ts, tricycler-py, tricycler-c-lua, ...)  │
│  Owned entirely by the implementer.                 │
│  Not part of this repo.                             │
├─────────────────────────────────────────────────────┤
│  Layer 2: Tricycler (this repo)                     │
│  Lifecycle skeleton: dev / stage / prod             │
│  Annotated TS example shows how to build a stack.   │
│  Defines what is generic vs. stack-specific.        │
├─────────────────────────────────────────────────────┤
│  Layer 1: Container Transport (setup.sh)            │
│  Pull image. Wire SSH. Done.                        │
│  Universal. Works for any tricycler-based image.    │
└─────────────────────────────────────────────────────┘
```

Each layer has a single responsibility. A change in one layer does not require
changes in another.

---

## Layer 1 — Container Transport (setup.sh)

### Responsibility

setup.sh is the universal entry point for everyone who works with tricycler. Its
only job is to get a container running and make it SSH-accessible from the host.

It does not know what is inside the container. It does not build anything. It does
not clone anything. The image name is its only input.

### Current state (setup.sh)

The current `setup.sh` still builds the image from the local Dockerfile. This is
a legacy of mini-deploy's proof-of-concept phase. It will be replaced by `setup2.sh`
once the infrastructure is in place. Until then both files coexist.

### Target state (setup2.sh)

```
setup2.sh [<image-name>]
```

**If an image name is provided:**

1. Resolve and cache the GitHub SSH key (see Key Caching below)
2. `docker pull <image-name>`
3. `docker run` — starts the container, mounts keys, maps SSH port
4. Write SSH config entry so `ssh <project>` works
5. Done

**If no image name is provided:**

1. Query the catalog (see Catalog below)
2. Present a numbered menu of available stacks
3. User picks one → proceed as above

### Key caching

setup.sh/setup2.sh require a GitHub SSH key so the container can push/pull from
GitHub. Finding and validating this key is the most interactive part of the setup.
Key caching eliminates this on all runs after the first.

**Mechanism:**

- Config file: `~/.config/tricycler/config`
- Contains: `GITHUB_KEY=/path/to/key`
- On each run: read the stored path, test it against GitHub with a live SSH call
- If valid: use it immediately, skip all detection logic
- If invalid (key revoked, file moved, etc.): run full detection, write new result

**Detection logic (when cache misses):**

1. Scan `~/.ssh/` for private key files (exclude `.pub`, `known_hosts`, `config`,
   `authorized_keys`, the project key itself, `.pem` files)
2. If one key found: test it automatically
3. If multiple found: present a numbered menu
4. If none found: offer manual path entry or instructions to create a new key
5. Retry up to 3 times on failure
6. On success: write path to `~/.config/tricycler/config`

### What setup.sh does NOT do

- Build Docker images
- Clone repositories
- Install tools on the host
- Manage container lifecycle beyond initial start (stop/remove are `docker` commands)

### SSH keypair

setup.sh generates a project-specific ed25519 keypair at `~/.ssh/tricycler` for
inbound SSH authentication (host → container). This is separate from the GitHub key.
The public key is bind-mounted into the container at startup and installed to
`/home/appuser/.ssh/authorized_keys` by the container's entrypoint.

---

## Layer 2 — Tricycler (This Repo)

### What tricycler is

A lifecycle skeleton. It defines that a project has dev, stage, and prod environments,
how those environments relate to each other, and the minimum common structure shared
by every stack. It contains the tooling to manage those environments (Makefile,
scripts, health checks) and an annotated example that demonstrates how to build a
stack on top of it.

**In one sentence:** Tricycler is the repeatable parts. Everything non-repeatable
belongs in the stack implementation.

### What tricycler is NOT

- Not a configuration system
- Not a schema or DSL for describing stacks
- Not a framework that needs to be extended when new options are needed
- Not trying to represent all possible platforms
- Not VS Code-specific or editor-specific
- Not devcontainers

### The name

"Tricycler" refers to the three core environments: **dev, stage, prod**. Three
containers. Three-cycle.

### The five containers

Tricycler defines five containers. Three are the core concept; two are supporting
infrastructure:

| Container | Role | Core? |
|-----------|------|-------|
| `dev` | Full toolchain, hot reload, SSH server. Where developers work. | Yes |
| `stage` | Same build as prod, debuggable. Pre-production validation. | Yes |
| `prod` | Minimal, hardened, no shell. Production runtime. | Yes |
| `builder-base` | Shared build environment for stage/prod/debug. Avoids rebuilding the toolchain on every build. | No — implementation detail |
| `debug` | Prod build + forensics tools + root access. Post-incident investigation. | No — implementation detail |

The prod container has no shell intentionally — `docker exec` into a running prod
container will fail. Use stage to investigate pre-production issues, debug for
post-incident forensics.

### The embedded example

Tricycler contains an annotated TypeScript/Next.js example. This is intentional and
necessary, not a design flaw.

**Why the example exists:**
- Without it, tricycler is so thin (a Makefile skeleton, a PROJECT.conf, some docs)
  that it is difficult to understand what a stack built on it actually looks like.
- The Dockerfiles — the core artifact of tricycler — are nearly empty without example
  content. An empty Dockerfile with only comments is not useful for someone building
  their first stack.
- The Makefile app-layer targets (install, dev-run, db-migrate, etc.) do not exist
  without a stack. These are the targets a developer runs inside the container daily.
- TS was chosen because it is the most common stack and makes for the simplest
  possible non-trivial example. The goal of tricycler is non-standard stacks
  (C + Lua + Scheme, embedded, unusual combinations) — TS is the baseline everyone
  understands before seeing the unusual case.

**How the example is marked:**

Three comment tags distinguish generic from specific throughout the codebase:

| Tag | Meaning |
|-----|---------|
| `[Tricycler]` | This is the generic pattern. Keep this in your implementation. |
| `[TS-Example]` | This is TypeScript-specific. Replace with your stack's equivalent. |
| `[Think]` | Explanatory note. Reasoning behind a decision — read before changing. |

These tags appear in Dockerfiles, scripts, Makefiles, and documentation. They are
the primary teaching mechanism. A developer building a new stack reads the code,
sees `[TS-Example]`, and knows: "this is what I replace." They see `[Tricycler]` and
know: "this is the pattern, keep it."

**What to do with the example:**

When building a new stack:
- Keep everything tagged `[Tricycler]`
- Replace everything tagged `[TS-Example]` with your stack's equivalent
- Delete `[Think]` comments once you understand them, or keep them as-is
- Add your own stack-specific code where needed

There is no automated stripping tool. Reading the example is part of the process.

### Files that stand on their own (generic)

These files are meaningful without the TS example:

- `PROJECT.conf` — project name, GitHub user, repo URL, branch, volume preference
- `Makefile` (container targets only) — build-base, dev, stage, prod, debug targets
- `templateInit.sh` — rename wizard (detects fresh clone, prompts for project name, find/replaces across repo, commits)
- `docker-compose.yml` — backing services pattern (DB, cache, queue as commented options)
- `workshop/docs/` — lifecycle documentation, publishing flow, debugging approach

### Files that require the example to be meaningful

These files are nearly empty or do not exist without a stack:

- `VERSIONS` — just a comment header without stack-specific version values
- All five Dockerfiles — the skeleton exists but the content (FROM image, installed tools, build commands) is entirely stack-specific
- `check-versions.sh`, `update-versions.sh` — check and bump specific runtime versions
- Makefile app-layer targets (install, dev-run, db-migrate, etc.)

### PROJECT.conf

The central source of truth for project identity. Read by the Makefile and available
as build args in Dockerfiles.

```bash
PROJECT_NAME=tricycler
GITHUB_USER=AI-Vectoring
DOCKERHUB_USER=aivcx
REPO_URL=https://github.com/AI-Vectoring/tricycler.git
REPO_BRANCH=main
LOCAL_VOLUME=false
```

### VERSIONS

Pins runtime versions for reproducible builds. All containers read from this file.
The mechanism is generic; the values are stack-specific.

```bash
# [TS-Example]
NODE_VERSION=22
PNPM_VERSION=9
```

A Python stack would have `PYTHON_VERSION=3.12`. A C stack might have
`GCC_VERSION=13`. The convention is always: one version per tool, all caps,
uppercase snake case.

### templateInit.sh

The first-run rename wizard. Detects a fresh template clone (PROJECT.conf still
contains the template values), prompts for a project name and GitHub user, and
does a repo-wide find/replace across all source files.

**Current state:** Triggered by `onCreateCommand` in `.devcontainer/devcontainer.json`.
This trigger is being removed along with devcontainers.

**Target state:** Called manually by the developer after SSHing into the container
for the first time, or triggered by a first-run detection in `entrypoint.sh`.
The wizard logic itself is unchanged.

**What it does:**
1. Checks if `PROJECT.conf` still matches template values — exits immediately if already initialized
2. Prompts for `PROJECT_NAME` and `GITHUB_USER`
3. Derives `REPO_URL` from those values
4. Updates `PROJECT.conf`
5. Runs `sed` find/replace across all text file types in the repo
6. Asks about `LOCAL_VOLUME` preference
7. Commits and pushes

---

## Layer 3 — Stack Implementations

### What they are

A stack implementation is a fork of tricycler that adds the specific tools,
languages, runtimes, and configuration needed for a particular development
environment. Once forked, the implementer owns it completely. There is no
dependency back on tricycler after the fork — updates to tricycler do not
automatically apply.

### Known implementations

| Repo | Stack | Status |
|------|-------|--------|
| tricycler-ts | TypeScript / Next.js / Prisma / PostgreSQL | Exists, needs rebuild on new paradigm |
| tricycler-py | Python | Planned |
| tricycler-c-lua-scheme | C + Lua + Scheme + full toolchain | Planned — the primary use case |

### Implementer responsibilities

Once a stack is working and stable:
1. Build and publish the Docker image to DockerHub (or any public registry)
2. Add a `tricycler.conf` manifest to the repo root
3. Tag the GitHub repo with the `tricycler` topic

At that point the stack is discoverable via the catalog and launchable with setup.sh.

### End user experience

An end user of `tricycler-ts`:
1. Runs `setup2.sh aivcx/tricycler-ts` (or picks from catalog)
2. SSHes in: `ssh tricycler-ts`
3. The full TS dev environment is ready — Node, pnpm, Postgres, everything
4. They never clone a repo, never install anything on their host, never run a build

---

## The Catalog

### Mechanism

GitHub topic search: all repos tagged with `tricycler` are potential catalog entries.
Tag alone is not enough — a `tricycler.conf` manifest file at the repo root must also
be present. This is the readiness gate.

### tricycler.conf format

```bash
IMAGE=aivcx/tricycler-ts
DESCRIPTION=TypeScript / Next.js / Prisma / PostgreSQL
```

Fields:
- `IMAGE` — the Docker image reference to pull (required)
- `DESCRIPTION` — one-line human description shown in the catalog menu (required)

Additional fields may be added in future (VERSION, MAINTAINER, MIN_DOCKER_VERSION,
etc.) but these two are the minimum.

### Discovery flow in setup2.sh

```
GET https://api.github.com/search/repositories?q=topic:tricycler
  → for each result:
      fetch https://raw.githubusercontent.com/<owner>/<repo>/main/tricycler.conf
      if file exists: add to menu with IMAGE and DESCRIPTION
      if file missing: skip silently
present numbered menu
user picks → docker pull IMAGE → docker run → write SSH config
```

### Readiness gate

A repo tagged `tricycler` but without `tricycler.conf` is invisible to the catalog.
This allows implementers to work in the open without polluting the catalog with
incomplete implementations.

When to add `tricycler.conf`:
- The image is published and tested
- A developer can `setup2.sh <image>` and get a working environment
- The implementation is stable enough to be useful to others

### Rate limiting

GitHub API: 60 requests/hour unauthenticated, 5000/hour authenticated. For a tool
run occasionally, this is not a constraint. No special handling required.

---

## The Two Users

### The implementer

A developer building a new stack on top of tricycler. They work with the repo
directly. They run setup.sh (or setup2.sh) to get a container, SSH in, clone
tricycler or their new repo inside, build the stack, test it, and publish an image.

They never need to install any stack tooling on their host. They do everything
inside the dev container.

### The end user

A developer who wants to use a finished stack. They run `setup2.sh <image>` or
browse the catalog, SSH in, and the environment is ready. They never see the
Dockerfiles or the Makefile. They may not even know about tricycler.

### Both use setup.sh

The implementer and the end user run the same tool. The difference is which image
they pass to it. `setup2.sh tricycler` gives the implementer the skeleton to work
with. `setup2.sh aivcx/tricycler-ts` gives the end user a finished TS environment.

---

## Key Design Decisions

### No devcontainers

Devcontainers is a declarative JSON configuration system. Every new option requires
the project to update its schema. Complex stacks (multiple languages, unusual
tooling) hit the edges of what it can express. Operational complexity is high.
After two and a half days of failures, it was abandoned.

SSH + shell scripts work for every editor, every terminal, every stack. No schema,
no extension dependencies, no VS Code lock-in.

### One repo, not two

An early option was to have a clean tricycler skeleton repo and a separate annotated
example repo. Rejected because:
- The example is structural — the Dockerfiles barely exist without it
- Two repos create maintenance drift (skeleton and example fall out of sync)
- The three comment tags (`[Tricycler]`, `[TS-Example]`, `[Think]`) handle the
  distinction inside one repo without the overhead of two

### Imperative code, not declarative config

Declarative systems require the framework to anticipate all options. Imperative code
requires nothing — you write what you need. Stack implementations are not limited
by what tricycler supports; they are limited only by what Docker and the host OS
can do.

### Pre-built images, no build step for end users

End users pull a published image. They never run `docker build`. This means:
- No local repo required on the host
- No build dependencies on the host
- Consistent environment (everyone gets the same image)
- Implementers control the release cycle by choosing when to publish

### Example lives in tricycler, not a separate repo

The TS implementations (tricycler-ts) are actual implementations used by developers,
not examples in the pedagogical sense. They happen to demonstrate the pattern, but
their primary purpose is to be used. Tricycler's embedded example exists specifically
to teach — it is annotated code, not a deployable stack.

---

## What Is Currently Implemented

### setup.sh (functional, legacy build step)

- Generates project SSH keypair
- GitHub key caching via `~/.config/tricycler/config`
- Full GitHub key detection with retry logic
- Builds Docker image from local Dockerfile (legacy — will be replaced by pull)
- Starts container with key mounts
- Writes SSH config entry

### setup2.sh (draft, not yet functional end-to-end)

- All of the above plus:
- Accepts image name as argument
- Uses `docker pull` instead of `docker build`
- Derives project name from image name
- Catalog section stubbed pending published images and manifests

### entrypoint.sh (functional)

- Installs authorized key from `/tmp/authorized_keys`
- If `/tmp/github_key` exists: installs it and writes `~/.ssh/config` for github.com
- Sets correct permissions for sshd
- Starts sshd in foreground

### Dockerfile (functional)

- Base: debian:13-slim
- Installs: git, openssh-client, openssh-server, ca-certificates
- Creates appuser (UID/GID 1000)
- Sets entrypoint.sh

---

## Open Questions and Next Decisions

### 1. The new day-one flow (BLOCKING)

The devcontainer flow is dead. The replacement is not yet fully designed. What is
known:

- End users: `setup2.sh <image>` → SSH in → work. Fully defined.
- Implementers: need to build a new stack. Current open question is whether they
  clone the tricycler repo on the host, or pull the tricycler base image and work
  entirely inside the container.

The container-only approach (pull base image, do everything inside) is preferred
because it upholds "nothing on the host." It requires Docker socket mounting so
that `make stage` / `make prod` (docker build commands) work from inside the
container.

### 2. templateInit.sh trigger

The rename wizard currently fires via `onCreateCommand` in devcontainer.json.
That trigger goes away with devcontainers.

Options:
- Developer runs it manually after first SSH connect (documented in README)
- entrypoint.sh detects a fresh template clone and prints a prominent message
- entrypoint.sh calls it automatically on first run

The first option is simplest. The second is more discoverable. The third is
potentially surprising. Not yet decided.

### 3. Docker socket mounting

For the container-only implementer workflow, the dev container needs to be able
to run docker commands (to build stage/prod images). This requires either:
- Bind-mounting the host Docker socket: `-v /var/run/docker.sock:/var/run/docker.sock`
- Docker-in-Docker (DinD)

Socket mounting is simpler and widely used for dev environments. DinD is more
isolated but heavier. Socket mounting is the likely answer but not yet decided.

### 4. tricycler base image

For setup2.sh to work for implementers, a tricycler base image must be published.
Its contents are approximately:
- debian:13-slim base
- openssh-server
- git, curl, ca-certificates
- Docker CLI (for socket-mount usage)
- appuser (UID/GID 1000)
- entrypoint.sh

Not yet built or published.

### 5. Catalog implementation in setup2.sh

Stubbed. Unblocked once the first stack image with a tricycler.conf manifest is
published to DockerHub and tagged on GitHub.

---

## Repo Naming

This repo is currently named `mini-deploy`. It will be renamed to `tricycler` when:
- The devcontainer artifacts are removed
- setup2.sh is functional
- The new day-one flow is implemented and documented
- At least the tricycler base image is published

The rename is a GitHub repo rename operation. All existing git remotes will
redirect automatically.
