# dependency-pinning

## Purpose

Governs what the build resolves its inputs against: which library versions a build gets, and which
compiler compiles it. This is one capability rather than two because both halves answer a single
test — can this build be reproduced on a fresh machine in six months? — and because the two halves
answer it in opposite directions. Libraries are pinned to immutable revisions; the Nim compiler is
deliberately left unpinned and bounded instead. Applying either half's rule to the other's subject
reintroduces a failure the policy exists to prevent, so the asymmetry is the substance of this
capability. How the build runs — stage order, quality flags, the nimble exit-code trap — belongs to
`build-pipeline`.

## Requirements

### Requirement: Every dependency decision SHALL satisfy the fresh-machine reproducibility test

A dependency arrangement SHALL be admissible only if a checkout of the repository on a machine
holding none of its build state resolves to the same library revisions the repository was developed
against. This is the criterion the remaining requirements implement; it is stated as a requirement so
that a case not covered by the specific rules below has a test to be judged against.

This requirement is `review-enforced`. No command in the repository evaluates it. Its instruments are
the committed lockfiles (`nimble.lock`, `web-ui/bun.lock`) and the frozen install in `justfile:31`,
each of which is separately enforced by the requirements that follow.

#### Scenario: A dependency arrangement is judged against the test

- **WHEN** a dependency is added, removed, or updated in `particle_garden.nimble` or
  `web-ui/package.json`
- **THEN** the reviewer SHALL determine whether a checkout carrying no prior build state resolves to
  the same revisions, and SHALL reject the change when it does not

#### Scenario: The lockfiles record the resolved revisions

- **WHEN** `nimble.lock` and `web-ui/bun.lock` are read
- **THEN** each SHALL name a concrete resolved revision for every library the build consumes, not a
  range to be re-resolved at install time

### Requirement: Nim library dependencies SHALL be pinned to immutable revisions

Every `requires` line in `particle_garden.nimble` naming a library SHALL identify an immutable
revision — a commit hash or an exact version — never a moving reference. `particle_garden.nimble:14`
carries the sole library dependency as `requires "webui#552a3e3"`, a commit hash rather than the
`2.4.2` tag it corresponds to, because a tag is a mutable pointer and a commit hash is not.

`nimble.lock` SHALL record, for each such library, the resolved commit and a content checksum. The
committed lock records `vcsRevision` `552a3e3fde6e3930bd8178affb42c4a5a0cec813` and a `sha1` checksum
for `webui` (`nimble.lock:4-13`). The checksum is the enforcement point: nimble verifies downloaded
content against it, so a revision that resolves to different bytes fails the install rather than
building. The requirement that the manifest itself name a hash rather than a tag is
`review-enforced` — nothing rejects a manifest that names a tag.

A moving reference is one whose resolution can change without the repository changing: `#head`, a
branch name such as `head`, `main`, `master`, or `latest`, a comparison operator such as `>=`, or the
wildcard `*`. Naming an upstream default branch resolves to whatever that branch holds at install
time, which makes the same checkout build differently on two machines and makes an already-published
release build differently from how it was built.

#### Scenario: A library dependency is declared

- **WHEN** a `requires` line in `particle_garden.nimble` names a library
- **THEN** it SHALL name a commit hash or an exact version, and SHALL NOT name a branch, `#head`, a
  comparison operator, or a wildcard

#### Scenario: A locked library resolves to unexpected content

- **WHEN** `nimble install` fetches a locked library whose content does not match the recorded
  checksum
- **THEN** the install SHALL fail rather than proceed with the mismatched content

### Requirement: The Nim compiler SHALL NOT be pinned in the lock, and SHALL be bounded by a version range

The Nim compiler is the deliberate exception to exact pinning. `nimble.lock` SHALL contain no entry
for `nim`; the committed lock's `packages` object holds `webui` alone (`nimble.lock:3-14`). Builds
SHALL use the toolchain installed on the machine, and `.github/workflows/release.yml:50` installs
dependencies with `--useSystemNim` so that nimble resolves libraries without substituting a compiler.

