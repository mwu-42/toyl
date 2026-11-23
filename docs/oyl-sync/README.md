# Keeping Oyl in step with toyl

toyl writes a numbered entry in `docs/oyl-changes.md` for every change that matters to Oyl. Oyl remembers the
last one it took in, in `~/Oyl/.toyl-sync`. These pieces tie the two together.

- **`pending.sh`** prints the entries Oyl hasn't taken in (nothing when it's up to date). `--latest` prints the
  newest entry's number.
- **`toyl-sync.md`** is a Claude Code command for Oyl: copy it to `~/Oyl/.claude/commands/toyl-sync.md`, then
  `/toyl-sync` in a Claude Code session in `~/Oyl` takes in whatever's pending.
- **A session-start hook** for Oyl, so every Claude Code session there is told when toyl has changed. Add this to
  `~/Oyl/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "out=$(\"$HOME/toyl/docs/oyl-sync/pending.sh\"); [ -n \"$out\" ] && printf 'toyl has changed since Oyl last took it in. Tell the owner, and offer to run /toyl-sync:\\n\\n%s\\n' \"$out\"; exit 0"
          }
        ]
      }
    ]
  }
}
```

Fully hands-off is possible too: a git `post-commit` hook in `~/toyl` that runs
`claude -p "/toyl-sync"` in `~/Oyl` whenever `docs/oyl-changes.md` changes. It isn't set up, because it would
edit Oyl with nobody watching, possibly over someone's unfinished work there.
