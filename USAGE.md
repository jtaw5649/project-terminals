# Usage

Set or show projects directory:

```bash
project-terminals projects-dir ~/Projects
project-terminals projects-dir
```

Set or show automatic login restore:

```bash
project-terminals auto-restore off
project-terminals auto-restore on
project-terminals auto-restore
```

Press `Super+Alt+Enter` to open menu.

- **New terminal**: choose project. Repeat for more terminals.
- **Reopen terminal**: reopen closed Foot window.
- **Restore all terminals**: reopen every remembered terminal.
- **Remove terminal**: stop and forget one terminal.
- **Finish project**: stop all managed project processes and forget its terminals.

Close Foot window to keep terminal running. Run `exit` inside shell to stop and
forget that terminal.

Codex conversation is saved after first prompt. On first use, trust project if
asked. If Codex warns about hook review, run `/hooks`, trust hook, then restart
Codex.

Saved terminals reopen after login when automatic restore is on. Run
`project-terminals restore` to restore immediately.
