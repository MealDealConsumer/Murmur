# Murmur engineering notes

Read this before changing the code. README.md is the user guide, WINDOWS.md the plan for the Windows version.

## Repo

Public on GitHub as `MealDealConsumer/Murmur` since 2026-11-12, so nothing private goes in: no dictionary, snippets,
history, recordings, logs or keys. `Vendor/` is not in git either. To rebuild it on a fresh Mac, unpack
`whisper-b5454-xcframework.zip` from whisper.cpp release b5454 into `Vendor/whisper.xcframework`, and
`llama-b12199-bin-macos-arm64.tar.gz` from llama.cpp release b12199 into `Vendor/llama` with `llama-server`, its dylibs
and `LICENSE` at the top. The release numbers are the ones recorded when the build was set up. Which llama archive was
used was not recorded; macos-arm64 is inferred from `llama-server` here being an arm64 binary. Check the paths against
`scripts/build-app.sh` after unpacking.

## What it is

A native Swift menu bar app (AppKit plus SwiftUI, built with SwiftPM from the command line, no Xcode project). Speech is
transcribed in process by **whisper.cpp** (official prebuilt `whisper.xcframework`, release b5454 / v1.9.5, Metal). Spoken
fixes go to a small local model, **Qwen3 4B Instruct 2507 Q4_K_M**, served by a bundled **llama.cpp `llama-server`**
(release b12199) as a child process on 127.0.0.1. Models live in `~/Library/Application Support/Murmur/Models`, the
dictionary and history beside them, logs in `~/Library/Logs/Murmur`.

## Pipeline

1. `HotkeyMonitor` (CGEventTap, session level, default tap so it needs Accessibility). Default mode `holdHandsFree`,
   matching Wispr's documented keys: holding the key records and letting go pastes, Space while holding latches hands free
   (the Space is swallowed), and a clean tap afterwards finishes. A recording that another key interrupts within 0.6 s
   is dropped so fn+arrow and fn+F keys still work. The `toggle` mode counts a press only on a clean release, the same
   rule VoiceInk uses (`ShortcutMonitor.swift`, read 2026-11-08). Cmd+V is reported so the missed paste card can close.
2. `AudioRecorder` (AVAudioEngine, converted to 16 kHz mono). A device change rebuilds the engine and keeps appending to
   the same buffer. A watchdog restarts capture after 2 s with no buffers.
3. `DictationController.tick` cuts finished pieces at natural pauses (`Chunker`, pieces of 12 to 28 s) and transcribes
   them while the user is still talking, so stopping only waits on the tail. Hard stop at 20 min, matching Wispr's
   documented hands free limit. `DictationController.warnings` flash the bar and play the Glass system sound at 15 and
   19 min (Glass was picked for the lowest peak of the chime sounds, -14 dB measured, not by ear). A stop by the limit is
   never pasted and never copied: it goes to the card with its own title and to History, because the owner may have left
   the chat by then.
4. `WhisperEngine`: automatic gain for quiet speech (boost only, max 30x, skipped below about -62 dBFS), Silero VAD at
   threshold 0.35, beam search 5, the dictionary as `initial_prompt` with `carry_initial_prompt`.
5. `TextPipeline`: dictionary `Replacer`, then only if a spoken instruction phrase is present, the sentences around it go to
   the model, with one retry, a leftover clause stripper, a diff to recover what the model fixed, and a deterministic
   "X is one word" fallback. The model answer is rejected if it adds words the passage did not have (`accept`).
6. `TextPipeline` also strips fillers (`stripFillers`) and stutters (`collapseStutters`) first and expands snippets
   (`SnippetStore`, `snippets.json`) last.
7. `TextInserter`: Accessibility focus check. **Nothing is ever left on the clipboard**, the owner's rule: a link copied
   before dictating must still paste afterwards. Editable or unknown means paste with a synthetic Cmd+V and put the old
   clipboard back as soon as `PasteCheck` sees the text in the field, or after 2 s, keeping the oldest snapshot when
   pastes overlap and leaving alone anything copied in between. Not editable means no paste, only the card. There is no
   setting to keep the text on the clipboard any more.
   Elements Chromium marks editable but whose role is a button or tab are treated as unknown. After a paste
   `DictationController.verifyPaste` runs `PasteCheck` on a background queue at 0.4, 1.0 and 2.0 s. Each try reads the
   original target, then whatever is focused now, then walks the front window (up to 6000 elements or 0.4 s) for a text
   field holding the first or last 32 letters of the text. Only if all three tries miss, and a text field could be read
   or the target was a guess, is the text shown in `MissedPasteCard`, a clickable panel sized to its content, whose Copy
   button is the only thing that puts it on the clipboard. Retrying from History does not copy either.
   A newer dictation cancels a pending check.
