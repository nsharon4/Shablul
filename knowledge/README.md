# knowledge/

Cached **technical** knowledge only. Governed by `CLAUDE.md`.

## Rules

1. **7-day TTL.** Every note carries `expires_utc` in its front-matter.
   On expiry the note is **deleted and regenerated from source** — never patched,
   never extended. An expired note is not evidence.
2. **Nothing dynamic.** Prices, quotes, rates, balances, positions, market data
   and any other live figure are **never** written here. They are fetched live at
   the moment of every question. A value older than 24 hours is unreliable by rule.
3. **Every claim is sourced.** Inline `[S#]` markers resolve to a URL plus the UTC
   time it was actually retrieved. Anything that could not be reached is listed
   under *What is NOT verified*, with the reason.

## Commands

```bash
tools/knowledge.sh status                   # fresh / EXPIRED per note
tools/knowledge.sh expired                  # expired slugs only
tools/knowledge.sh purge                    # delete expired notes
tools/knowledge.sh new <slug> "<title>"     # scaffold with correct dates
```
