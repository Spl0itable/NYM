# Audit 02 — Relay transport / networking / backend API client

1:1 fidelity audit of the native Flutter clone against the Nymchat Nostr PWA for
the relay transport, networking, and backend API-client slice.

Scope (owned): `lib/services/relay/**`, `lib/services/api/**`,
`lib/services/nostr/{nostr_service,event_mapper,event_signer,identity_service,nym_generator}.dart`.

PWA reference: `../js/modules/{relays,nostr-core,users}.js`,
`../functions/api/{relay-pool,relay,proxy,storage,bot,_shared}.js`,
`../js/modules/build-verify.js`.

Verification: `flutter analyze lib/services` clean; subsystem tests
(`relay_test`, `network_test`, `storage_sync_test`, `nostr_service_test`) green —
79 tests (was 73; +6 added for the fixes below).

## Discrepancy table

| # | Item | PWA behavior | Flutter (before) | Action |
|---|------|--------------|------------------|--------|
| D1 | **Geo channel publish frame** | `broadcastEvent` routes a kind-20000 event carrying a `g` tag through `["GEO_EVENT", evt, [closestUrls]]` when `getClosestRelaysForGeohash` is non-empty, else plain `["EVENT", evt]` (relays.js:3380-3401). | `NostrService.publishChannelMessage` always called `pool.publish` (plain `EVENT`) for geo channels; `RelayPoolProxy.publishGeo` existed but was never called. | **FIXED.** `publishChannelMessage` now calls `pool.publishGeo(signed, closestGeoRelays(geohash).urls)` for geo channels; named channels keep plain publish. Proxy `publishGeo` falls back to plain `EVENT` when the url list is empty (mirrors the PWA fallback). |
| D2 | **DM / gift-wrap publish frame** | All kind-1059 gift wraps publish via `sendDMToRelays`, which in proxy mode emits `["DM_EVENT", evt]` so the proxy prioritizes the default relays (relays.js:3270-3276; call sites in nostr-core.js / pms.js / groups.js). | `NostrService._wrapAndPublish` (the single funnel for PM / group / receipt / typing / friend-presence / private-reaction wraps) called plain `pool.publish` (`EVENT`). | **FIXED.** `_wrapAndPublish` now calls `pool.publishDm(wrap)`. Direct mode's `RelayPool.publishDm` is a plain publish (correct — direct mode has no proxy frame). |
| D3 | **`POOL:RELAY_BAN` inbound frame** | The proxy can push `["POOL:RELAY_BAN", relayUrl, reason]`; the PWA permanently blacklists the relay so it is excluded from future `_shardRelaysByRole` layouts (relays.js:2117-2124). | The Flutter pool-frame parser dropped `POOL:RELAY_BAN` (fell into the `default` → null branch); a banned relay would be re-added on the next shard rebuild. | **FIXED.** Added `PoolRelayBan` parse (validates `wss://`) and `_onShardMessage` now adds the url to the proxy's `_permanentBlacklist` (made mutable), mirroring `_permanentlyBlacklistRelay`'s effect on the layout. Exposed `permanentBlacklist` getter for inspection/tests. |
| D4 | **API host** | The PWA derives the host from `window.location.host`; the canonical/official host is asserted as `web.nymchat.app` (build-verify.js:10 `OFFICIAL_HOSTS`, bot.js docs). | `ApiConfig.apiHost = 'web.nymchat.app'` with a `TODO(verify)` doubting it. | **VERIFIED + doc fix.** Host is correct; removed the TODO and documented the `OFFICIAL_HOSTS` anchor. No code change to the value. |

## Verified correct (no change needed)

- **Sharding** (`shardRelaysByRole` ↔ `_shardRelaysByRole`, relays.js:1699): app-0
  dedicated shard, critical = defaults+dmRelays minus app relay, geo from CSV,
  discovered with canonical-url dedup, 50/shard chunking, blocked-relay set
  (`relay.nosflare.com`, `relay.nostraddress.com`,
  `nostr-server-production.up.railway.app`), empty-fallback `critical-0`. Exact match.
- **Per-shard reconnect backoff** (`_ShardSocket._scheduleReconnect` ↔
  `_reconnectPoolShard`, relays.js:1871-1872): `min(3000·1.7^n, 60000)` with
  jitter `0.7 + random·0.3`. Exact match. (The pool-level
  `_schedulePoolReconnect` uses a different `min(3000·2^n,30000)`/`0.5+r·0.5`
  formula but that's the all-shards-down path, handled by the transport's own
  per-shard reconnect plus the controller-level reconnect, not the per-socket
  loop being ported here.)
- **Direct-mode backoff** (`computeBackoff`): `min(base·1.5^n, cap)` + ±25%
  jitter, matches relays.js:3058 (`min(baseDelay·1.5^attempt, maxDelay)`) and
  the appRelay-forever / others-capped reconnect policy.
- **Outbound frames** (`PoolFrame` / `RelayFrame`): `RELAYS{relays,dmRelays}`,
  `EVENT`, `GEO_EVENT`, `DM_EVENT`, `REQ`, `CLOSE` shapes match.