8. `EditWatcher`: reads the field back once a second for up to 60 s using 24 character anchors either side of the paste,
   then `EditLearner` diffs and learns small, similar, non English fixes.
9. `DictionaryBridge`: the `murmur` command (`~/.local/bin/murmur`, written by `build-app.sh --install`, which runs
   `Murmur --dictionary`) adds, removes and lists words. While the app runs the command posts a distributed notification
   and the app makes the change and answers, so the app's own saves never overwrite the file. With the app closed, or
   with `MURMUR_DATA_DIR` set, it edits the file directly. A single everyday English word as "heard as" is refused
   without `--anyway`, because personal variants always apply and it would rewrite every sentence using that word.
   This exists so any Claude chat fixes a clear mishearing the moment it notices one, without asking first, and asks
   only when it is unsure; the global `~/.claude/CLAUDE.md` tells chats how. Chats log problems that are not a word
   in `FEEDBACK.md`, which is the first thing to read before changing the app. Any local process could post the same notification, but any local process can already write the
   dictionary file, so it opens nothing new.
10. `HistoryStore`: entries and their audio older than seven days are deleted, the owner's choice on 2026-11-11, at
   launch, on every new entry and once an hour so an idle app still forgets on time. Within the week at most 2000
   entries and the newest 40 recordings are kept, plus failed ones so they can be retried. Audio files no entry points
   at are deleted at launch once they are a week old. Saved outcomes keep the raw value `copied` for what the code now
   calls `notPasted`, so older history files still load.

## Research findings (sources, read 2026-11-08)

