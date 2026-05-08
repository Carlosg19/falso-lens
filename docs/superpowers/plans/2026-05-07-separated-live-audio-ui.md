# Separated Live Audio UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the live hearing UI so microphone and computer transcripts are visually and operationally separated instead of looking like one combined transcript area.

**Architecture:** Keep capture and transcription logic out of `ContentView`. `ContentView` should render two independent source panels from `liveHearing.computerTranscript` and `liveHearing.microphoneTranscript`, with source-local copy/status/metrics controls. Remove combined transcript affordances from the main UI because they make the sources feel merged.

**Tech Stack:** SwiftUI, macOS app UI, `NavigationSplitView`, `ScrollView`, `VStack`, source-specific `SourceTranscriptState`.

---

## Current Scan Summary

`ContentView` already receives separate state:

- Computer UI uses `liveHearing.computerTranscript`.
- Microphone UI uses `liveHearing.microphoneTranscript`.
- `liveTranscriptLane(_:systemImage:state:)` renders a lane from a single `SourceTranscriptState`.

The UI problem is presentation, not binding:

- The two lanes are rendered inside one shared `HStack`, which can read as one combined transcript region.
- The header has one total chunk count, not per-source summary.
- The toolbar includes `Copy Both`, which reinforces the idea that the two transcripts are one combined transcript.
- The copy buttons live in the shared toolbar instead of inside the source they copy.
- The two transcript lanes use identical styling without stronger source-specific separation.

Important dependency:

- UI changes will make the separation visible and harder to confuse.
- UI changes cannot fix transcript-layer source rewriting. The separate plan `docs/superpowers/plans/2026-05-07-independent-audio-transcript-lanes.md` should also be executed so `LiveMixedAudioTranscriptionPipeline` never moves, suppresses, or reassigns text across sources.

## Files

- Modify: `falsoai-lens/ContentView.swift`
- Verify only: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

No new Swift file is required. `ContentView.swift` already owns this demo UI and has a private `liveTranscriptLane` helper.

---

### Task 1: Confirm The UI Is Bound To Separate State

**Files:**
- Inspect: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Search the live hearing UI bindings**

Run:

```bash
rg -n "liveHearing\\.computerTranscript|liveHearing\\.microphoneTranscript|Copy Both|liveTranscriptLane|Separated Live Audio" falsoai-lens/ContentView.swift
```

Expected before implementation: matches show separate source state is already available, plus a shared `Copy Both` button and `liveTranscriptLane` helper.

- [ ] **Step 2: Record the UI root cause**

Write this in implementation notes:

```text
Root cause: the UI has separate source state, but presents both sources inside one shared transcript area with shared actions. This makes microphone and computer text feel combined even when the bindings are separate.
```

---

### Task 2: Replace Shared Transcript Toolbar With Source-Neutral Capture Controls

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Replace the shared button row**

In `hearingDemoSection`, replace the `HStack` that currently contains Start, Clear, Copy Computer, Copy Mic, and Copy Both:

```swift
HStack {
    Button {
        Task {
            if liveHearing.isRunning {
                await liveHearing.stop()
            } else {
                await liveHearing.start(mode: hearingMode)
            }
        }
    } label: {
        Label(
            liveHearing.isRunning ? "Stop" : "Start Separated Capture",
            systemImage: liveHearing.isRunning ? "stop.circle" : "record.circle"
        )
    }
    .disabled(!liveHearing.isEngineAvailable && !liveHearing.isRunning)

    Button {
        liveHearing.clearTranscript()
    } label: {
        Label("Clear", systemImage: "trash")
    }
    .disabled(!liveHearing.hasTranscriptText && liveHearing.errorMessage == nil)

    Button {
        copyToPasteboard(liveHearing.computerTranscript.text)
    } label: {
        Label("Copy Computer", systemImage: "desktopcomputer")
    }
    .disabled(liveHearing.computerTranscript.isEmpty)

    Button {
        copyToPasteboard(liveHearing.microphoneTranscript.text)
    } label: {
        Label("Copy Mic", systemImage: "mic")
    }
    .disabled(liveHearing.microphoneTranscript.isEmpty)

    Button {
        copyToPasteboard(liveHearing.combinedTranscriptText)
    } label: {
        Label("Copy Both", systemImage: "doc.on.doc")
    }
    .disabled(!liveHearing.hasTranscriptText)
}
```

