# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private reporting: **Security → Advisories → Report a vulnerability** on this
repository. That opens a private thread with the maintainer.

Include the version, the platform, and a reproduction. If the issue involves a `.kairo`
file you cannot share, a description of its structure is enough.

## Scope

Kairo reads and writes local `.kairo` files, runs an MCP server over stdio, and ships a
CLI. Relevant classes of issue:

- Path handling in `.kairo` loading, and in the installer / updater
- Parsing of untrusted JSON (migration and import paths)
- Command injection through MCP/CLI arguments or hook scripts
- Anything that lets a project file execute code

## Current distribution caveats

- Release builds of the macOS app are **ad-hoc signed and not notarized** at the moment.
  macOS refuses the first launch until you allow it in System Settings. Do not read the
  absence of a Gatekeeper warning on your own machine as proof of provenance — verify the
  SHA-256 published with each release.
- The CLI / MCP tarball is not notarized either. Verify the `.sha256` file next to it.
- The app's over-the-air updater checks a signed manifest; a release without a valid
  signature will not be installed automatically.

## Supported versions

Only the latest release receives fixes. This project is pre-1.0: the `.kairo` format is
versioned and migrations are provided, but the Swift API may change between minor versions.