- **Wispr Flow runs speech recognition in the cloud.** "Transcription always occurs on the cloud"
  (https://wisprflow.ai/data-controls). The CTO on SE Radio 703 describes a speech model then an LLM on their own servers
  (https://se-radio.net/2026/01/se-radio-703-sahaj-garg-on-low-latency-ai/). Their in house speech model Canto launched
  17 Sep 2026 and is fed the user's dictionary (https://wisprflow.ai/canto). Cleanup runs on fine tuned Llama models on
  Baseten per Baseten's case study (only search extracts were readable, not the page itself). Published target: 700 ms
  end to end (https://wisprflow.ai/research/technical-challenges).
- **The Mac client is Electron.** Observed directly in the installed bundle: id `com.electron.wispr-flow`, ships
  `Electron Framework.framework`, version 1.6.1400, plus a separate Swift helper app. Strings in the helper include
  `AXManualAccessibility`, `AXEnhancedUserInterface` and `org.nspasteboard.ConcealedType`.
- **How Wispr learns from edits**, inferred from its own database migrations in the bundle (observation, not documentation):
  History rows store `pastedText`, `textboxContents`, `axText`, `editedText`, `editDistanceToDictated` (normalised
  Levenshtein) and `contentObservationEndReason` with values seen in the user's data such as `next_paste_started`,
  `observation_window_elapsed` and `anchor_mismatch`. The Dictionary table has `phrase`, `replacement`, `source`,
  `observedSource`, `isSnippet`. Murmur's `EditWatcher` follows the same shape.
- **Open source apps doing the same job:** VoiceInk (Swift, GPL 3, whisper.cpp plus Parakeet, the only one found with
  learn from corrections, and it asks before adding), Handy (Rust and Tauri, MIT, no learning), OpenWhispr (Electron, MIT,
  auto learn setting), FluidVoice (Swift, GPL 3), Hex (Rust, MIT). None of them falls back to copying when no field is
  focused, and none suppresses the Globe key action.
- **Engines:** Parakeet TDT 0.6B v3 is faster and scores better on the Open ASR leaderboard (6.3% vs 7.8% for whisper
  large v3 turbo, from the model cards) but has no prompt biasing, and whisper.cpp's own Parakeet support is marked TODO in
  its header. Whisper was chosen because the user's Roblox vocabulary needs the prompt.

## Measurements on this Mac (M4 Pro, 48 GB)

- Speed with chunking and beam 5: 11 s of audio in about 0.6 s, 56 s in about 1.9 s, 380 s in about 11.7 s. In the app most
  of that happens while the user is still talking.
- 16 of the user's own recordings from Wispr's history: word disagreement with Wispr's cloud transcript 27.4% without
  chunking (one 6 min clip lost 40% of its words), 7.3% with chunking, 6.4% with the dictionary prompt, and **5.7% in the
  final build** (filler removal and the stricter dictionary). Most of what is
  left is formatting such as "1,600" against "one thousand six hundred". This is agreement with Wispr, not accuracy:
  there is no ground truth transcript.
- Quiet speech: the macOS Whisper voice at -52 dBFS and a user recording turned down 18 dB to -56 dBFS both transcribed
  fully. 30 s of room noise at the user's measured floor (-69 dBFS) gave no text, and so did 20 s of louder noise at
  -50 dBFS and a low hum at -46 dBFS. A 25 s silent pause mid recording kept both halves with nothing invented.
- Spoken fixes: `scripts/llm-cases.txt` holds 17 sentences, seven of which only mention "one word", "spelling", "no
  spaces", "delete that" or "I mean" and must stay unchanged. Two runs of the final build: 17 of 17 and 15 of 17, the two
  misses cosmetic (a leftover "camel case", a trailing comma, the comma since fixed). The model varies between runs even at
  temperature 0, which is why the deterministic guards in `TextPipeline.correct` exist. No run changed a sentence that
  should stay. The 9B Qwen3.5 model was tried and was slower and no better, so it was dropped. Run them with `while read -r l; do .build/release/Murmur --process "$l"; done < scripts/llm-cases.txt` and a
  `MURMUR_DATA_DIR` copy so learned words do not land in the real dictionary.
- End to end through the real controller fed from a file: 57 s of audio pasted 0.81 s after stop, 380 s pasted 1.18 s
  after stop with 853 of Wispr's 855 words.
- The live test against TextEdit passed: focus detected as an editable AXTextArea, Cmd+V pasted, clipboard restored,
  a hand edit of deep-woken to Deepwoken was learned, the tap saw a clean tap and ignored a chord, the mic delivered audio.

## Precision rules after review (2026-11-08)

Two independent read only reviews found that the first version mangled ordinary sentences. The rules now:
- Imported variants apply only if a word in them is not ordinary English (two letter fragments like lu and d count as not
  ordinary) or they are three or more words for a term with three or more capitals. Variants the user teaches are kept in
  `personalHeardAs` and always apply.
- Separate spoken words merge only into a coined two part word (Deepwoken, Bitmon) or a long API name of three or more
  words. Merges never cross a comma or a spaced dash. Two word API names are left as spoken.
- Only a hand typed dictionary entry can respell an existing term. Edits that only remove capitals or only change digits
  are never learned.
- The correction model's answer is used only if every removed word is paid for by an instruction (`removalAllowance`),
  no negation was added, no short word was invented, and a spelling instruction actually respelled something. An unchanged
  answer is final. The model is not asked again after an error in the same dictation.
- Esc, quit and logout keep the audio in History. Timers run in common mode so an open menu cannot pause chunking or the
  20 minute stop. Whisper failures are flagged and the audio kept.

## Second pass with the owner present (2026-11-08)

Verified live by the owner: Accessibility granted on the stable signature, fn dictation into VS Code, the voice bars
reacting to speech, the missed paste card on the desktop and its 6 s auto close, holding fn to talk, and fn with Space
for hands free. Added at the owner's request: live voice bars
(`VoiceBars`, a smoothed level drawn every frame), stutter and filler removal, snippets, Control Command V to paste the
last dictation, words and pace stats on History, Copy original, optional sounds, a language setting, the missed paste
card. "Wispr Flow" was added to the dictionary as a hand entry because Whisper hears it as Voiceflow.

Left out on purpose because they depend on a large cloud model in Wispr: automatic tone per app, automatic list
formatting, backtracking without an explicit phrase, and the select text then speak an edit command mode.

## Not verified

- How the warning chime sounds, and how loudly the real microphone picks it up, are unknown since I cannot hear. The
  limit test mixed it at its full file level, alone at 5 min and over speech at 15 and 19 min, and no stray words came
  out (2026-11-08). The same run stopped at exactly 1200 s, warned at 900 s and 1140 s, and made no paste attempt. Rerun on 2026-11-11
  after the clipboard rule: same timings, and the clipboard held what was there before for the limit run, for a normal
  paste 2.5 s later, and straight away for a paste marked as landed.
- fn and pasting into VS Code were verified live by the owner on 2026-11-08: a 9.7 s dictation pasted into the VS Code
  chat box (AXTextArea, editable) about 1 s after stop. The Globe key was set to Do Nothing
  (`defaults write com.apple.HIToolbox AppleFnUsageType -int 0`) at the same time, and no emoji picker was reported.
- Learning from a hand edit inside VS Code, Discord, Chrome and Codex. Only TextEdit was tested for that. Electron and
  Chromium apps get `AXManualAccessibility` set, which is what Wispr and FluidVoice do.
- British English accuracy has no ground truth. Whisper writes American spelling by default and nothing converts it.
- The reworked paste check has not yet been seen live on a dictation into the VS Code Claude chat. What was verified:
  the log showed false cards in VS Code on targets reported as `AXRadioButton` or `AXWebArea`, and twice on a readable
  `AXTextArea` whose value lacked the text at 0.6 s. Why the text area read missed is not proven; a late tree update or
  a stale element are the likely causes but neither was observed. A read only probe showed VS Code reporting a tab or
  checkbox as focused while the walk reached the chat boxes at depth 24 to 29 in about 0.1 s. `--paste-check` against a
  background TextEdit file found the text and reported a miss for absent words. The Claude extension inserts a paste
  itself as plain text below 50,000 characters (read from its `webview/index.js`), so a big paste is not turned into an
  attachment there.

## Developer commands

All run the same binary, `.build/release/Murmur` after `swift build -c release`:

- `--selftest` dictionary, learning, cue and fallback tests (no model needed)
- `--transcribe file.wav ... [--no-prompt] [--greedy] [--no-agc] [--vad 0.5]` full pipeline on files, prints timings
- `--process "text"` the text pipeline with the correction model
- `--live-test` paste, learning, hotkey and mic against TextEdit, aborts unless TextEdit is frontmost
- `--e2e-test file.wav` drives the real controller from a file and pastes into TextEdit, same guard
- `--limit-test file.wav` needs `MURMUR_DATA_DIR`. Plays a file longer than 20 min through the real controller with
  the Cmd+V keystroke blocked and the chime muted, prints when each warning fired, where it stopped, whether anything
  tried to paste and whether the clipboard came back untouched, then a 20 s clip that must try to paste once, then a
  paste that is confirmed and must give the clipboard back at once. Test audio is built from `say` sentences and the
  Glass sound.
- `--render-ui dir` renders every pill state and window tab to PNG
- `--diag` permissions and model presence
- `--dictionary add|remove|list ...` what the `murmur` command runs
- `--paste-check [--app bundle.id] "text"` runs `PasteCheck` against the front app, or a named one, and prints what it saw
- Any other `--` flag prints an error and exits, it never starts the app
- `MURMUR_DATA_DIR=dir` points dictionary and history somewhere disposable, `MURMUR_LLM_MODEL=path` swaps the model

## Traps already hit

- **The Metal backend asserts at process exit** if a whisper context is still alive (`ggml-metal-device.m:1040`). The app
  frees the model and calls `_exit` in `applicationWillTerminate`, and the CLI does the same.
- **AVAudioFile throws when reading past the end** instead of returning zero frames, so reads are sized to what is left.
- **Whisper drops whole stretches of long audio** when given one long buffer. That is why chunking exists.
- **SwiftUI `strokeBorder` on these capsules drew stray ticks** outside the ends. `HairlineCapsule` uses two stacked fills.
- **NSSpellChecker auto detects language** and accepted rojo as a word, so it is pinned to English.
- **Orphaned correction servers.** A plain kill skipped `applicationWillTerminate`, so each reinstall left llama-server
  running with its parent gone, about 2.4 GB each; two were found and stopped on 2026-11-08. The old cleanup trusted a
  pid file that any CLI run deleted on exit. Now SIGTERM goes through `NSApp.terminate`, the pid file is gone, and every
  launch stops any copy of Murmur's own llama-server whose parent is pid 1 (`LLMService.killOrphanedServers`). Other
  llama.cpp installs are never touched.
- **An unknown flag used to start a second full copy of the app**, with its own event tap, so fn would fire twice. It
  happened once from a failed build leaving an older binary. Unknown `--` flags now exit with an error.
- **Signing:** builds are signed with the self signed identity "Murmur Local Signing" in
  `~/Library/Keychains/murmur-signing.keychain-db`, which was added to the user keychain search list on 2026-11-08 with the
  owner present. The designated requirement is the bundle id plus the certificate leaf, so permissions survive rebuilds.
  Before that the app was signed ad hoc and every rebuild looked like a new app, which is why the first Accessibility
  switch did nothing: it belonged to an earlier build. If the identity is ever missing, `build-app.sh` falls back to ad hoc.
