# Bluetooth Mesh (bitchat-compatible)

Nymchat now speaks the **bitchat** Bluetooth-LE mesh protocol, so a Nymchat
device can discover, chat with, and exchange end-to-end-encrypted direct
messages with nearby devices — including devices running the real bitchat
app — with no internet, relays, or infrastructure. All existing Nostr
functionality (PMs, groups, public channels, geohash bridging, zaps, etc.) is
untouched; the mesh is an additional transport that runs alongside the relays.

Everything is implemented in **pure Dart over published Flutter plugins** (no
hand-written Swift/Kotlin in this repo), so it builds through the Dreamflow /
standard Flutter pipeline unchanged.

## Why pure Dart

bitchat's own clients are native (Swift `CoreBluetooth`, Kotlin BLE). We could
not rely on adding native code to `ios/Runner` / `android/app` because a
Flutter-only build pipeline may regenerate or ignore it. Instead:

- **Radio:** the `bluetooth_low_energy` plugin gives us both GATT roles
  (central + peripheral) from one cross-platform Dart package.
- **Crypto:** the `cryptography` package (already a dependency) provides X25519,
  ChaCha20-Poly1305 (IETF) and Ed25519; `pointycastle` provides SHA-256 / HMAC.

Because the mesh is ultimately just bytes over a GATT characteristic, a correct
Dart re-implementation of bitchat's wire format interoperates with the native
clients byte-for-byte.

## Interop constants (must match bitchat)

| Thing | Value |
|---|---|
| GATT service UUID | `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C` |
| GATT characteristic UUID | `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D` (notify + write) |
| Advertised name | our mesh peerID (also carried in the announce) |
| Packet header (v1) | `version:1 · type:1 · ttl:1 · timestamp:8 (u64 BE ms) · flags:1 · payloadLen:2 (BE)` |
| Flags | `0x01` hasRecipient, `0x02` hasSignature, `0x04` isCompressed, `0x08` hasRoute (v2) |
| Sender / recipient id | 8 bytes each; broadcast = `FF*8` |
| Message types | `0x01` announce, `0x02` message, `0x03` leave, `0x10` noiseHandshake, `0x11` noiseEncrypted, `0x20` fragment |
| Default TTL | 7 |
| Padding | PKCS#7 to 256/512/1024/2048 (strict — all pad bytes equal the length) |
| Compression | raw DEFLATE (decode-side only; we never compress on send) |
| Fragment threshold / size | split > 512 B; ≤ 469 B data per fragment |
| Noise suite | `Noise_XX_25519_ChaChaPoly_SHA256`, empty prologue |
| Noise transport frame | `<4-byte BE counter><ciphertext‖tag>`, 1024-entry replay window |
| peerID | first 16 hex chars of `SHA-256(noiseStaticPublicKey)` |
| fingerprint | full `SHA-256(noiseStaticPublicKey)` hex (64 chars) |

The single most subtle detail: bitchat's Noise backend (southernstorm/Noise-Java)
lays the nonce counter into ChaCha state words 14–15 little-endian, which is
exactly the IETF 12-byte nonce `[0,0,0,0] + LE64(n)`. Our `NoiseCrypto.nonce12`
produces the same bytes, so the AEAD streams match.

## Architecture / layering

```
lib/services/mesh/
  protocol/            deterministic wire codecs (unit-tested)
    bitchat_packet.dart      BinaryProtocol encode/decode (v1/v2, flags, padding)
    message_padding.dart     PKCS#7 privacy padding
    fragment_payload.dart    fragment header codec
    identity_announcement.dart  announce TLV (nickname + noise/signing keys)
    noise_payload.dart       inner PM TLV + delivery/read receipts
    bitchat_message.dart     public broadcast message codec
    mesh_message_type.dart   type + NoisePayloadType constants
  noise/               Noise XX (unit-tested, self-interop)
    noise_crypto.dart        X25519 / AEAD / HKDF / SHA-256 primitives
    noise_handshake.dart     CipherState / SymmetricState / HandshakeState (XX)
    noise_session.dart       session + 4-byte-nonce transport framing + replay window
    noise_session_manager.dart  per-peer sessions, collision tie-break, peerID binding
    noise_identity.dart      persistent static + signing keys, peerID/fingerprint
  transport/
    mesh_transport.dart      abstract radio interface (fake-able for tests)
    ble_mesh_transport.dart  dual-role BLE over bluetooth_low_energy
  mesh_service.dart          orchestrator: dedup, TTL relay, fragmentation,
                             announce, PM/receipt routing, high-level events
  dedup.dart · fragmentation.dart · mesh_peer.dart · mesh_constants.dart

lib/features/mesh/
  mesh_controller.dart   Riverpod lifecycle + event → UI-state bridge
  mesh_screen.dart       Nearby feed, peers list, encrypted DM threads
```

The app layer (`app.dart`) keeps `meshControllerProvider` alive so the radio
starts at launch when the `meshEnabled` setting is on; Settings → **Bluetooth
Mesh** opens the screen and toggles the flag.

## How a message flows

- **Announce (0x01):** every ~30 s and on each new link we broadcast a
  signed `IdentityAnnouncement` (nickname + Noise static key + Ed25519 signing
  key). Receivers verify the signature and that the peerID hashes to the Noise
  key before marking a peer *verified*.
