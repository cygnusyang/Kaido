## What changed

<!-- One or two sentences. Link the issue: Refs #123 / Closes #123 -->

## How it was tested

<!-- Commands you ran; platform(s). CI covers macOS and Linux. -->

- [ ] `swift test` passes locally
- [ ] `bash tools/gate-core.sh` and `bash tools/gate-ui.sh` pass
- [ ] New behaviour has a test (or a note explaining why not)

## Boundaries

- [ ] No new write path outside `KaidoSession`
- [ ] No platform-bound imports in `KaidoCore` / `KaidoCommands` / `KaidoPresentation`
- [ ] `.kaido` format change includes a migration step and a version bump
- [ ] Docs updated if behaviour or commands changed
