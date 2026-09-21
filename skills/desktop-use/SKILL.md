---
name: desktop-use
description: >-
  Drive macOS apps through the Accessibility tree with a fast typed action loop.
  Use when the user asks to click, type, open, scroll, switch, or otherwise
  operate a native Mac app, browser, menu, or desktop UI, including computer use.
  Prefer this over screenshot-based computer use.
---

# Desktop use

Run macOS UI tasks with `/Users/taro/.local/bin/desktop-use`. The command reads the Accessibility tree, asks Jev through Vercel AI Gateway for one typed action at a time, performs it, and prints a short JSON result. The tree never comes back to you.

Use this before Codex computer use, `cua_repl`, screenshots, or one-off AppleScript. If the result says the control is not available to Accessibility, Codex may fall back to native computer use. In Cursor, say that this interface is not visible to Accessibility.

## Call

Pass a short goal and, when the user named apps, an allow list. Do not pass the conversation, file contents, or secrets.

```bash
/Users/taro/.local/bin/desktop-use run --goal "Open Notes and type hello"
/Users/taro/.local/bin/desktop-use run --allow Notes --goal "Open Notes and type the meeting is at 3"
```

Add `--verbose` only when a run failed and the cycle trace is needed. It writes to stderr.

## Result

Read the JSON on stdout. Tell the user the `summary`. Do not paste the raw JSON unless they asked.

- `done` (exit 0): the goal finished. `actions` lists what ran.
- `needs_confirmation` (exit 2): a send, post, delete, pay, publish, or quit was held. Ask the user. Only after they agree, run the same goal again with `--approve`.
- `unclear` (exit 2): the target was ambiguous. Ask which one, then run a more specific goal.
- `blocked` (exit 3): it stopped. If the allow list is the reason, ask before widening `--allow`.
- `error` (exit 1, or 4 when Accessibility is missing): report the summary. Do not invent a retry that clicks around the failure.

`--approve` applies to the whole goal, so keep that goal to the single held action.

## Setup failures

A missing key or Accessibility grant is a setup problem, not a task to solve by clicking.

```bash
/Users/taro/.local/bin/desktop-use key status
/Users/taro/.local/bin/desktop-use access
```

Jev is `typesafe-ai/jev` on Vercel AI Gateway, with zero data retention. The key is `AI_GATEWAY_API_KEY` already in the environment. Do not print it, pass it as an argument, or write it into a file. Accessibility must be enabled for `/Users/taro/.local/bin/desktop-use`.
