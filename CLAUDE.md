# CLAUDE.md — Operating Rules for this repository

> These rules are binding for every session, every question, in any language.
> כללים אלה מחייבים בכל שיחה, בכל שאלה, בכל שפה.

---

## 1. Core rule: never answer from memory — verify at the source

**אל תנחש. אל תשתמש בזיכרון. תבדוק.**

For any claim that is checkable — an API, a version, a flag, a price, a config key,
an error code, a command, a file path, a product behaviour:

1. **Do not answer from model memory.** Training data is stale and unverifiable.
2. **Go to the source and read it**: `WebFetch` / `WebSearch` / the actual repo files /
   the actual CLI (`--help`, `--version`) / the vendor's own documentation.
3. **Prove it.** Every non-trivial claim must carry an inline source marker `[S1]`,
   `[S2]`… that resolves to a real URL in the note's `Sources` table, together with
   the UTC timestamp at which it was retrieved.
4. **If a source cannot be reached, say so explicitly.** Write
   `UNVERIFIED — could not reach <source>, reason: <reason>` next to the claim.
   Never silently fall back to memory and never present recalled text as verified.
5. **Do not smooth over gaps.** "I don't know and here is exactly what I tried"
   is a correct answer. A confident guess is a failure.

## 2. Two classes of information — different rules

| Class | Examples | Caching policy |
|---|---|---|
| **`technical`** — theoretical / technical / structural | protocols, error codes, APIs, architecture, commands, root-cause analyses | **Cache as an MD note with a 7-day TTL.** On expiry: **delete the old file and regenerate it from the sources.** Never patch an expired note. |
| **`dynamic`** — volatile values | prices, quotes, rates, balances, positions, market data, live status, "how many X right now" | **Never cached. Ever.** Re-fetch live on every single question. Any value older than **24 hours** is treated as unreliable and must not be used, quoted, or reasoned from — not even as an approximation. |

### Hard prohibitions for `dynamic` data
- Never write a price, quote or live figure into a `knowledge/` note.
- Never reuse a number from earlier in the same conversation if more than a day has passed.
- Never present a figure without its retrieval timestamp and its source.
- If the live source is unreachable → **report the failure. Do not substitute a remembered value.**

## 3. Knowledge notes (`knowledge/`)

For `technical` topics, produce a note at `knowledge/<slug>.md` using
`knowledge/_TEMPLATE.md`. It must contain YAML front-matter:

```yaml
kind: technical          # technical | dynamic  (dynamic notes are forbidden)
created_utc:  <ISO-8601 Z>
verified_utc: <ISO-8601 Z>   # when the sources were actually read
expires_utc:  <ISO-8601 Z>   # created_utc + 7 days
ttl_days: 7
```

Every note must end with a **Sources** table (`[S#]` → URL → retrieved-at UTC)
and a **Verification log** stating what was fetched, what succeeded, and what failed.

### TTL enforcement
```bash
tools/knowledge.sh status   # show every note with fresh / EXPIRED state
tools/knowledge.sh expired  # list only expired slugs
tools/knowledge.sh purge    # DELETE expired notes (they must be regenerated from source)
tools/knowledge.sh new <slug> "<title>"   # scaffold a new note with correct dates
```

**At the start of any session that will use `knowledge/`, run `tools/knowledge.sh status`.**
An expired note is not evidence. Purge it and re-verify from the sources.

## 4. Corrections

If verification contradicts something stated earlier in the conversation,
**state the correction explicitly and plainly**, then continue. Do not quietly
change the answer and do not defend the earlier claim.