The bound that makes this safe SHALL be declared in the manifest.
`particle_garden.nimble:11` declares `requires "nim >= 2.0.0 & < 3.0.0"`. This is the enforcement
point for the exception: nimble evaluates the range against the installed toolchain, so a compiler
outside it fails resolution rather than producing a build. The lower bound admits only toolchains
whose language features the source uses; the upper bound is the guardrail that keeps "track the
installed stable toolchain" safe across a future Nim major release, whose incompatible changes would
otherwise be adopted silently.

Pinning the compiler in the lock is prohibited because a pinned Nim ages asymmetrically across its
two backends. A Nim release can compile `src/main.nim` natively while its JS backend cannot compile
`src/app.nim`, emitting `system module needs: nimAddStrStr`. The native test suite stays green under
that condition, so a stale compiler pin breaks the frontend build while every native signal reports
success. Release builds are insulated from this because
`.github/workflows/release.yml:35-37` installs Nim through `iffy/install-nim` at `version:
binary:stable`, ignoring the lock entirely — a divergence between local and CI compiler selection
that a lock entry would convert into a shared failure.

#### Scenario: The lock is inspected for a compiler entry

- **WHEN** `nimble.lock` is read
- **THEN** its `packages` object SHALL contain no `nim` key

#### Scenario: An out-of-range toolchain is installed

- **WHEN** a build runs against an installed Nim outside `>= 2.0.0 & < 3.0.0`
- **THEN** nimble SHALL fail dependency resolution against the `requires` line rather than compiling

#### Scenario: A release build selects its compiler

- **WHEN** the release workflow builds on any matrix platform
- **THEN** it SHALL install Nim at `binary:stable` and SHALL NOT consult `nimble.lock` for a compiler
  version

### Requirement: TypeScript dependency resolution SHALL be fixed by a committed lockfile and frozen installs

`web-ui/bun.lock` SHALL be committed and SHALL record a concrete resolved version and integrity hash
for every package in the transitive tree. Every install SHALL run with `--frozen-lockfile`:
`justfile:31` defines `build-ui` as `cd web-ui && bun install --frozen-lockfile && bun run typecheck
&& bun run build.ts`, and this is the only install path — the release workflow reaches it through
`just check` and `just release` (`.github/workflows/release.yml:58,61`) rather than installing
separately.

`--frozen-lockfile` is the enforcement point, and it is a real one: an install whose manifest and
lockfile disagree fails rather than re-resolving and rewriting the lock. This holds identically for
local builds and CI, because both go through the same recipe.

The separate requirement that each entry in `web-ui/package.json` be written as an exact version
rather than a range is `review-enforced`; `--frozen-lockfile` constrains what a range resolves to but
does not reject the range itself. `web-ui/package.json:11-17` pins the five runtime dependencies
exactly (`@babel/core` `8.0.1`, `@babel/preset-typescript` `8.0.1`, `@dschz/bun-plugin-solid`
`1.0.4`, `babel-preset-solid` `1.9.12`, `solid-js` `1.9.14`), and `@types/bun` at `1.3.14`. No entry
carries a caret or a tilde.

One entry departs from exactness: `web-ui/package.json:20` declares `"typescript": "7"`, a bare
major-version range rather than an exact version. Reproducibility survives it, because
`web-ui/bun.lock:189` resolves that range to `typescript@7.0.2` with an integrity hash and
`--frozen-lockfile` forbids re-resolution — the range is inert as long as the lockfile is the
authority. The exposure is that the manifest alone does not determine the compiler version used for
the `tsc --noEmit` typecheck, so a lockfile regenerated without a corresponding manifest change would
be free to adopt any 7.x release.

#### Scenario: A manifest edit is not reflected in the lockfile

- **WHEN** `build-ui` runs after `web-ui/package.json` is changed without `web-ui/bun.lock` being
  regenerated
- **THEN** `bun install --frozen-lockfile` SHALL fail the build rather than re-resolving and
  rewriting the lockfile

