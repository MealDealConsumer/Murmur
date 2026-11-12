# Murmur

Local dictation for this Mac. Hold **fn**, talk, let go, and the text is pasted where your cursor is.
Everything runs on this Mac: no account, no limits, nothing leaves the machine.

This is the Mac app. A Windows version is planned in this same repo; [WINDOWS.md](WINDOWS.md) is the plan.

## First run

1. Open **Murmur** from Applications (it is already installed and set to open at login).
2. Click **Allow** on the microphone prompt.
3. In the Setup page click **Allow** next to Accessibility, then tick **Murmur** in System Settings. This is what lets
   the fn key work and lets Murmur paste.
4. **Quit Wispr Flow** (and take it out of Login Items). Both apps listen to fn, so with both running every press
   starts two recordings, and its bar sits on top of Murmur's.
5. If fn opens the emoji picker, go to System Settings, Keyboard, and set "Press 🌐 key to" to **Do Nothing**.

## Using it

- **Hold fn** while you talk and **let go** to paste. For long dictations **hold fn and press Space**, then let go of both:
  it keeps listening hands free until you **tap fn** once more. The bars at the bottom of the screen bounce with your voice and
  settle to a slow ripple when you are quiet, so you can always see it is still listening.
- **Esc** while listening cancels. If you had been talking for more than a few seconds the audio is kept in History,
  so an accidental Esc can be undone with **Transcribe again**.
- Going quiet while you think never stops it. Only your key press stops it, or the 20 minute limit. A chime plays and
  the bar warns at five minutes left and again at one minute left. When the limit stops it, everything you said is shown
  in the card and kept in History, but never pasted, because by then you may have wandered off to another window.
- **Murmur never leaves your dictation on the clipboard.** A paste borrows the clipboard for a moment and puts back
  whatever you had copied before, so a link you copied before dictating is still there for Cmd+V afterwards.
- If no text box is focused, or the paste did not land, a card above the bar shows the text with **Copy** and
  **Open History**. Nothing is copied until you press Copy. The card goes away after about 6 seconds, or as soon as you
  paste, and the text is always still in History.
- **Control Command V** pastes your latest dictation again wherever the cursor is.
- Fillers (um, uh, erm, er, hmm) and stutters ("I I I think", "the the", "w-what") are removed. Real doubles such as
  "had had" and "that that" are kept. **Copy original** on a History entry gives you exactly what was heard.
- Everything you dictate is kept in **History** (menu bar icon, then History) for **seven days**, then deleted along with
  its audio so it never fills up the Mac. Click any entry to copy it. The last five are also in the menu bar menu.
- **Transcribe again** on a history entry reruns the saved audio, for when something came out wrong. The new text
  replaces the entry; click it to copy.

## Teaching it words

- **Say it.** "We should play deep woken, that's one word" pastes "We should play Deepwoken" and remembers it. Also works
  with "no dash", "no space", "with a capital G", "spelled J A X O N", "camel case", and "scratch that" to take back what
  you just said.
- **Fix it by hand.** If you correct a word in the pasted text (deep-woken to Deepwoken), Murmur notices within a minute
  and adds it. Ordinary English fixes like there to their are ignored on purpose.
- **Add it yourself** in the Dictionary page. "Often heard as" is optional: use it for mishears like roho for Rojo.
  Anything you add yourself always applies.
- **Claude chats fix it for you.** When a chat spots a clear mishearing in something you dictated, it adds the fix
  straight away with the `murmur` command, for example `murmur add "Rogue Lineage" --heard "rugged lineage"`, and tells
  you what it added. If it is not sure, it asks. A single everyday word such as "claw" is refused as a "heard as",
  because every claw you ever say would change, so the chat teaches the phrase instead. Problems that are not a word
  go into `FEEDBACK.md` here so the app itself can be fixed. `murmur list` shows your words and `murmur remove` takes
  one out.
- Your VoiceInk vocabulary (162 words, `VOICEINK_VOCAB.md`) and the two words from your Wispr dictionary are already in.
- Imported "heard as" rules made only of ordinary English words are switched off, because they rewrote normal sentences
  (rocket became rokit, Paris became parihsz, "how many small rooms" became howmanysmall). Two word API names such as
  replicated storage are left as you said them, so "get players" in a sentence never turns into GetPlayers. Long ones such
  as find first child of class are still joined. Add a rule yourself in the Dictionary page if you want one back.

## Settings

Change the key (fn, a right side modifier, or any key combination you record), switch between hold with Space for hands
free, press to start and press to stop, or hold only, pick English or
automatic language detection, and turn the spoken fixes, learning, start and stop sounds and the idle
bar on or off.

## Snippets

Save a phrase and the text it stands for, like "my email". Saying the phrase while dictating puts the text in its place.

## Rebuilding

`./scripts/build-app.sh --install` rebuilds and reinstalls, and puts the `murmur` command in `~/.local/bin`. The app is
signed with a local certificate, so macOS keeps its Microphone and Accessibility permissions across rebuilds.
