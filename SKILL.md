---
name: codex-max-context
description: Raise the OpenAI Codex context window to the largest size Codex allows (for example GPT-6.1 Sol from ~475K to ~828K) by setting model_context_window in ~/.codex/config.toml, on Windows, macOS or Linux, with automatic backup and one-step undo. Use when the user says their Codex context is too small, asks for a 1M / larger context in Codex, mentions model_context_window, or asks to undo that change. 当用户说 Codex 上下文太小、想把上下文调到 1M、想改 model_context_window 或想还原时使用。
---

# Codex max context

Sets the top-level `model_context_window` key in the Codex config file and tells the user what they will actually get. Codex caps the value at the model's own maximum (read from `models_cache.json`) and then shows about 95% of it as usable, so "1M" usually shows as less. Report the real number, not 1M.

This only affects **Codex** (desktop app, CLI, IDE extension). The ChatGPT web and mobile apps have no local setting for this, so say so if the user asks about them.

## Files

- `scripts/set-context.ps1`: Windows (PowerShell 5.1+), also PowerShell 7 on macOS and Linux
- `scripts/set-context.sh`: macOS, Linux, WSL, Git Bash (bash + awk only)

Both scripts take the same options:

| Purpose | PowerShell | bash |
|---|---|---|
| Show current state, change nothing | `-Status` | `--status` |
| Preview the change | `-DryRun` | `--dry-run` |
| Set a value (default 1000000) | `-Value N` | `--value N` |
| Look up limits for another model | `-Model SLUG` | `--model SLUG` |
| Undo the most recent change | `-Restore` | `--restore` |

The config lives in `$CODEX_HOME` if that is set, otherwise in `~/.codex`. The scripts only edit top-level `model_context_window` lines in `config.toml` and leave everything else as it is, including `[profiles.*]` sections. Before each actual change they save a field-level undo record in `config.toml.ctxundo-<timestamp>-<sequence>/`. Repeating the same value is a no-op.

## Scope

Change **only** `model_context_window`. Don't touch `model`, reasoning effort, providers, plugins, profiles or any other setting, and don't edit `config.toml` by hand. Use the scripts, which make only this change. If the user asks for anything beyond the context window, treat it as a separate request.

## Steps

1. **Pick the script for the OS.** `<skill-dir>` is the folder this file is in.
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\set-context.ps1" <options>`
   - macOS / Linux / WSL: `bash "<skill-dir>/scripts/set-context.sh" <options>`
   - If the user runs Codex in WSL but you are on the Windows side (or the reverse), ask which install they mean. Each one has its own `~/.codex`.

2. **Check the current state first.** Run it with `--status` / `-Status` and show the user the model, the current setting and the usable size.

3. **Apply the change.** Run it with no options to set 1000000, or with `--value` if the user asked for a specific number. If you are running inside Codex and the write is blocked by its sandbox, ask the user to approve the command or run it themselves (see the README).

4. **Report back in the user's language.** Include:
   - the line that was written and where the backup is
   - the expected usable size after restart, from the script output. Make clear that this is the real ceiling, and if it is below 1M, explain that Codex caps it.
   - next steps: **quit Codex completely** (not just close the window; on Windows also check the system tray), reopen it, and **start a new conversation**. Existing conversations keep their old size.
   - cost: a longer context means each request uses more quota. On the API, input over 272K tokens is billed at a higher rate.

5. **Undo.** If the user wants to go back, run it with `--restore` / `-Restore`. That restores only the context key from the newest safe undo record, preserving unrelated current settings. Repeated changes undo in reverse order. If the context key has changed independently, the script refuses with a conflict and leaves files untouched. An initially absent config is removed only if undo leaves no other content. Legacy `ctxbak` backups are not automatically restored; review them manually and restore only the context key.

## Troubleshooting

- **"Cached limits: not found":** Codex hasn't downloaded its model list yet, or the model name doesn't match. Open Codex once, or pass `--model gpt-6.1-sol`. The setting is still written, but the script can't predict the usable size.
- **Size unchanged after restart:** Codex was probably still running, or the user is looking at an old conversation. Also check that no `-c model_context_window=...` flag or profile overrides it.
- **Error about the file being in use (Windows):** quit Codex first, then run it again.