#### Scenario: A dependency version range is declared

- **WHEN** an entry is added to `dependencies` or `devDependencies` in `web-ui/package.json`
- **THEN** the reviewer SHALL require an exact version, and SHALL reject a caret, tilde, wildcard, or
  bare major-version range

### Requirement: Both lockfiles SHALL be tracked in version control

`nimble.lock` and `web-ui/bun.lock` SHALL be committed, and `.gitignore` SHALL NOT match either path.
`.gitignore` ignores build artifacts — `web/app.js`, `web/ui-bundle.js`, `web/ui-bundle.css`, the
generated `web/shaders/*.wgsl`, `web-ui/node_modules/`, `nimble.paths`, `nimbledeps` — and matches no
lockfile. Both files are tracked.

The distinction is that a lockfile is an input to the build and an artifact is an output. An
uncommitted or absent lockfile means each machine re-resolves independently, which defeats every
other requirement in this spec regardless of how exactly the manifests are written.

#### Scenario: A fresh clone is inspected

- **WHEN** the repository is cloned with no build having been run
- **THEN** both `nimble.lock` and `web-ui/bun.lock` SHALL be present in the working tree

#### Scenario: A generated bundle is inspected

- **WHEN** `.gitignore` is read
- **THEN** it SHALL match the generated bundles under `web/` and `web-ui/node_modules/`, and SHALL
  NOT match `nimble.lock` or `web-ui/bun.lock`

### Requirement: Lockfile updates SHALL be deliberate rather than incidental

A change to `nimble.lock` or `web-ui/bun.lock` SHALL accompany a corresponding manifest change and
SHALL be reviewable on its own terms. No build step regenerates either lock as a side effect: the
justfile's only install invocation passes `--frozen-lockfile` (`justfile:31`), which fails rather
than rewrites, and no recipe runs `nimble lock`.

This requirement is `review-enforced` for the Nim side. Nothing prevents a `nimble lock` run outside
the build from rewriting `nimble.lock`; the guarantee is that the build itself never does it.

#### Scenario: A pull request changes a lockfile

- **WHEN** a diff touches `nimble.lock` or `web-ui/bun.lock`
- **THEN** the reviewer SHALL require a corresponding manifest change explaining the new resolution,
  and SHALL reject a lockfile change that appears without one

#### Scenario: A build runs against a clean tree

- **WHEN** `just happen` completes on a tree with no manifest changes
- **THEN** neither lockfile SHALL have been modified

### Requirement: The release build SHALL resolve against the same pinned inputs as a local build

The release workflow SHALL reach its dependency resolution through the same `just` recipes a local
build uses, so that no CI-only install path can resolve differently.
`.github/workflows/release.yml:58,61` runs `just check` and `just release`; the UI install is
therefore the `--frozen-lockfile` invocation in `justfile:31` and not a separate step.

The Nim compiler is the one input that SHALL differ by design, per the compiler exception above: CI
installs `binary:stable` while a local build uses whatever toolchain is installed. Both are
constrained by the same `requires` range in `particle_garden.nimble:11`, so the divergence is bounded
rather than open.

The Bun version SHALL be declared in the repository. `web-ui/package.json:6` declares
`"packageManager": "bun@1.3.14"` and `.github/workflows/release.yml:44` requests the same version
from `oven-sh/setup-bun`. Keeping the two declarations equal is `review-enforced` — no check compares
them, and a divergence would let CI build the UI bundle with a different bundler than a local build.

#### Scenario: The release workflow installs UI dependencies

- **WHEN** the release workflow runs on any matrix platform
- **THEN** it SHALL install `web-ui` dependencies through a `just` recipe using `--frozen-lockfile`,
  and SHALL NOT invoke `bun install` directly

#### Scenario: The Bun version is changed

- **WHEN** the Bun version is updated
- **THEN** both `web-ui/package.json`'s `packageManager` field and the release workflow's
  `bun-version` input SHALL be updated to the same version
