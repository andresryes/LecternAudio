# Earmark

A native macOS (SwiftUI) audiobook manager for your own Audible library, built to replace OpenAudible.

Status: v0.1 opens an existing OpenAudible library folder (`books.json`) and shows it in a sidebar + table/cover grid + inspector UI with a built-in player (chapters, speed, Now Playing). Audible sign-in, sync, download and decrypt are tracked as issues.

```sh
brew install xcodegen
xcodegen generate && open Earmark.xcodeproj
```

Development is agent-driven: see `CLAUDE.md`.
