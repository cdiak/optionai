# optionai

**Option+A+I — an agent at your cursor, everywhere on your Mac.**

**Option+L+M — the same interaction with a local model.** Uses Qwen3.5 9B Q4_K_M
through [Ollama](https://ollama.com), with no cloud fallback. See
[local model setup and usage](LOCAL_MODEL.md).

Put your cursor in any text field. Hold **Option**, then press **A** and **I** together (two hands, on purpose). optionai reads the context of the textbox you are in. It sends that context to a coding agent ([Claude Code](https://claude.com/claude-code), `claude -p`). It pastes the agent's response at your cursor. A small orb floats near the pointer while the agent thinks.

```
⌥A+I  →  ◍ think  →  paste at cursor
```

optionai is the sibling of [everywhisper](https://github.com/cdiak/everywhisper) (Option+Shift+W, local dictation). Same skeleton: one Swift file, a menu-bar item, a chord event tap, a LaunchAgent.

## Install from a prompt

Copy everything inside the block below and paste it into a coding agent (Claude Code, Cursor, Codex, …). It should build optionai, start the login agent, and tell you which permission to grant — no manual GitHub steps.

```text
Set up optionai: a system-wide "agent at the cursor" hotkey (Option+A+I) on this Mac. Do every step yourself in the shell; do not tell me what to run. Stay on macOS only.

Repo: https://github.com/cdiak/optionai
Source dir: ~/.local/src/optionai unless I name another folder (create parent dirs if needed). It only holds the source to build from; install.sh copies everything it runs into ~/.local.
Binary: ~/.local/bin/optionai
LaunchAgent label: com.cdiak.optionai

Steps:
1. Prerequisites
   - Confirm macOS (uname -s is Darwin). If not, stop and say optionai is macOS-only.
   - Ensure Xcode Command Line Tools (swiftc) are available. If missing, run xcode-select --install and wait / guide only if the GUI installer blocks non-interactive completion.
   - Ensure the Claude Code CLI (claude) is available. If missing, install it with: curl -fsSL https://claude.ai/install.sh | bash
   - Check auth: if `claude -p "say ok"` fails with an auth error, tell me to run `claude` once and log in, then continue.
2. Clone
   - Call the source dir SRC.
   - If SRC is already a git clone of this repo, git pull --ff-only origin main (or the default branch).
   - If SRC exists but is not this repo, move it to SRC.bak.<timestamp>.
   - Otherwise: git clone https://github.com/cdiak/optionai.git SRC
3. Install
   - cd SRC
   - ./install.sh
4. Verify process
   - Confirm ~/.local/bin/optionai exists and is executable.
   - Confirm the LaunchAgent is loaded: launchctl print "gui/$(id -u)/com.cdiak.optionai" shows running / path.
   - tail ~/Library/Logs/optionai.log and confirm an "optionai ready" line (or note the Accessibility prompt).
5. Permissions (cannot be automated — be explicit)
   - Tell me I must enable Accessibility for optionai in:
       System Settings → Privacy & Security → Accessibility
   - Tell me the hotkey activates automatically the moment I flip the toggle: the menu bar item turns from ◌ to AI. No restart needed.
   - If the app is missing from that list, run ~/.local/bin/optionai once from the terminal to trigger registration, then:
       launchctl kickstart -k "gui/$(id -u)/com.cdiak.optionai"
6. Report when done
   - clone path, claude path, binary path, whether the agent is running, log snippet, and the hotkey (Option+A+I; press again to cancel).
   - Remind me: click a text field (or highlight text), hold Option, press A and I together.

If any step fails, diagnose and fix before reporting done. Prefer fixing brew/path/auth issues over asking me to run commands.
```

After the agent finishes, grant **Accessibility** when prompted, then try **⌥A+I** in any text field.

## Requirements

| Need | Notes |
|------|-------|
| macOS | Apple Silicon or Intel; tested on recent macOS |
| [Xcode Command Line Tools](https://developer.apple.com/xcode/) | for `swiftc` (build once) |
| [Claude Code CLI](https://claude.com/claude-code) | `claude` on `PATH`, logged in |

No other dependencies. The orb spinner is vendored (no network calls).

## Manual install

```bash
git clone https://github.com/cdiak/optionai.git
cd optionai
./install.sh
```

This builds `~/.local/bin/optionai` and registers a login LaunchAgent.

Then grant one permission: **System Settings → Privacy & Security → Accessibility → optionai**. This one permission covers both reading the textbox and pasting.

The Option+A+I chord activates the moment you flip the toggle — no restart needed. Until then, the menu bar shows **`◌`** (waiting for permission); it turns to **`AI`** when the hotkey is live.

## The context rule

One if-statement. It decides what the agent sees:

1. **You highlighted text** → the highlight is the context. This works everywhere. Native apps: read directly through Accessibility. Web canvas apps (Google Docs): optionai performs an invisible copy, reads it, and restores your clipboard — you never press Cmd+C.
2. **No highlight** → the whole document is the context, split at your cursor. The agent writes at the split point. (Native apps only — web canvas apps cannot expose the whole document.)
3. **No highlight and nothing readable** → a beep. Highlight first.

The mental model: *either this whole doc is the context window, or whatever I've highlighted is.* The clipboard is never an input — optionai uses it only as internal transport, inside a transaction that puts your clipboard back. Stale clipboard contents can never leak to the agent.

One quirk: a few editors copy the current line when nothing is selected (VS Code's default). If such an app also hides its text from Accessibility, an empty-selection trigger can capture one stray line instead of beeping.

## What the agent does with it

The prompt tells the agent: write only the text to insert at the cursor. No preamble. No code fences unless the document is code. If the text near the cursor asks a question or gives an instruction, it answers it. Otherwise it continues the document.

So you can:

- Type "TODO: write a closing paragraph about X" and press ⌥A+I.
- Select a rough sentence, press ⌥A+I, and get a response to it.
- Put the cursor mid-draft and let it continue.

## Safety behaviors

- **Focus guard.** If you switch apps while the agent runs, optionai does not paste. It leaves the response on the clipboard and plays the Submarine sound. Press Cmd+V wherever you want it.
- **Cancel.** Press ⌥A+I again while the orb is spinning.
- **Clipboard restore.** After a normal paste, your previous clipboard contents come back (same trick as everywhisper).
- **Neutral cwd.** The agent runs in a temp directory. No project `CLAUDE.md` leaks into your document context.

## The orb

The spinner is the **composing** state from [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) (MIT, Jakub Antalik). We vendor only the framework-free canvas engine (pinned from `thinking-orbs@0.3.1`, zero dependencies, no network calls) and drive it with a short vanilla script, rendered in a borderless WKWebView panel near the pointer. The engine is inlined into `orb/orb.html`: WebKit refuses ES-module fetches from `file://` pages, so a separate module file would silently never load. `orb/engine.es.js` stays as the pristine vendored copy. License in `orb/LICENSE.thinking-orbs`.

## Configuration

Environment variables, set in the LaunchAgent plist (re-run `./install.sh` after changing them):

| Var | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_CLI` | `which claude` | Path to the claude CLI |
| `OPTIONAI_MODEL` | CLI default | Passed as `--model` |
| `OPTIONAI_TIMEOUT` | `180` | Seconds before the agent call is killed |
| `OPTIONAI_MAX_CONTEXT` | `100000` | Max context characters (75% before cursor, 25% after) |
| `OPTIONAI_ORB_DIR` | `~/.local/share/optionai/orb` | Orb assets; unset → menu-bar indicator only |
| `OPTIONAI_ORB_MODE` | `follow` | `follow` = orb rides beside the mouse pointer; `caret` = orb sits at the text caret |

Example:

```bash
OPTIONAI_MODEL=claude-sonnet-5 OPTIONAI_TIMEOUT=120 ./install.sh
```

## Sounds

| Sound | Meaning |
|-------|---------|
| Tink | Context captured, agent started |
| Glass | Response pasted |
| Submarine | Focus changed — response is on the clipboard |
| Pop | Canceled |
| Basso | Agent failed (see `~/Library/Logs/optionai.log`) |

Menu bar: **`AI`** idle · **`◍`** thinking · **`◌`** waiting for Accessibility (plus the floating orb). Quit from the menu bar item.

## Uninstall

```bash
./uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE). The vendored orb engine is MIT-licensed by Jakub Antalik — see [orb/LICENSE.thinking-orbs](orb/LICENSE.thinking-orbs).