With a source-neutral control row:

```swift
HStack {
    Button {
        Task {
            if liveHearing.isRunning {
                await liveHearing.stop()
            } else {
                await liveHearing.start(mode: hearingMode)
            }
        }
    } label: {
        Label(
            liveHearing.isRunning ? "Stop Capture" : "Start Capture",
            systemImage: liveHearing.isRunning ? "stop.circle" : "record.circle"
        )
    }
    .disabled(!liveHearing.isEngineAvailable && !liveHearing.isRunning)

    Button {
        liveHearing.clearTranscript()
    } label: {
        Label("Clear Both", systemImage: "trash")
    }
    .disabled(!liveHearing.hasTranscriptText && liveHearing.errorMessage == nil)
}
```

- [ ] **Step 2: Verify combined transcript action is gone from the primary UI**

Run:

```bash
rg -n "Copy Both|combinedTranscriptText" falsoai-lens/ContentView.swift
```

Expected after this task: no `Copy Both` match in `ContentView.swift`. `combinedTranscriptText` may remain in the pipeline for export/future use, but it should not be a primary UI action in this section.

---

### Task 3: Render Source Panels As Separate Full-Width Sections

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Replace the side-by-side lane `HStack`**

Replace:

```swift
HStack(alignment: .top, spacing: 12) {
    liveTranscriptLane(
        "Computer Audio",
        systemImage: "desktopcomputer",
        state: liveHearing.computerTranscript
    )
    liveTranscriptLane(
        "Microphone",
        systemImage: "mic",
        state: liveHearing.microphoneTranscript
    )
}
```

With:

```swift
VStack(alignment: .leading, spacing: 14) {
    liveTranscriptPanel(
        title: "Computer Audio",
        subtitle: "System audio captured from the selected display",
        systemImage: "desktopcomputer",
        state: liveHearing.computerTranscript,
        accent: .blue
    ) {
        copyToPasteboard(liveHearing.computerTranscript.text)
    }

    liveTranscriptPanel(
        title: "Microphone",
        subtitle: "External input captured from the active microphone",
        systemImage: "mic",
        state: liveHearing.microphoneTranscript,
        accent: .green
    ) {
        copyToPasteboard(liveHearing.microphoneTranscript.text)
    }
}
```

This makes each source a full-width section. Full-width stacking is intentional: it prevents the two transcript surfaces from visually merging into one horizontal text area.

---

### Task 4: Replace `liveTranscriptLane` With A Source-Specific Panel

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Delete the old helper signature**

Delete:

```swift
private func liveTranscriptLane(
    _ title: String,
    systemImage: String,
    state: SourceTranscriptState
) -> some View {
    ...
}
```

- [ ] **Step 2: Add the source panel helper**

Add this helper in the same location where `liveTranscriptLane` used to live:

```swift
private func liveTranscriptPanel(
    title: String,
    subtitle: String,
    systemImage: String,
    state: SourceTranscriptState,
    accent: Color,
    copyAction: @escaping () -> Void
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(accent)

            Spacer()

            Button {
                copyAction()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(state.isEmpty)
        }

        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)

        ScrollView {
            Text(state.isEmpty ? "No transcript yet" : state.text)
                .font(.body)
                .foregroundStyle(state.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 150, maxHeight: 260)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))

        HStack(spacing: 12) {
            Label("\(state.chunksTranscribed) chunks", systemImage: "waveform")

            if let elapsed = state.lastInferenceDurationSeconds {
                Label(String(format: "%.2f s", elapsed), systemImage: "timer")
            }

            if let language = state.latestLanguage {
                Label(language, systemImage: "globe")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(12)
    .overlay {
        RoundedRectangle(cornerRadius: 8)
            .stroke(accent.opacity(0.35), lineWidth: 1)
    }
}
```

Notes:

- Copy is source-local, inside the source panel.
- The colored leading rule and border make the panes visually distinct without relying on explanatory text.
- The transcript text remains selectable and scrollable.
- The panel is not nested inside another card-style card; it is a bounded source section within the existing hearing area.

- [ ] **Step 3: Verify no old helper calls remain**

Run:

```bash
rg -n "liveTranscriptLane" falsoai-lens/ContentView.swift
```

Expected after this task: no matches.

---

### Task 5: Make The Section Header Reflect Separate Sources

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Replace the combined chunk summary**

Replace:

