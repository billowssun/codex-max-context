# Install the codex-max-context skill

These steps are for an AI coding assistant (Codex, Claude Code, or another agent that supports `SKILL.md` skills) that a user has asked to install this skill. Tell the user what you are doing as you go, in their language, and ask for approval when your environment requires it.

The skill raises the OpenAI Codex context window to the largest size Codex allows. It edits one line in `~/.codex/config.toml` and backs the file up first. Source: https://github.com/billowssun/codex-max-context

## 1. Pick the install folder

- If you are **Codex**: `~/.codex/skills/codex-max-context/` (use `$CODEX_HOME/skills/` if `CODEX_HOME` is set)
- If you are **Claude Code**: `~/.claude/skills/codex-max-context/`
- Any other agent: your own user-level skills folder. If you don't have one, skip ahead to step 3 and run the script straight from a temporary folder.

On Windows, `~` is the user's home folder, for example `C:\Users\<name>`.

## 2. Download and unzip

Download https://github.com/billowssun/codex-max-context/releases/latest/download/codex-max-context.zip

The zip holds a single folder, `codex-max-context/`, with `SKILL.md`, `README.md`, `LICENSE` and `scripts/`. Unzip it so you end up with `<skills folder>/codex-max-context/SKILL.md`. If that folder already exists, replace it; it contains only this skill.

- Windows (PowerShell): `Invoke-WebRequest <url> -OutFile $env:TEMP\cmc.zip; Expand-Archive $env:TEMP\cmc.zip -DestinationPath <skills folder> -Force`
- macOS / Linux: `curl -fsSL <url> -o /tmp/cmc.zip && unzip -o /tmp/cmc.zip -d <skills folder>`

## 3. Use it now

A freshly installed skill may not be loaded until the next session, so don't wait for it: open `<skills folder>/codex-max-context/SKILL.md` and follow its steps directly. In short:

1. Run the script for this OS with `--status` / `-Status` and show the user the current numbers.
2. Run it with no options to apply the change.
3. Tell the user how much context they will have after the change, where the backup is, and that they need to **quit Codex completely, reopen it and start a new conversation**.

## 4. Later

After this, the user can just say "max out my Codex context" or "restore my Codex context" in any session, and the skill will handle it.
