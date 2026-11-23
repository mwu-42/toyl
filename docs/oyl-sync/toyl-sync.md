---
description: Take in what's changed in toyl since Oyl last did (from ~/toyl/docs/oyl-changes.md)
---

Bring Oyl up to date with toyl.

- Run `~/toyl/docs/oyl-sync/pending.sh` to see the toyl changes Oyl hasn't taken in yet. If it prints nothing,
  say Oyl's up to date and stop.
- Read `~/toyl/docs/oyl-integration.md` for how Oyl and toyl fit together, and its rules: never launch or
  activate Oyl or toyl while testing, don't edit anything in `~/toyl`, don't commit unless asked, and leave
  uncommitted work that isn't yours alone.
- Make each change the entries ask for, in order, with and without toyl working as the integration document
  says. Test headlessly as it describes.
- Then write the latest entry's number (`~/toyl/docs/oyl-sync/pending.sh --latest`) into `~/Oyl/.toyl-sync`.
- Finish with a short list of what changed in Oyl, and anything you couldn't do or need the owner to decide.