```swift
HStack {
    Label("Separated Live Audio", systemImage: "waveform.and.person.filled")
        .font(.headline)
    Spacer()
    if liveHearing.totalChunksTranscribed > 0 {
        Text("\(liveHearing.totalChunksTranscribed) chunks")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

With:

```swift
HStack {
    Label("Separated Live Audio", systemImage: "waveform.and.person.filled")
        .font(.headline)
    Spacer()
    if liveHearing.hasTranscriptText {
        Text("Computer \(liveHearing.computerTranscript.chunksTranscribed) | Mic \(liveHearing.microphoneTranscript.chunksTranscribed)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

This keeps the header compact while avoiding a single merged chunk count.

- [ ] **Step 2: Verify the old total count is not displayed in the UI header**

Run:

```bash
rg -n "totalChunksTranscribed" falsoai-lens/ContentView.swift
```

Expected after this task: no match in `ContentView.swift`, or only usage outside the visible live-audio header if intentionally retained elsewhere.

---

### Task 6: Add A Developer-Only UI Assertion For Binding Separation

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add debug assertions in `liveTranscriptPanel`**

At the top of `liveTranscriptPanel(...)`, before the returned `VStack`, add:

```swift
#if DEBUG
if title == "Computer Audio" {
    assert(state.source == .computer, "Computer panel must receive computer transcript state")
}
if title == "Microphone" {
    assert(state.source == .microphone, "Microphone panel must receive microphone transcript state")
}
#endif
```

Expected: in Debug builds, an accidental swapped binding fails loudly.

- [ ] **Step 2: Verify `SourceTranscriptState.source` is still passed through**

Run:

```bash
rg -n "let source: CapturedAudioSource|state.source" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift falsoai-lens/ContentView.swift
```

Expected: `SourceTranscriptState` still has `let source: CapturedAudioSource`, and `ContentView.swift` checks `state.source` in the debug assertion.

---

### Task 7: Build Verification

**Files:**
- Build all Swift sources.

- [ ] **Step 1: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify the UI no longer has combined primary controls**

Run:

```bash
rg -n "Copy Both|liveTranscriptLane|totalChunksTranscribed" falsoai-lens/ContentView.swift
```

Expected: no matches.

---

### Task 8: Manual UI Verification

**Files:**
- Runtime verification in the app.

- [ ] **Step 1: Launch the app and scroll to live audio**

Expected:

```text
The live audio section shows one global capture control row and two clearly separate full-width panels.
```

- [ ] **Step 2: Inspect the Computer Audio panel**

Expected:

```text
Computer Audio has its own title, subtitle, copy button, transcript scroll area, and chunk/timing/language metadata.
```

- [ ] **Step 3: Inspect the Microphone panel**

Expected:

```text
Microphone has its own title, subtitle, copy button, transcript scroll area, and chunk/timing/language metadata.
```

- [ ] **Step 4: Confirm there is no primary combined transcript action**

Expected:

```text
There is no Copy Both button in the live audio section.
```

- [ ] **Step 5: Runtime source check**

Speak into the microphone while computer audio is silent.

Expected UI behavior after the transcript-layer separation plan is also implemented:

```text
Microphone text appears in the Microphone panel.
Computer Audio remains empty unless the computer capture source truly contains that audio.
```

Play computer audio while staying silent.

Expected UI behavior:

```text
Computer text appears in the Computer Audio panel.
Microphone remains empty unless the physical microphone picks up the speaker audio.
```

---

## Self-Review

Spec coverage:

- Microphone and computer are visually separated: Task 3 stacks full-width source panels.
- Source-local controls: Task 4 moves copy actions into each panel.
- Avoid combined display: Task 2 removes `Copy Both`; Task 5 replaces total chunk count with source-specific counts.
- Guard against accidental swapped bindings: Task 6 adds debug assertions.
- Build verification: Task 7 runs `xcodebuild`.
- Manual verification: Task 8 checks the actual app behavior.

Placeholder scan:

- No `TBD`, `TODO`, `implement later`, or vague "add appropriate UI" steps remain.

Type consistency:

- The plan uses existing `SourceTranscriptState`, `liveHearing.computerTranscript`, `liveHearing.microphoneTranscript`, `isEmpty`, `chunksTranscribed`, `lastInferenceDurationSeconds`, and `latestLanguage`.
- The new helper name `liveTranscriptPanel` is used consistently.
