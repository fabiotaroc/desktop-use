# desktop-use

A local macOS command that does computer use for Cursor and Codex. It reads the Accessibility tree, asks Jev through Vercel AI Gateway which typed action to take, performs that action, and prints a short JSON result.

## What it does

You pass one goal. The command loops:

1. Read the front app's Accessibility tree.
2. Offer a closed list of actions.
3. Ask Jev for one operation and one target.
4. Perform it in Swift.
5. Stop when the goal is done, the screen cannot continue, or the next action needs confirmation.

Send, post, delete, pay, publish, and quit stop unless you pass `--approve`. `--allow` limits which apps may be touched.

## Setup

macOS 14.2 or later, Swift, `AI_GATEWAY_API_KEY` in the environment, and Accessibility permission for the installed binary.

```bash
bash scripts/install.sh
desktop-use key status
desktop-use access --prompt
```

`install.sh` builds the release binary, signs it with a stable local identity, and copies it to `~/.local/bin/desktop-use`. The skill stays in `skills/desktop-use/` until you install it yourself.

If `desktop-use` is not on your `PATH`, call `~/.local/bin/desktop-use`.

## Commands

```bash
desktop-use run --goal "Open Notes and type hello"
desktop-use run --allow Notes,Finder --goal "Open the Downloads folder"
desktop-use run --approve --goal "Send the draft"
desktop-use access [--prompt]
desktop-use key status
desktop-use self-check
```

`run` prints JSON on stdout. `--verbose` writes the cycle trace to stderr.

Jev is requested as `typesafe-ai/jev` from `https://ai-gateway.vercel.sh/v4/ai/evaluation-model`, with `zeroDataRetention` on. Yes/no questions are Gateway booleans. Set `DESKTOP_USE_MODEL` to use a different gateway model id.

Exit codes: `0` done, `2` needs confirmation or an unclear target, `3` blocked, `4` Accessibility is missing, `1` any other error.