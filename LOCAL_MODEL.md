# Local Model — Option + L + M

Hold **Option**, then press **L and M together**. The same context capture and
insertion behavior used by Option+A+I now works with **Qwen3.5 9B Q4_K_M**, run
locally. Select text to work with that selection, or place the cursor in a readable
native text field to use the document around it. In web canvas editors, highlight
the text first.

The request goes directly from the Swift app to Ollama at
`http://127.0.0.1:11434`. The model name is pinned to
`qwen3.5:9b-q4_K_M`. The local shortcut never invokes Claude, fetches web pages,
downloads a model automatically, or switches to a cloud model on failure.
Option+A+I continues to use Claude.

Press either chord again to cancel the active request. Clipboard restoration,
the floating orb, and the focus guard work with both shortcuts. If you change
apps while it works, the answer stays on the clipboard for manual pasting.

## Runtime

- Needs [Ollama](https://ollama.com) and a one-time model download of about
  6.6 GB. No Python dependencies are needed.
- Requests a 32,768-token context and up to 2,048 output tokens. Reasoning output
  is disabled for responsive inline text work.
- Loads the model when needed and keeps it available for five minutes afterward.
  The first request can take longer than subsequent requests.
- Allows up to ten minutes for a request, including loading and reading context.
- Refuses input above the app's 100,000-character capture limit (by default),
  model context overflow, and incomplete output instead of inserting a partial
  answer. Select a smaller excerpt or request a shorter answer if necessary.
- Logs status and character counts, not local prompts or responses.

## Setup and recovery

The local backend requires Ollama **0.34.2 or newer**, including its explicit
controls for refusing prompt truncation. With Ollama running, download the exact
model once:

```sh
ollama pull qwen3.5:9b-q4_K_M
```

Disable Ollama cloud features by setting `disable_ollama_cloud` to `true` in
`~/.ollama/server.json` (preserve any other existing settings), then restart
Ollama:

```json
{
  "disable_ollama_cloud": true
}
```

Ollama should listen on `127.0.0.1:11434`, its default. Keep the Ollama app running
for the shortcut. After this initial download, inference needs no internet.
This setup configures cloud features off; requests from the shortcut also use
only the fixed loopback endpoint, bypass proxies, and reject HTTP redirects.

Run `./install.sh` to build and install the updated hotkey app. If a code-signing
identity is available, the build uses it, so the Accessibility permission survives
rebuilds.

To test the same local backend without capturing or inserting any screen text:

```sh
printf '%s\n' 'Reply with exactly: Local model ready.' | ~/.local/bin/optionai --local-smoke-test
```

To free the model's memory immediately:

```sh
ollama stop qwen3.5:9b-q4_K_M
```

The model will load again on the next local request. If the shortcut fails, check
the menu-bar tooltip and `~/Library/Logs/optionai.log`. Start Ollama if it is not
running. No fallback request is sent elsewhere.

## Privacy boundary

This applies to the **Option+L+M inference path**. Option+A+I still uses its normal
Claude backend. An editor's own sync or sharing features are separate from the
local model. Avoid placing private text in the Claude shortcut when local-only
processing is intended.