- **Inbound wrapped frame parse**: `["EVENT",subId,evt,sourceRelay?]` (note the
  proxy's subId-at-index-1 + trailing relay attribution), `OK`, `EOSE`,
  `CLOSED`, `POOL:PING` (keepalive, no PONG), `POOL:STATUS{connected,latency}`.
  Cross-shard dedup cap 10k matches `eventDeduplication` (relays.js:3754).
- **Master critical filters**: the Flutter `NostrService.start` subscription set
  is the lean native subset (channels 20000/23333, reactions `#k`, gift wrap
  `{kinds:[1059],#p:[self]}`, presence 30078 `nym-presence`) — a deliberate
  subset of `_buildCriticalFilters`; the heavy D1-aware filter matrix (zaps,
  vouches, emoji packs, per-kind `since` watermarks) is backend/state-layer and
  out of this transport slice. `since = now − 3600` is consistent with the
  PWA's 1h channel window. No deviation introduced.
- **Proxy actions** (`api_client.dart` ↔ proxy.js): `translate` (POST
  `{text,source='auto',target}`), `unfurl`, `geo-relays`, `geocode`
  (`lat/lng/zoom/lang`), `giphy` (`q`/`trending` + `api_key`), `upload`
  (`server`), `zap-verify`, media `?url=` (+`emoji=1`). All paths/queries/bodies
  match. (`mirror` + `json` proxy actions are unused by this slice and not
  ported — out of scope.)
- **UA gate**: `_shared.js` / per-worker `isNymchatClient` matches
  `/NymchatApp\//i || /\bNYMApp\b/`; `ApiConfig.userAgent = 'NymchatApp/1.0.1'`
  satisfies it, sent on every HTTP request.
- **NIP-98 auth** (`Nip98Auth.build` ↔ `verifyClientAuth` _shared.js:2656 /
  `_signBotAuth` pms.js): kind 27235, tags `domain=nymbot-pm`, `method=POST`,
  `u`, `action`, content `nymbot-pm-auth`, `|now−created_at|≤120`. The optional
  `payload` tag is intentionally omitted (PWA omits it; server only enforces it
  when present). Match.
- **Storage actions** (`storage_sync.dart` ↔ storage.js): `settings-set` /
  `settings-get` (encrypted-to-self category blobs with `__cat`, content-hash
  no-op), `profile-get` (public NDJSON batch ≤100) / `profile-set`, `pm-put` /
  `pm-deposit` / `pm-get` (NDJSON, `X-Has-More` pager, durable-only, session
  dedup with 6000→4000 trim). Bodies/auth/streaming match.
- **Geo relays**: `parseGeoRelaysCsv` (strip scheme + trailing slashes, skip
  header) and `closestGeoRelays` (Haversine sort, take N=5) match relays.js
  `_parseGeoRelaysCsv` / `getClosestRelaysForGeohash`.
- **Nym generator**: adjective/noun wordlists are byte-identical to
  users.js `generateRandomNym`; `fancy` = `adjective_noun#suffix`, `simple` =
  `nymNNNN#suffix` with `1000 + rand(9000)`.
- **Identity boot**: nsec restore / ephemeral session-nsec reuse /
  random-per-session match the PWA's `checkSavedConnection` ephemeral path.

## Deferrals (documented, not fixed)

- **WS handshake User-Agent** — `RelayPoolProxy` opens the
  `/api/relay-pool` socket via `WebSocketChannel.connect` with no custom
  headers, so the WS upgrade request does not carry the `NymchatApp/` UA. The
  relay-pool worker's `isNymchatClient` gate (relay-pool.js:76) does **not
  reject** non-clients — it only adds the app-relay proxy secret for
  authenticated clients (relay-pool.js:1124), so the connection still succeeds
  and only the app-relay proxy-secret optimization is lost. Setting the UA
  natively requires the platform-specific `IOWebSocketChannel.connect(headers:)`
  (dart:io only; not available on the default cross-platform factory). Left as a
  deferral to avoid forking the channel factory per platform inside the
  transport; the HTTP `ApiClient` already sends the UA on every REST call.
- **Settings D1 column = cleartext category vs PWA hashed `_d1Category`** —
  pre-existing `TODO(verify)` in `storage_sync.dart`: the native build keys
  settings rows by the cleartext `nymchat-settings-<section>` category, while the
  PWA uses an opaque `nymchat-<sha256(...)>` column. Both are valid per the
  worker regex and native↔native sync works; PWA↔native cross-read of settings
  does not until the hashed scheme is mirrored. Outside the transport-routing
  scope of this audit; left as-is.

## Files changed

- `lib/services/relay/relay_pool.dart` — added `publishDm` / `publishGeo` to the
  `PoolTransport` interface and concrete plain-publish implementations on
  `RelayPool` (direct mode).
- `lib/services/relay/relay_pool_proxy.dart` — `@override` on `publishDm` /
  `publishGeo` (+ empty-url plain-EVENT fallback for geo); `POOL:RELAY_BAN`
  parse → `PoolRelayBan`; mutable `_permanentBlacklist`; ban handling +
  `permanentBlacklist` getter.
- `lib/services/nostr/nostr_service.dart` — geo channel → `publishGeo`,
  gift-wraps → `publishDm`.
- `lib/services/api/api_config.dart` — resolved host `TODO(verify)` with the
  `OFFICIAL_HOSTS` confirmation.
- `test/network_test.dart` — `_NoopTransport` + `_RecordingTransport` implement
  the new methods; +6 tests (DM_EVENT routing, GEO_EVENT routing + empty
  fallback, POOL:RELAY_BAN blacklisting, and NostrService geo/named/DM routing).
