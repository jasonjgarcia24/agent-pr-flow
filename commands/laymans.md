---
description: Explain in plain, non-technical language — no jargon, no code deep dives, acronyms spelled out
argument-hint: [on|off|start|stop|replay|<something to explain>] — omit or "on" to switch to plain-language mode for the rest of the session
---

Respond in **layman's terms**, per the rules below and whichever branch of the Input section applies:

- **No code deep dives.** Don't use code, file paths, or line numbers as the explanation itself — describe what it does or what changed in plain language. If a code detail is genuinely necessary, keep it to a minimal, clearly-labeled aside, not the main explanation.
- **No unexplained technical jargon.** Skip engineering/domain terminology wherever a plain-language equivalent exists. If a technical term is unavoidable, define it in one plain clause the first time it's used.
- **Acronyms: always spelled out and briefly explained.** Never use an acronym bare on first use — spell it out and add a short, plain-language note on what it means (e.g., "API (Application Programming Interface — a way two programs talk to each other)"). After that first explained use, it's fine to use the acronym alone.
- **Explain outcomes and reasons, not mechanisms.** Favor "what it does and why it matters" over "how it's built internally." Analogies are welcome if they clarify.
- Stay direct and concise — layman's terms means simpler words, not longer answers.

## Input
$ARGUMENTS

If empty or the argument is **`on`** or **`start`** — turn plain-language mode ON going forward for the rest of the session.

If the argument is **`off`** or **`stop`** — turn plain-language mode OFF and go back to the normal (technical-as-needed) response style for the rest of the session. Confirm briefly that it's off; don't re-explain anything.

If the argument is **`replay`** or pointing to a previous response — re-explain the latest or the pointed-to response in layman's terms. This is a one-off translation, like the explain-a-topic case below: it does NOT change the ongoing mode. Pair with `on` (e.g. ask for both) if you also want plain-language mode going forward.

Otherwise, if other arguments are given, explain that specific thing in layman's terms right now (without changing the ongoing mode).
