# Contributing to Kaido

Thanks for taking a look. Kaido is a macOS workbench plus an MCP server and CLI for
scheduling AI coding work. The fastest way to get oriented:

- [README.md](README.md) — what it does, four entry points
- [QUICKSTART.md](QUICKSTART.md) — five minutes from clone to first schedule
- [ARCHITECTURE.md](ARCHITECTURE.md) — module boundaries and the contracts that must hold

## Requirements

- macOS 14+ and Xcode 16+ (Swift Testing needs it)
- Swift 5.9+ toolchain via the Xcode command line tools
- Linux contributors: the core, commands and presentation layers build and test on
  Linux; the app and GUI tests are macOS-only

## Build and test

```bash
swift build                 # debug
swift test                  # full suite
bash tools/gate-core.sh     # KaidoCore / KaidoCommands / KaidoPresentation must not import AppKit, SwiftUI, Cocoa or Combine
bash tools/gate-ui.sh       # views must not reference Project / TaskItem / KaidoSession directly
bash tools/build.sh         # release build, packages dist/Kaido.app
```

CI runs `swift test` plus both gates on macOS **and** on Linux (`swift:6.0-jammy`).
A pull request that fails either job will not be merged.

## Boundaries that cannot be crossed

These are architecture decisions, not style preferences:

1. **One write path.** Every mutation goes through `KaidoSession` in `KaidoCommands`.
   Do not add a second way to write a `.kaido` file.
2. **The core stays UI-free.** `KaidoCore`, `KaidoCommands` and `KaidoPresentation`
   are Foundation-only. No AppKit, SwiftUI, Cocoa or Combine imports; the gate scripts
   enforce it.
3. **Views read snapshots, not models.** Views in `Apps/macos/Sources/Workspace` talk to
   the presentation layer through snapshots and actions.
4. **The file format is versioned.** Any change to `.kaido` needs a migration step in
   `FormatDocument`; never rewrite a document without bumping `formatVersion`.

If a change seems to need breaking one of these, open an issue first — that is a design
conversation, not a patch.

## Pull requests

1. Fork, branch from `main`, keep the branch short-lived.
2. Write the test first: a failing case, then the change that makes it pass.
3. Run `swift test` and both gates locally before pushing.
4. Open the PR with the template; fill in what you tested and on which platform.
5. Expect review on behaviour and boundaries, not on formatting.

Commit messages follow `<type>(<scope>): <summary>` (`feat`, `fix`, `docs`, `test`,
`refactor`, `chore`). One commit should map to one change; if the work is tracked as a
work item, put its ID in the subject.

## Reporting bugs

Use the issue template. A useful bug report has: what you ran, what you expected, what
happened, the version (`Kaido → About` or `git describe --tags`), your macOS version and
the relevant log lines. If the app itself misbehaves, mention whether you installed it
from the DMG, via Homebrew, or built it locally.

## Translations

`README.zh-CN.md` is the Chinese README; the diagrams under `docs/` are generated in both
languages by `tools/gen-arch-svg.py` (`KAIDO_SVG_LANG=en|zh`). If you change a diagram,
change the generator, not the SVG.

The AI collaboration guide is bilingual the same way: `Plugins/README.md` (English) and
`Plugins/README.zh-CN.md` (Chinese). They are section-for-section translations — a change to
one lands in both, and sample command output must be re-run, never paraphrased.

## Releasing

\`tools/release.sh <version>\` validates, bumps the version, runs the full suite, packages,
commits, tags and pushes; the tag triggers \`.github/workflows/release.yml\`, which tests again,
repackages, signs the update manifest, archives artifacts and creates the Release.

Every Release ships:

| Asset | For |
|---|---|
| `Kaido-vX.Y.Z.dmg` | installing the app by hand |
| `Kaido-vX.Y.Z.zip` | the over-the-air updater payload |
| `kaido-vX.Y.Z-macos-universal.tar.gz` | `kaido` and `kaido-mcp` binaries, arm64 + x86_64 in one file |
| `…tar.gz.sha256` | checksum for the CLI tarball |
| `update-manifest.json` | signed OTA feed |
| `SIGNING.txt` | what signing/notarization actually happened for this build (never inferred) |

### Signing and notarization

Signing is **optional and off by default**: the workflow checks whether the certificate
secret exists and skips the whole signing chain when it does not, so an unsigned release
still succeeds — and says so: the Release notes get an "unsigned, not notarized" banner and
`SIGNING.txt` is attached to the Release and archived under `artifacts/<tag>/`.
Partial credentials are a hard failure (a signed-but-unnotarized build is still blocked by
Gatekeeper, so "half signed" must never ship silently).

Full operator guide, including how to verify the chain on a machine that has the
certificate: [docs/release.md](docs/release.md).

To turn signing on, add these repository secrets:

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | base64 of a Developer ID Application certificate + private key exported from Keychain as .p12 |
| `MACOS_CERT_PASSWORD` | the password used for that .p12 |
| `NOTARY_APPLE_ID` | Apple ID used for notarization |
| `NOTARY_PASSWORD` | an app-specific password for that Apple ID |
| `NOTARY_TEAM_ID` | the 10-character team identifier |

Generate the base64 blob without leaking the file:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

When the secrets are present the workflow imports the certificate into a temporary keychain,
signs `Kaido.app` with the hardened runtime, notarizes and staples **the app itself**
(the OTA zip cannot be stapled, so the ticket has to be inside the bundle before packaging),
then signs, notarizes and staples the DMG, and finally signs the CLI/MCP binaries in the
universal tarball. Unsigned builds keep working meanwhile — that is why this is a switch
rather than a hard requirement for 0.x.

Whether a release ends up signed and notarized depends on whether the Developer ID secrets are
available to CI, so it changes over time. Do not describe a release as signed or notarized unless
its `SIGNING.txt` says so.
