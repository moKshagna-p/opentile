# Working on OpenTile

OpenTile is a native macOS window and workspace utility. Keep it responsive,
lightweight, and predictable. Prefer a small, well-tested change that fits the
existing code over a new abstraction or dependency.

## How we work

- Treat a request to implement or fix something as authorization to carry it
  through relevant verification. Resolve routine choices yourself. Ask only
  when missing information would materially change the result, or an action
  needs authorization beyond the request.
- Start with the intended outcome and a few concrete acceptance criteria.
  Inspect the relevant code and callers before editing. For bugs, establish
  the cause with evidence before choosing the smallest effective fix.
- Keep one coherent outcome per task. Preserve unrelated work and avoid
  opportunistic refactors. Follow existing conventions and reuse native APIs
  and existing helpers before adding dependencies.
- Continue through implementation and verification; do not stop at a plan
  when the user requested action. Treat follow-up messages as steering the
  current task unless the user clearly changes direction.
- Give concise updates about findings, decisions, and blockers. Finish with
  what changed, the verification performed, and any remaining limits. Never
  claim a check passed without observing its result.

## Where things belong

| Path | Responsibility |
| --- | --- |
| `Sources/OpenTile/` | App lifecycle, native UI, permissions, updates, workspace integration |
| `Sources/OpenTileCore/` | Gesture recognition and reusable domain logic |
| `Sources/OpenTileC/` | Native trackpad bridge |
| `Tests/` | Swift Testing unit and integration coverage |
| `Vendor/AeroSpace/` | Embedded tiling engine; keep local changes focused and explain why |
| `scripts/` | Shared local and CI tooling |
| `.github/` | CI and repository maintenance |

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development and manual checks, and
[RELEASING.md](RELEASING.md) before touching signing, packaging, or releases.
Update [README.md](README.md) when changing documented user behavior or setup.
Keep workflow rules here; avoid duplicating detailed guides.

## Runtime guardrails

- Keep AppKit and UI work on the main thread. Protect state shared with native
  callbacks, bound input queues, and cancel safely when input is lost.
- Treat pause, resume, cancellation, and shutdown as first-class behavior.
  Avoid duplicate observers or timers and stale callbacks after stopping.
- Do not keep gesture polling alive when there is no work. Preserve the ticks
  needed for active drawing, timeouts, and cancellation. Workspace controls
  must remain usable while gesture handling is paused.
- Respect macOS permission state. Avoid unnecessary prompts, handle denial
  and revocation, and do not promise that code can preserve permission grants
  across changes in signing identity.
- Support performance claims with measurements. Passing tests or removing a
  timer does not establish battery savings; distinguish idle, paused, and
  sustained gesture usage when measuring.

## Verification

Run commands from the repository root. Tests use **Swift Testing**, not XCTest;
the supported Command Line Tools setup does not require full Xcode.

```sh
scripts/test.sh                                  # automated tests
scripts/test.sh --filter <testName>               # focused test
swift build -c release                          # release compilation
OPENTILE_SIGNING_IDENTITY="-" scripts/package.sh  # local ad hoc package
```

- Start with the smallest meaningful check. Behavioral changes need coverage
  for the changed behavior and relevant failure paths; prefer deterministic
  core tests and focused lifecycle tests. Broaden checks for integration risk.
- Documentation changes need diff and link checks; script and workflow edits
  need applicable syntax or configuration checks. Avoid unrelated test runs.
- CI cannot prove physical trackpad behavior, privacy dialogs, update
  permissions, or battery impact. Report what remains manual. Use the same
  build and machine for performance comparisons; see
  `scripts/measure-performance.py` for process sampling.
- Packaging does not authorize replacing the installed app or publishing a
  release. Never describe an ad hoc or development-signed build as notarized.

## Git and collaboration

- Inspect Git status before editing or staging. Never discard unrelated edits,
  rewrite shared history, or stage secrets, signing material, or build outputs.
- Create branches, worktrees, commits, pushes, pull requests, tags, and releases
  only when explicitly authorized. Once authorized, proceed without asking
  again. A push request alone does not authorize a release.
- When a branch is requested, use `<type>/<short-description>` with `fix`,
  `feat`, `ui`, `docs`, `refactor`, `test`, or `chore`. Split authorized commits
  by coherent outcome, with clear messages and relevant verification.
- Work directly by default. Use subagents only when requested or explicitly
  authorized, for bounded independent tasks with clear file ownership. Keep
  integration and final verification with the lead; avoid overlapping edits.
- Skills support the task; they do not add approval gates or authorize extra
  work. Do not create plans or process documents unless requested. Keep private
  agent notes under `.codex/`, exclude `/.codex/` in `.git/info/exclude`, and
  never commit them.
