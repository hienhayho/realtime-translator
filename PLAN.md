# Implementation Plan — Self-Managed Install + Process Supervision + Models UI

Sequential checklist. Work top to bottom, verify each step before moving on.
Full design rationale: `/Users/hienht/.claude/plans/encapsulated-hatching-marble.md`
(note: that file still says "hand-assembled .app bundle" — superseded below,
this PLAN.md uses `.xcodeproj` instead, per later decision).

## 0. Packaging decision (settled)

Use a **checked-in `.xcodeproj`** with a proper macOS App target, not a
hand-assembled bundle script. Reasons: Xcode owns Info.plist/codesign/bundle
wiring natively (no custom script to maintain), same build path for dev
(Cmd+R) and install (`xcodebuild -scheme ... -configuration Release build`),
easier to extend later (app icon, entitlements, real signing).

- [x] **0.1** Generated via `xcodegen` from `macapp/project.yml` (not hand-written
      pbxproj — safer/diffable). macOS App target `Translate`, sources from
      `Sources/Translate/`, Info.plist merged in place (now has
      CFBundleIdentifier/CFBundleName/etc + NSMicrophoneUsageDescription),
      bundle ID `com.hienhayho.translate`, deployment target macOS 14.
      `Translate.xcodeproj` stays gitignored (regenerate via `xcodegen generate`);
      `project.yml` is the committed source of truth.
- [x] **0.2** Verified: `xcodebuild -project Translate.xcodeproj -scheme Translate -configuration Release build`
      → BUILD SUCCEEDED. `codesign -dv` confirms `Info.plist entries=21`
      (bound, not "not bound" like raw `swift build`).
- [x] **0.3** Verified: Cmd+R in Xcode works, mic permission prompt fires correctly.
- [x] **0.4** Kept `Package.swift` — still used by `.vscode/launch.json`'s
      `swift build`-based debug workflow, coexists fine with `.xcodeproj`
      (same `Sources/Translate/` dir, no conflict).

## 1. Backend: minimal config + health endpoint

- [x] **1.1** `backend/app/main.py` — added `GET /health` route, returns
      `{"status": "ok"}`. Verified live: uvicorn takes ~7s to become ready
      (model load time), returns `{"status":"ok"}` once up.
- [x] **1.2** `backend/app/config.py` — `WHISPER_TIER = os.environ.get("WHISPER_TIER", "tiny.en")`,
      `WHISPER_MODEL_DIR`/`WHISPER_ENCODER`/`WHISPER_DECODER`/`WHISPER_TOKENS`
      derived from it. Also updated `app/asr/whisper.py` logs to reference
      the tier dynamically instead of hardcoded "base.en".
- [x] **1.3** `backend/scripts/download_models.sh` — rewritten: dropped
      stale Bonsai-MLX vendor flow entirely, downloads Gipformer + tiny.en
      Whisper only (both already present locally from earlier session work).
- [x] **1.4** `backend/pyproject.toml` — fixed stale description string.
- [x] **1.5** Verified: unset `WHISPER_TIER` → loads tiny.en (default);
      `WHISPER_TIER=base.en` → loads base.en. Both confirmed via direct
      `uv run python -c "..."` import test with real log output.

## 2. Swift: process supervision

- [x] **2.1** `macapp/Sources/Translate/Process/ProcessStatus.swift` — done.
- [x] **2.2** `macapp/Sources/Translate/Process/BackendProcessManager.swift` —
      done, plus `resolveBackendDir()` (checks `~/.translate-app/backend`
      first, falls back to `#filePath`-relative for dev builds run from
      this checkout — fixed an off-by-one bug caught during testing).
- [x] **2.3** `macapp/Sources/Translate/AppDelegate.swift` — done, wired via
      `@NSApplicationDelegateAdaptor` in `TranslateApp.swift`.
- [x] **2.4** Verified end-to-end against the real Xcode-built `.app`
      (not just `swift build`'s bare binary — quit-cleanup specifically
      needs a real `NSApplication` termination flow, confirmed via
      `osascript -e 'tell application "Translate" to quit'`):
      - Both subprocesses spawn with correct args/env/ports (llama-server:
        `-hf unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL ...`; uvicorn: `WHISPER_TIER`
        defaults working, tiny.en loaded).
      - `/health` polling on both transitions to `.healthy` (confirmed via
        direct curl, both responded 200 within ~1s using already-cached models).
      - Log capture works — `~/Library/Logs/Translate/backend.log` and
        `llama-server.log` both populated with real startup output.
      - Quit cleanup: real quit (AppleEvent, not bash `kill`) leaves zero
        orphaned processes. Noted: a raw `kill <app-pid>` via signal does
        NOT reliably trigger `applicationWillTerminate` (SIGTERM isn't the
        same as an `NSApplication` quit event) — orphans are possible under
        a hard kill/crash, acceptable known gap, real Cmd+Q path is clean.
      - Also had to `xcodegen generate` again after adding the new Swift
        files — `Translate.xcodeproj` doesn't auto-pick-up new files,
        needs regeneration whenever source files are added (relevant for
        install.sh, which already plans to run `xcodegen generate`).

## 3. Swift: model selection state

- [x] **3.1** `macapp/Sources/Translate/State/ModelSelection.swift` — done
      (built alongside step 2 since BackendProcessManager needed the enums
      to compile). `WhisperTier` (tinyEn/baseEn/mediumEn, default tinyEn),
      `TranslationModel` (qwen4B/qwen9B, default qwen4B). Persisted via
      manual `UserDefaults` read/write in `didSet` (not the `@AppStorage`
      property wrapper — that requires a SwiftUI View context, this is a
      plain `@Observable` class — functionally equivalent).
