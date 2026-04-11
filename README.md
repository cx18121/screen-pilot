# ScreenPilot

A tiny screen-aware assistant for macOS. Press **⌘⇧Space**, type a question about what's on your screen, and Claude answers.

## The loop

1. Press **⌘⇧Space** anywhere.
2. ScreenPilot snapshots the full screen.
3. A minimal floating input appears. Type your question, hit return.
4. The screenshot + question goes to Claude (`claude-sonnet-4-6`).
5. The answer appears in a floating panel you can dismiss with the ✕.

Press **⌘⇧Space** again to dismiss any open overlay without asking anything.

## Requirements

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`)
- An Anthropic API key

## Setup

1. **Add your API key.** Either export it:
   ```bash
   export ANTHROPIC_API_KEY="sk-ant-..."
   ```
   or edit `Sources/ScreenPilot/API/Config.swift` and replace the `YOUR_ANTHROPIC_API_KEY_HERE` placeholder.

2. **Build the app bundle.**
   ```bash
   ./build-app.sh
   ```
   This produces `.build/ScreenPilot.app`.

3. **Run it.**
   ```bash
   open .build/ScreenPilot.app
   ```

## First-run permissions

The first time you launch, macOS will ask for two permissions:

- **Accessibility** — required so ScreenPilot can listen for the global ⌘⇧Space hotkey via `CGEventTap`.
- **Screen Recording** — required so ScreenPilot can grab a full-screen snapshot via `CGWindowListCreateImage`.

ScreenPilot will show a prompt with a button that jumps straight to the relevant System Settings pane. **After enabling each permission you must quit and relaunch** (macOS doesn't reload these live for running processes).

If the hotkey doesn't fire, the Accessibility permission is almost always the cause.

## Project layout

```
Sources/ScreenPilot/
├── main.swift                       NSApplication bootstrap
├── AppDelegate.swift                permissions + wiring
├── AssistantCoordinator.swift       core loop orchestrator
├── System/
│   ├── HotkeyManager.swift          CGEventTap for ⌘⇧Space
│   ├── ScreenshotCapture.swift      CGWindowListCreateImage → PNG
│   └── PermissionsManager.swift     Accessibility + Screen Recording
├── API/
│   ├── Config.swift                 model + API key + system prompt
│   ├── ChatMessage.swift            message/content types + RequestContext
│   └── ClaudeClient.swift           Anthropic messages API client
└── Overlay/
    ├── OverlayPanel.swift           frameless always-on-top NSPanel
    ├── InputOverlayController.swift panel lifecycle for input
    ├── InputView.swift              SwiftUI text field
    ├── ResponseOverlayController.swift
    └── ResponseView.swift           SwiftUI response panel
```

AppKit runs the plumbing (windows, event taps, permissions). SwiftUI renders the two overlays. That split keeps each concern in whichever framework is best at it.

## Built for expansion, not built yet

The shape of v1 is deliberate. These are wired in but not implemented:

- **Voice input.** Input enters through `InputOverlayController`. A `VoiceOverlayController` would satisfy the same contract (`onSubmit(String)`). The coordinator doesn't care which one fed it text.
- **Conversation memory.** `ClaudeClient.ask` already takes a `history: [ChatMessage]` array. V1 passes `[]` each call; wiring persistent session history is a field on `AssistantCoordinator`.
- **Active app / window context.** `ClaudeClient.ask` accepts a `RequestContext?` struct. Populating it (via `NSWorkspace.shared.frontmostApplication`, AX APIs, etc.) and passing it through is an additive change.
- **Pointing / highlighting.** `OverlayPanel` is the shared base for any floating layer. A `HighlightOverlayController` can sit alongside the input/response ones and draw boxes/arrows on screen coordinates Claude returns.
- **Automation / click actions.** These go in a new module (`Automation/`) and are triggered by the coordinator, not the client. The API layer stays pure.

Nothing in v1 blocks any of these — the boundaries are already there.

## Known limits (v1)

- `CGWindowListCreateImage` is the API specified; on macOS 14+ Apple prefers ScreenCaptureKit. It still works, but that's the long-term replacement.
- No hotkey customization.
- No retry / rate-limit handling beyond surfacing the error text.
- Each trigger is an independent conversation — no memory across presses.
