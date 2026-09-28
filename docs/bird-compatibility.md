# Bird 0.8 compatibility

The compatibility reference is the local Bird 0.8.0 distribution (`bird-copy`). The older 0.7.0 source checkout supplies additional test examples. Aviary remains a native Swift executable; Bird and Node.js are not runtime dependencies. Adapted code and fixtures retain the [upstream license notice](../THIRD_PARTY_NOTICES.md).

## Command matrix

| Commands | Compatibility contract |
| --- | --- |
| `read`, tweet ID/URL shorthand | One tweet; quoted text/media, article content, date/link/statistics; single-object JSON; raw JSON and quote depth. |
| `replies`, `thread` | Cursor/all/max-pages/delay, partial results and resumable failures; chronological thread order. A max-pages limit applies even with `--all`. |
| `search`, `mentions` | Search defaults to 10 results with cursor/all paging. Mentions defaults to the current account and supports `--user`; no paging flags. |
| `home` | 20 tweets from For You by default; `--following` selects the chronological Following feed. |
| `user-tweets` | 20 by default; page size 20, at most 200 tweets / 10 pages per invocation, 1,000 ms delay, resumable cursor. |
| `bookmarks` | Count/paging/folders; each bookmark's own thread is expanded and filtered; parent inclusion, thread metadata, sorting, and deduplication. |
| `likes` | Current account by default; count and cursor/all paging. |
| `following`, `followers` | Current account or explicit user ID; 20 users per page by default; count/cursor/all/max-pages. |
| `lists`, `list-timeline` | Owned/member-of lists with actual list metadata; list IDs or URLs; timeline count/paging. |
| `news`, `trending` | Default For You, News, Sports, Entertainment tabs; explicit tab selection, AI-only filter, related tweets, raw JSON; 10 items and 5 related tweets by default. |
| `tweet`, `reply` | Text and image/video attachments, alt text, upload/processing validation, returned tweet URL, operation errors and safe fallbacks. |
| `follow`, `unfollow`, `unbookmark` | User lookup and Bird result semantics; multiple tweet IDs for unbookmark. |
| `about`, `whoami`, `check` | Account information, credential diagnostics, accuracy fields, source information, and output modes. |
| `query-ids` | Cache metadata/IDs/discovery and feature status; fresh ID discovery and feature-cache refresh. Paths identify Aviary's separate caches. |
| `help`, `--help`, `-h`, `--version`, `-V` | All commands and options are available; help for unknown commands fails. Native help layout and executable branding differ. |

Normal collection JSON is an array. Paginated JSON contains `tweets` or `users` plus `nextCursor`, including an explicit `null` cursor at exhaustion. `read` JSON is one tweet object. Optional tweet fields follow Bird's omission rules; `--json-full` includes the unmodified API object in `_raw`.

Count and page flags retain their command-specific Bird behavior. For search, bookmarks, and likes, `--max-pages` needs `--all` or `--cursor`. For replies, thread, and list-timeline it enables pagination itself. Followers/following require `--all` with `--max-pages`. User tweets has its own bounded paging interface, without `--all`.

Cursor values are opaque and may resemble flags (for example, `--cursor -V`); they are passed through without version-flag rewriting.

## Configuration and isolation

Global `~/.config/bird/config.json5` and project `.birdrc.json5` are merged in that order. Valid JSON5 syntax and local null overrides are supported; malformed configuration warns. CLI/config/environment precedence, browser-source normalization, and profile environment variables match Bird. Default Chrome uses `Default`; Firefox prefers `default-release`. Explicit profile selection does not silently become a scan of other accounts.

Aviary reads legacy query-ID/feature caches as fallbacks, but default writes go to `$XDG_CONFIG_HOME/aviary` or `~/.config/aviary`. `AVIARY_QUERY_IDS_CACHE`, `AVIARY_FEATURES_CACHE`/`AVIARY_FEATURES_PATH`, and `AVIARY_FEATURES_JSON` provide Aviary-specific overrides. Legacy `BIRD_QUERY_IDS_CACHE`, `BIRD_FEATURES_CACHE`/`BIRD_FEATURES_PATH`, and `BIRD_FEATURES_JSON` remain supported as read-only inputs or invocation-only feature overrides. Cache refresh does not persist environment feature overrides.

Query-ID discovery pairs operation names and IDs within the same JavaScript object, not across adjacent operations. Feature inheritance uses one override snapshot per resolution, preserving global and per-set precedence without rereading caches for every parent set.

## Validation

`mise run test` runs the registered XCTest suites. `mise run test-filter NAME` passes its filter through to `swift test`. Tests cover CLI parsing and rendering, request/response behavior, failed uploads and posts, pagination/cursors, per-bookmark expansion, articles and raw JSON, cache isolation, and synthetic Chrome/Firefox/Safari cookies. Boundary regressions include nonzero-index media slices, malformed processing metadata, ambiguous follow/unfollow failures, adjacent query-ID definitions, and malformed cookie records. No live account mutations are part of the tests.

The checked-in oracle corpus contains every command/option from Bird 0.8, ordinary/quoted/article/video tweet mappings, rich article rendering, and normal/plain/no-emoji text snapshots. To regenerate it during development:

```bash
node scripts/generate-bird-fixtures.mjs /path/to/bird-copy
```

The generator reads Bird's pure mapper and CLI definitions; its writes are confined to Aviary's fixture directories. Tests consume the checked-in corpus and need neither Node.js nor Bird. New behavior should add a failing fixture or mock-session regression before changing the implementation.

## Intentional differences

- The executable is `aviary`; help layout and version branding are native to Swift ArgumentParser.
- Aviary keeps the existing `--full-chain` alias for `--full-chain-only` and nonconflicting optional positional username conveniences.
- Caches are separate from Bird. No command installs, changes, or replaces Bird.
- Browser credentials require a complete `auth_token`/`ct0` pair from the same exact `x.com` or `twitter.com` domain (with an optional leading dot), preferring X. Tokens from different domains are not combined. Firefox container identities are not currently distinguished within one domain.
- Ambiguous write failures are not automatically resubmitted. Follow/unfollow try another mutation endpoint only after an endpoint-not-found response; timeouts, rate limits, server errors, API rejections, and malformed success responses terminate the operation. Media processing must explicitly succeed once asynchronous processing begins; missing status metadata and exhausted polling fail rather than reporting success. Malformed responses, cookie files, and cursor cycles are bounded and reported safely. Malformed or nonpositive counts are rejected before requests rather than sending invalid numeric values to X.

Fixture parity establishes the local compatibility contract. X's private endpoints can change independently, so it does not guarantee every operation will keep working against the live service. Posting and account-changing operations are validated with mocks rather than live mutations.
