# Murmur

Local dictation, a Wispr Flow replacement that runs entirely on the machine. The Mac app (Swift, `Sources/`) is
finished and in daily use. A Windows version does not exist yet; it goes in `windows/` in this same repo.

## Read before doing anything

1. **On Windows: [WINDOWS.md](WINDOWS.md) first.** It is the porting plan and lists what to ask the owner.
2. [NOTES.md](NOTES.md), the engineering notes: pipeline, measurements, traps already hit, what is not verified.
3. [FEEDBACK.md](FEEDBACK.md), problems Claude chats noticed in real dictations. Fix the cause, then delete the line.
4. [README.md](README.md) is the user guide, which doubles as the feature list.
5. `Sources/Murmur/SelfTest.swift` is the behaviour spec for the text pipeline. A port passes the same cases.

## This repo is public

Never commit the owner's dictionary, snippets, history, recordings, logs, models or any key. `.gitignore` covers the
known files; check `git status` before every commit anyway. Commit with the GitHub noreply address, not a personal
email: `git config user.email 278188596+MealDealConsumer@users.noreply.github.com` in this repo.

## How the owner wants to work

- The owner reads only the final message of a turn, so it has to stand on its own: what changed, what was tested,
  what was not, and anything they need to do, marked **needs you:**. Short bullets, conclusion first.
- No em dash, en dash or spaced hyphen in anything written for the owner. Plain words, no unexplained jargon.
- Never guess. Verify by running or reading, and say plainly what could not be verified. Claude cannot hear audio,
  so anything about how a sound sounds comes from measurement and has to say so.
- Flag anything added that was not asked for.
- Decisions that are the owner's go through the question tool the moment they come up, not at the end.
- Commit or push only when asked.
- Code comments: first person notes to myself, terse, say why not what. One `//` line, or a block of three lines at
  most. Never two `//` lines in a row forming one thought.

## Misheard dictation

The owner dictates with Murmur, so messages can carry misheard words ("claw chat" for "Claude chat"). On the Mac any
chat fixes a clear mishearing straight away with `murmur add "<right spelling>" --heard "<what appeared>"` and says
what it added. Unclear ones are asked about. Ordinary English fixes are never added, and a single everyday word as
`--heard` is refused, so teach the phrase instead. Problems that are not a word go in FEEDBACK.md, quoting only the
words that went wrong because this file is public. Once the Windows build has its own `murmur` command, the same rule
goes into the Windows machine's `~/.claude/CLAUDE.md`.