- **Public chat (0x02):** `BitchatMessage` broadcast, flooded with TTL, shown in
  the Nearby feed.
- **Private chat (0x11):** first use triggers a Noise `XX` handshake (0x10);
  the plaintext is queued and flushed on establishment. Content > 255 bytes is
  chunked (bitchat's 1-byte TLV cap). Delivery/read receipts flow back over the
  same session.
- **Relay:** non-directed packets with `ttl > 1` are re-broadcast after 10–220 ms
  of jitter; an LRU/TTL seen-set (1000 / 5 min) stops flood loops.
- **Fragmentation:** packets > 512 B are split and reassembled transparently.

## Verification status

Verified in CI here (no radios required — these layers are deterministic):

- 24 mesh unit/integration tests, `flutter analyze` clean.
- Full Noise `XX` handshake self-interop (32/96/64-byte messages), bidirectional
  transport encryption, replay + tamper rejection.
- Every wire codec round-trips (packet, padding, fragment, announce TLV, PM TLV,
  public message).
- End-to-end over an in-memory radio bus: peer discovery via signed announce,
  public delivery, full handshake + PM + delivery ack, and chunked long-message
  reassembly.

Requires on-device validation (this container has no Bluetooth radios):

- Real BLE central+peripheral behaviour and MTU negotiation on iOS/Android.
- Byte-level interop against the shipping bitchat app (the wire format is matched
  to bitchat's source, but only a live cross-device test confirms it end to end).
- Background execution limits and power/duty-cycling tuning.

## Identity & profile parity (avatars, banners, cosmetics)

The mesh shows peers with their **real Nymchat identity**, not just a nickname:

1. **Canonical rendering.** The Nearby feed and mesh DM threads build real
   `Message` objects and render through the app's own `MessageGroup`/
   `MessageRow` — so mesh chat is visually identical to a channel/PM (same
   bubbles, avatars, author colours, grouping, emoji/mention formatting,
   delivery receipts, IRC/bubbles layout and theme). All chrome uses `NymSvgIcon`.

2. **Signed Nostr link (cached avatars).** A peer can advertise a
   Nymchat-only announcement TLV (`0x50`) binding its mesh Noise key to a Nostr
   pubkey with a BIP340 schnorr signature (`NostrLink`). Once verified, the app
   reuses the avatar/banner it already cached for that pubkey — so a peer you've
   seen on Nostr shows their real picture with zero internet. bitchat ignores
   the TLV, so interop is unaffected. Devices signing remotely (NIP-46) simply
   omit the link.

3. **On-demand transfer (never-seen peers).** For a peer whose avatar isn't
   cached, the app requests it over the mesh — Nymchat-only packet types
   `0x50`/`0x51` (bitchat ignores unknown types) carry a `MeshProfile` TLV
   (nickname, npub, avatar/banner bytes) that rides the normal fragmentation
   path. Received avatars are size-capped, cached to disk, and shown. So even a
   brand-new peer renders their real avatar offline.

## Media, files, emoji & GIFs over the mesh

Attachments ride the mesh with no server in the loop:

1. **Wire format.** A file is encoded as a `BitchatFilePacket` — a TLV with
   name (`0x01`), size (`0x02`, u64), mime (`0x03`) and the content chunked into
   `0x04` CONTENT TLVs (≤65535 each, rejoined on decode; unknown TLVs skipped).
   A **1:1 DM attachment** is sealed inside a Noise-encrypted packet with the
   `fileTransfer` (`0x20`) payload discriminator (same session as text DMs); a
   **public/channel attachment** rides a `FILE_TRANSFER` (`0x22`) packet. Both
   go through the normal fragmentation/reassembly path, so arbitrarily large
   media survive the BLE MTU.

2. **Sending.** The mesh composer reuses the app's own image/video picker
   (`image_picker`) and file picker (`file_picker`), 10 MB-capped to keep
   fragmentation bounded. DMs call `sendFileToPeer` (encrypted); Nearby/group
   sends call `sendFileBroadcast`.

3. **Rendering.** Received bytes are written under `mesh_files/` and shown
   inline through the **canonical** `MessageRow`: a new local-attachment body
   (`Message.localMediaPath`) renders an image inline (tappable → fullscreen,
   pinch-zoom, share) or a tappable file card — keeping every other row chrome
   (avatar, author, grouping, bubble, meta, verified badge) identical to a
   normal message.

4. **Emoji & GIFs offline.** The mesh composer keeps its emoji and GIF buttons,
   but over the mesh they offer only what is **already cached locally** — custom
   emoji rasters from `InlineNetworkImage`'s in-memory decode cache, favourite
   GIFs from `flutter_cache_manager`'s disk cache (the exact caches the display
   path populates). Picking one ships those cached bytes as a mesh file, so the
   recipient renders it inline like any other image — no internet required.


## Possible next steps

- Unify mesh DMs/threads into the main conversation store (currently a dedicated
  mesh surface) so a contact reachable by both Nostr and mesh shares one thread.
- Source-routed (v2) directed sends and store-and-forward for offline peers.
- Foreground-service / background tuning for longer-lived meshing.
