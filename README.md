# Codex Pulse

Codex Pulse is a private, local macOS token dashboard for Codex Desktop and CLI sessions. It appears in both the Dock and the menu bar, has a draggable glass toolbar, and presents raw token counts, estimated Codex credits and API-equivalent cost, the current server-reported weekly-limit percentage remaining, how that limit is pacing against the window, and live weekly token totals by chat with each chat's share of weekly usage. The interface uses a light "liquid glass" theme and does not follow the system appearance.

## Privacy boundary

The collector whitelists session metadata, turn context needed for model attribution, thread settings needed for service-tier attribution, and token-count events. Message and tool-output events are skipped and are never persisted.

## Build

The project intentionally has no third-party dependencies and builds with the Apple command-line developer tools:

```bash
make test
make app
make verify
make package
```

The native shell uses AppKit and WebKit. The dashboard is bundled HTML/CSS/JavaScript and makes no network requests.

## Updates

Codex Pulse checks the repository's latest public GitHub release shortly after launch. The menu-bar menu also includes **Check for Updates…**. Update archives are accepted only when the GitHub-provided SHA-256 digest, bundle identifier, version, and macOS code signature all verify. The app then replaces its existing bundle and relaunches itself.

## Accounting

- `total = input + output`
- Cached input is a subset of input.
- Reasoning output is a subset of output.
- Historical events are calculated from cumulative-counter deltas, with `last_token_usage` as the reset-safe fallback.
- Event keys deduplicate moved or archived session files.
- Local event detail begins on June 1 and continues forward. The local ledger grows with retained history so it does not silently discard older usage.
- Credits use the bundled dated OpenAI rate table.
- GPT-6 Astra (including the `gpt-6` alias) uses the September 9, 2026 [Codex credit rates](https://developers.openai.com/codex/pricing) and [API rates](https://developers.openai.com/api/docs/models/gpt-6-astra). Fast mode applies 2.5x credits and 2x API cost; Priority applies 2x API cost with the existing base-credit estimate. Previously unpriced saved events are priced on load when their model becomes supported.
- Dollar amounts are API-equivalent estimates, not ChatGPT subscription charges.
- Estimates use base token rates and recorded service tiers; they do not account for long-context surcharges or separately billed cache writes.
- Weekly remaining uses the complete seven-day rate-limit window. Shorter windows and incomplete events are ignored.
- The Active chats panel uses the same current seven-day window and reports each chat's raw tokens plus its percentage of the week's tracked tokens.
- The pace projection divides the server-reported weekly-limit percentage by the fraction of the limit window that has elapsed. It is a linear extrapolation of the current rate; non-zero usage is shown early as an explicitly provisional estimate and becomes stable-labelled after 8% of the window has passed. It is not a prediction from OpenAI.