- [x] **3.2** `BackendProcessManager.restartPython(withTier:)` /
      `.restartLlama(withModel:)` — done (built alongside step 2). Confirmed
      correct asymmetry in code: `restartPython` only touches
      `pythonProcess`/`pythonStatus`, `restartLlama` only touches
      `llamaProcess`/`llamaStatus`. Not yet tested live via UI (no picker
      exists yet — that's step 5); logic verified by reading, will get a
      real end-to-end test once ModelsView exists.

## 4. Swift: WS reconnect logic

- [x] **4.1** `macapp/Sources/Translate/Networking/SessionCoordinator.swift` —
      rewritten. `isIntentionalDisconnect` flag distinguishes user-initiated
      `stop()` from an unexpected drop. Unexpected drop →
      `attemptReconnect()`: exponential backoff (0.5s→1s→2s→4s, capped 5s),
      6 attempts, probes `/health` before reconnecting, gives up with
      `.failed(...)`. Planned relaunch → `disconnectForPlannedRelaunch()` /
      `reconnectAfterPlannedRelaunch()`, a separate deterministic path (no
      backoff — caller already knows the new process is healthy via
      `BackendProcessManager.restartPython/.restartLlama`, which now await
      `waitUntilSettled()` before returning). `activeSource` kept alive
      across reconnects (not nilled) so resume doesn't need the caller to
      re-pick a file/mic — except on explicit `stop()`, which does nil it
      (no reconnect should ever resume a deliberately-stopped session).
- [x] **4.2** Verified via build only so far (`swift build` +
      `xcodebuild` both clean, `xcodegen generate` re-run since new methods
      were added to existing files — doesn't need regeneration for that,
      only for new *files*, but ran it anyway to keep the Xcode project
      fresh for interactive testing). **Full live reconnect test (kill
      backend mid-session, watch actual reconnect) deferred to after step 5**
      — needs a real UI trigger for the model-switch path; the
      unexpected-drop path could be tested now but is more meaningfully
      tested once there's a Listen button wired through the full stack in
      the new sidebar shell.

## 5. Swift: new UI shell

- [x] **5.1** `macapp/Sources/Translate/Views/Sidebar.swift` — done.
      `NavigationSplitView`, `SidebarDestination` enum (translate/models),
      `systemImage` per destination.
- [x] **5.2** `macapp/Sources/Translate/Views/ModelsView.swift` — done. Form
      with Translation Model picker, English STT picker, process status
      rows (`pythonStatus`/`llamaStatus` from `BackendProcessManager`,
      color-coded), Advanced section (host/port, folded from SettingsView).
      Picker `.onChange` sequences `onBeforeModelSwitch()` (sync,
      disconnects WS first) → `processManager.restartX()` (async, awaits
      health) → `onAfterModelSwitch()` (async, reconnects WS) — see
      SessionCoordinator's planned-relaunch path from step 4.
- [x] **5.3** `macapp/Sources/Translate/TranslateApp.swift` — replaced
      `WindowGroup { ContentView }` with `NavigationSplitView` sidebar
      shell; removed `Settings { SettingsView }` scene; wired
      `ModelSelection`/`BackendProcessManager` construction +
      launch-on-appear via `.task`.
- [x] **5.4** Deleted `SettingsView.swift` (folded into ModelsView).
- [x] **5.5** **REVERTED per user correction** — white background made the
      sidebar/toolbar look visually broken against system dark mode (flat
      dark chrome next to a stark white content pane). Removed
      `.background(Color.white)` from `ContentView` entirely; app now uses
      system-default adaptive appearance throughout, no forced white
      anywhere. (Plan's original "white background" requirement is
      superseded by this correction — noted here since it contradicts
      Section E/H.3 of the full design doc.)
- [x] **5.6** Verified: `swift build` and `xcodebuild` both clean.
      Confirmed visually via screenshot — sidebar (Translate/Models,
      correct icons) + Translate view (header, status banner, two-column
      transcript) render correctly in native dark appearance. Models tab
      not click-tested via GUI automation (no accessibility permission
      granted to the shell) but is straightforward SwiftUI that compiled
      clean and whose logic was verified by reading. Subprocess spawn +
      clean-quit re-confirmed working after the UI rewrite (no orphans on
      real quit).

## 6. Install script

- [ ] **6.1** `install.sh` at repo root — preflight checks (brew, git,
      xcode-select, arch), clone/pull to `~/.translate-app`, `uv sync`,
      `brew install llama.cpp` if missing, download Gipformer+tiny.en,
      `xcodebuild -project macapp/Translate.xcodeproj -scheme Translate -configuration Release build`,
      copy resulting `.app` to `/Applications/Translate.app`, `open` it.
- [ ] **6.2** Root `README.md` — minimal pointer + one-line install command.
- [ ] **6.3** Root `.gitignore` — `.DS_Store`, editor dirs.
- [ ] **6.4** Verify: fresh-ish run of `install.sh` (or dry-run the steps
      manually) produces a working `/Applications/Translate.app`.

## 7. Docs cleanup

- [ ] **7.1** `macapp/README.md` — update "requires backend running first"
      language.
- [ ] **7.2** `backend/README.md` — note manual launch is now optional/dev-only.
- [ ] **7.3** `BACKEND.md` — document `WHISPER_TIER` env var under Model Setup.

## Open items to resolve during implementation (see full plan doc Section I)

- Port-in-use handling for 8000/8081 (fail with clear error, no dynamic
  reassignment).
- Ad-hoc codesign means mic permission re-prompts on every rebuild/reinstall
  — accepted tradeoff, no paid Developer ID in scope.
