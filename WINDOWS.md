# Murmur on Windows

Written on the Mac on 2026-11-11 for the Claude chat that builds the Windows version. Nothing Windows exists yet. Every
fact below says where it came from; anything marked **check** was not verified and has to be tested on the PC.

## The short version

The Mac app is Swift, AppKit and SwiftUI. None of that runs on Windows, so this is a **port, not a tweak**: the logic
carries over almost line for line, while the keyboard hook, the focus check, the paste, the bar and the windows are
rewritten against Windows APIs. Build it in `windows/` in this repo. The Mac code stays where it is.

## What the owner gets on the Mac today (the target)

Read README.md for the full list. The parts that matter most to the owner:

- Hold a key to talk, let go to paste where the cursor is. Hold it and press Space for hands free, tap it to finish.
- A bar at the bottom of the screen with bars that react to the voice. It never takes focus.
- **The clipboard is never left holding a dictation.** A paste borrows it and puts back what was there, as soon as the
  text shows up in the field or after 2 s. If nothing could be pasted, a card shows the text with a Copy button, and
  nothing is copied unless that button is pressed. This was the owner's explicit rule on 2026-11-11.
- Everything goes to History, kept **seven days** then deleted with its audio (owner's choice, 2026-11-11).
- Filler and stutter removal, spoken fixes ("that's one word", "scratch that"), learning from hand edits, snippets.
- 20 minute cap, no silence cutoff, a chime and bar warning at 15 and 19 minutes, and at 20 minutes the text is held
  in the card and History, never pasted.
- A `murmur` command so any Claude chat can fix a misheard word in the dictionary.
- Everything local. No account, nothing leaves the machine.

## Ask the owner first

Use the question tool, one plain sentence each saying what the choice is and what a yes changes.

1. **Which key to hold.** On the Mac it is fn. On most Windows laptops fn is handled inside the keyboard and never
   reaches Windows as a key at all (**check** on this PC: hook the keyboard and press it). Wispr Flow's own Windows
   default is **Ctrl + Win** to hold and **Ctrl + Win + Space** for hands free
   (docs.wisprflow.ai/articles/6391241694-use-flow-hands-free, read 2026-11-11). Recommend matching that, because the Mac
   version matched Wispr's Mac keys.
2. **Whether to bring the Mac dictionary and snippets over.** They are personal and never go in this public repo. The
   owner would copy `dictionary.json` and `snippets.json` from `~/Library/Application Support/Murmur/` on the Mac by
   hand. The file format is the same on both machines, so keep it identical.
3. **Whether Wispr Flow is installed on this PC.** If it is, both apps would answer the same key. On the Mac the
   owner quit Wispr.

## Check the PC before choosing anything

- Windows version, CPU, RAM, and the GPU: `nvidia-smi`, or `Get-CimInstance Win32_VideoController`. This decides
  whether speech runs on CUDA, Vulkan or the CPU.
- What is already installed: `git`, the .NET SDK (`dotnet --list-sdks`), `ffmpeg`, and `winget` to install what is
  missing. Ask before installing anything large.
- Where Documents really is: `[Environment]::GetFolderPath('MyDocuments')`. It may be inside OneDrive.

## Recommended stack

This is a recommendation reasoned from what each piece needs, not something tested on Windows.

- **C# on .NET (the current LTS), WPF for the windows.** It reaches every Win32 API below directly and has maintained
  packages for audio and whisper.
- **Speech: Whisper.net** (github.com/sandrohanea/whisper.net, latest release 1.9.1 on 2026-06-01, checked 2026-11-11).
  Its README lists runtimes for CPU, CUDA 13, CUDA 12 and Vulkan, picks one automatically with CUDA ahead of Vulkan,
  and has a `WhisperVadFactory` for voice activity detection. **Check** that it exposes everything `WhisperEngine.swift` sets:
  initial prompt, carrying the prompt across pieces, beam search of 5, and the Silero VAD threshold of 0.35. If it does
  not, call `whisper.dll` from the official whisper.cpp build instead: release **b5454** (the same build the Mac uses,
  tagged v1.9.5) ships `whisper-bin-x64.zip` and `whisper-bin-win-cuda-12.4.0-x64.zip` (asset list read 2026-11-11).
- **Correction model: llama.cpp `llama-server.exe`** as a child process, exactly like the Mac. Release **b12199**
  ships `llama-b12199-bin-win-cpu-x64.zip`, `llama-b12199-bin-win-cuda-12.4-x64.zip` (needs
  `cudart-llama-bin-win-cuda-12.4-x64.zip` beside it) and `llama-b12199-bin-win-vulkan-x64.zip` (asset list read
  2026-11-11). Same flags as `LLMService.swift`, same prompt, same guards.
- **Audio: NAudio** (github.com/naudio/NAudio, v3.3.0 on 2026-10-19), WASAPI capture converted to 16 kHz mono float.
- **Models: the same three files and URLs** as `ModelCatalog` in `Sources/Murmur/Support/Paths.swift`: Whisper large
  v3 turbo q8_0, Silero VAD v6.2.0, Qwen3 4B Instruct 2507 Q4_K_M. About 3.4 GB together.

## Mac file to Windows piece

| Mac | What it does | Windows |
|---|---|---|
| `System/HotkeyMonitor.swift` | CGEventTap, hold, Space latch, clean tap, 0.6 s chord rule | `SetWindowsHookEx(WH_KEYBOARD_LL)` on its own thread with a message loop |
| `System/AX.swift`, `TextInserter.swift` | Is the focused thing a text field, paste, put the clipboard back | UI Automation: `GetFocusedElement`, control type Edit or Document, `ValuePattern` and its `IsReadOnly`. Clipboard plus `SendInput` Ctrl+V |
| `System/PasteCheck.swift` | Did the text land: read the target, the focus, then walk the window | Same three steps through UI Automation, same node and time budget |
| `System/EditWatcher.swift` | Read the field back for 60 s to learn hand edits | UI Automation reads; `Text/EditLearner.swift` is pure logic |
| `Audio/AudioRecorder.swift` | Mic capture, device change, 2 s watchdog | NAudio WASAPI |
| `Audio/Chunker.swift`, `Text/*`, `Engine/LLMService.swift` | Chunking, pipeline, dictionary, learning, snippets, history, model prompt | Port line for line |
| `App/DictionaryBridge.swift` | `murmur` command talking to the running app | A named pipe served by the app, and `murmur.cmd` on PATH |
| `UI/Overlay.swift`, `UI/MissedPasteCard.swift` | The bar and the card | Borderless topmost WPF windows that never activate |
| `UI/MainView.swift` | Settings, History, Dictionary, Snippets | A WPF window opened from a tray icon |
| `App/AppSettings.swift` | Settings, open at login | Settings file, `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| `SelfTest.swift` | The behaviour spec | Port every check. They must all pass |

Two Apple only calls sit inside the text logic and need a replacement:
- `Text/Vocabulary.swift` uses `NSSpellChecker` to decide whether a word is ordinary English, which decides whether a
  "heard as" rule may apply. Windows has its own spell checking API, or a bundled word list works. Results will
  differ, so run the SelfTest cases and write down every difference.
- `Text/TextPipeline.swift` uses `NLTokenizer` to split sentences.

## Windows traps known before starting

- **A slow keyboard hook gets removed without warning.** Microsoft: "on Windows 7 and later, the hook is silently
  removed without being called. There is no way for the application to know whether the hook is removed", and from
  Windows 10 1709 the timeout is at most 1000 ms (learn.microsoft.com, LowLevelKeyboardProc, read 2026-11-11). The hook
  must only record the key and hand everything else to another thread.
- **Pasting into an app running as administrator fails silently.** Microsoft on SendInput: "Applications are permitted
  to inject input only into applications that are at an equal or lesser integrity level", and "neither GetLastError
  nor the return value will indicate the failure was caused by UIPI blocking" (read 2026-11-11). Treat an elevated
  foreground window as nowhere to paste and show the card.
- **The bar and card must never take focus**, or the paste lands in Murmur's own window. Show them without activating
  (`WS_EX_NOACTIVATE`, `WS_EX_TOOLWINDOW`). The bar also ignores the mouse; the card does not, it has buttons.
- **Chromium and Electron apps** (VS Code, Discord, Chrome) may not expose their text fields to UI Automation until
  something asks. On the Mac this needed `AXManualAccessibility`. **Check** what VS Code reports on Windows before
  trusting the focus check, because VS Code is where the owner dictates most.
- **Windows clipboard history** (Win+V) records everything put on the clipboard, which would keep every dictation.
  Microsoft documents clipboard formats that ask history to skip an entry; **check** them and mark the temporary paste
  that way, the same way the Mac marks it transient.
- Holding Ctrl + Win might open the Start menu on release (**check**). If it does, the hook has to swallow it.

## Order of work

1. Check the PC, ask the three questions, then propose the plan to the owner before writing code.
2. A console project first: port `Text/` and `Audio/Chunker.swift`, then every SelfTest check.
3. Speech: download the models, transcribe generated audio. Windows can speak test sentences through
   `System.Speech.Synthesis`, the way the Mac used `say`.
4. `llama-server.exe` and the 17 sentences in `scripts/llm-cases.txt`.
5. Hotkey, recording, the paste into a Notepad window the test opened itself, the bar.
6. Paste check against VS Code, the card, History with the seven day cleanup, the 20 minute limit.
7. The `murmur` command, then add the misheard dictation rule from this repo's CLAUDE.md to the Windows machine's own
   `~/.claude/CLAUDE.md` so every chat on the PC fixes words too.
8. Tray icon, settings, open at login.

## Testing rules carried over from the Mac

- Generate test audio. Do not use the owner's own recordings unless they say so.
- Point every test at a throwaway folder (`MURMUR_DATA_DIR`), never the real dictionary or History.
- Tests never paste into the owner's apps. Paste only into a window the test opened, or block the keystroke.
- Claude cannot hear. Anything about how a sound sounds is a measurement and says so.
- Keep the same developer flags as the Mac (`--selftest`, `--transcribe`, `--process`, `--dictionary`,
  `--limit-test`) and the same environment variables, so NOTES.md stays true for both.
- Write what was learned on Windows into NOTES.md under its own heading, and fix any line that stops being true.
