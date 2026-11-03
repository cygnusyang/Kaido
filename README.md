# Kaido Plan

A project planning workbench for people and AI. Claude Code and Codex do the work; Kaido keeps the WBS, dependencies, schedule and progress in one plan both sides can inspect.

**[Download for macOS](https://github.com/cygnusyang/Kaido/releases/latest)** · **[Website](https://cygnusyang.github.io/Kaido/)** · **[中文](https://cygnusyang.github.io/Kaido/zh.html)** · **[Privacy](https://cygnusyang.github.io/Kaido/privacy.html)**

macOS 14 (Sonoma) or later · universal binary (Apple silicon and Intel) · plans are local `.kaido` files

## Install

**Homebrew** — one command, keeps the app updated:

```
brew install --cask cygnusyang/kaidoplan/kaido
```

**Or download** `Kaido-vX.Y.Z.dmg` from the [latest release](https://github.com/cygnusyang/Kaido/releases/latest) and drag it to Applications.

## CLI and MCP server

The same release ships `kaido` (CLI) and `kaido-mcp` (MCP server) as universal binaries, so AI agents can read and write plans:

```
brew install cygnusyang/kaidoplan/kaido-cli
```

Without Homebrew, take `kaido-vX.Y.Z-macos-universal.tar.gz` from the release, unpack it and put `bin/kaido` and `bin/kaido-mcp` on your `PATH`.

## Pricing

The app is free. **Kaido Pro** adds the delivery report export — turning the plan into a document you can hand to a client. Previewing the report is always free.

On the App Store, Kaido Pro is a subscription at **$9.99 per year**, cancel anytime. Direct-download builds of the app are activated with a license file.

## Support

Bugs and questions: [open an issue](https://github.com/cygnusyang/Kaido/issues) or write to ruohuyang@163.com.

## License

Kaido is **proprietary software**. Copyright © 2026 Ruohu Yang. All rights reserved.

This repository distributes the compiled application and its release notes; it does not contain the source code. Use of the app is governed by the terms accepted at download or purchase; builds distributed through the App Store are additionally licensed under Apple's Standard End User License Agreement. No right to copy, modify, redistribute or reverse-engineer the software is granted beyond what those terms allow.
