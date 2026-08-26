```
                                            ##\                  ##\     
                                            ## |                 ## |    
#######\  ##\   ##\ ######\####\   #######\ #######\   ######\ ######\   
##  __##\ ## |  ## |##  _##  _##\ ##  _____|##  __##\  \____##\\_##  _|  
## |  ## |## |  ## |## / ## / ## |## /      ## |  ## | ####### | ## |    
## |  ## |## |  ## |## | ## | ## |## |      ## |  ## |##  __## | ## |##\ 
## |  ## |\####### |## | ## | ## |\#######\ ## |  ## |\####### | \####  |
\__|  \__| \____## |\__| \__| \__| \_______|\__|  \__| \_______|  \____/ 
          ##\   ## |                                                     
          \######  |                                                     
           \______/                                                      

```

# Nymchat - Geohash Mesh Chat

A feature-rich, ephemeral geohash and bluetooth mesh chat client built on the [Nostr](https://github.com/nostr-protocol/nostr) protocol and bridged with [Bitchat](https://bitchat.free) for pseudonymous, temporary messaging. Learn more in the [knowledge base](https://nymchat.app/docs/).

## Overview

Nymchat, also known as NYM (Nostr Ynstant Messenger), is a Progressive Web App (PWA) and native iOS/Android chat messenger. It uses [Nostr](https://github.com/nostr-protocol/nostr) ephemeral events for channels (kind 20000 for geohash channels and kind 23333 for non-geohash, named channels) and [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) gift-wrapped events (kind 1059) for private messages and group chats. No registration is required. Pick a nym and start chatting, or log in with an existing Nostr account if you want a persistent identity.

The web app is served as static files plus a set of Cloudflare Pages Functions under `functions/api/`. The Functions act as a privacy proxy for relays and media, generate link previews, run the Nymbot, and store the flair shop and encrypted settings.

![Nymchat Screenshot](https://nymchat.app/images/nymchat-app.png)

## Features

### Identity
- **Ephemeral Identity**: Generate a temporary keypair and pseudonym per session.
- **Auto-Ephemeral Mode**: Auto-start an ephemeral session without a welcome screen.
- **Login with a Nostr Account**: Use a persistent identity via a NIP-07 browser extension (Alby, nos2x, and similar), a NIP-46 remote signer, or by entering an nsec.
- **Optional Identity Encryption**: Encrypt your saved identity's (nsec) private key on a device so it cannot be read from local storage without unlocking. Group chats' ephemeral secret keys are encrypted at rest under the same vault key too. You pick the unlock factor per device: a password, a PIN, a passkey, or a biometric (Face/Touch ID, Windows Hello, Android biometric, or a hardware security key). Passkey and biometric unlock use WebAuthn with the PRF extension to derive the key; password and PIN use PBKDF2. The key stays in memory only for the session and the plaintext key is never written to disk while encryption is on. This is a per-device setting and is not synced, because the unlock factor and the stored key are local to each device, so you enable it separately on each device. After you enable it, the app confirms an unlock right away so you are not locked out if an authenticator turns out not to support PRF. Only a non-sensitive on/off preference syncs across devices, so a new device can offer to set it up too. No password, salt, or credential is ever synced.

### Channels
- **Geohash Channels**: Location-based channels using geohash encoding (kind 20000).
- **Non-Geohash Channels**: Named topic channels (kind 23333).
- **Geohash Explorer**: Browse location channels on an interactive globe.
- **Channel Sharing**: Generate shareable URLs for channels.
- **Channel Favoriting**: Favorite frequently used channels to the top of the list.
- **Proximity Sorting**: Sort geohash channels by distance from your location.

### Messaging
- **Private Messages**: End-to-end encrypted 1:1 PMs using [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) (kind 14 rumor) wrapped in NIP-59 gift wraps.
- **Private Group Chats**: End-to-end encrypted multi-party group chats via [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) and [NIP-59](https://github.com/nostr-protocol/nips/blob/master/59.md) with rotating ephemeral recipient keys and automatic post-compromise recovery. Each message is individually gift-wrapped per member using one-time pubkeys so relays cannot correlate group membership, timing, or real identities. Groups are capped at 100 members to keep the per-message fan-out bounded.
- **Group History Sharing**: Owner-controlled option ("Share history with new members", off by default) to give newly added members the group's recent chat history. The member who adds someone forwards up to the last 50 messages in a single encrypted blob to the new member only; forwarded messages are marked as unverified since the original authors' signatures cannot be re-checked.
- **Group Key Resync**: A client returning after a multi-day offline gap automatically re-exchanges current ephemeral keys with each group (rate-limited), so missed key rotations that expired off relays can't leave members unable to decrypt each other.
- **Group Invite Links**: Optional shareable invite links for group chats. Joining via link is off by default; the owner turns on "Allow joining via invite link" from the group context menu, after which the link appears there for the owner (and for members too when "allow members to add others" is on). A brand-new user who opens a link is prompted to pick a nym or log in first, then the join resumes automatically. The owner can "Reset Invite Link" to revoke every link shared so far.
- **Quantum-Resistant Encryption**: Hybrid post-quantum key agreement for PMs, group chats and synced settings between Nymchat users. Automatic, with no setting. Every message's key exchange combines the standard NIP-44 secp256k1 ECDH with [ML-KEM-768](https://csrc.nist.gov/pubs/fips/203/final) (FIPS 203), so both would have to be broken to read it. This defeats "harvest now, decrypt later" — traffic recorded today cannot be decrypted by a future quantum computer. Bitchat users and other Nostr clients are unaffected and keep receiving standard NIP-17.
- **Forward Secrecy and Disappearing Messages**: Optional per-message forward secrecy for DMs and a configurable message time-to-live.
- **Read Receipts and Typing Indicators**: Optional, with per-scope control (everyone, friends only, or off).
- **Rich Text**: Markdown for bold, italic, strikethrough, code blocks, and quotes.
- **Message Threads**: Reply threads in channels, PMs, and group chats. Clicking a message (or its reply-count row) swaps the current view to the thread. On by default and can be disabled in Settings, which restores the classic flat view. Channel replies carry a NIP-10 marked `['e', rootId, '', 'root']` tag so other clients still see a normal message; PM/group replies carry a `['nymthread', rootNymMessageId]` tag inside the encrypted rumor.
- **Message Reactions**: React to messages with emoji ([NIP-25](https://github.com/nostr-protocol/nips/blob/master/25.md)).
- **Custom Emoji**: NIP-30 custom emoji pack discovery and rendering.
- **Polls**: Create and vote on polls in channels.
- **Message Translation**: Translate received messages on demand.
- **Auto-Reply**: Set an away message with the `/brb` command.
- **Image and Video Sharing**: Upload and share images or video.
- **Peer-to-Peer File Sharing**: Send files directly over WebRTC data channels, with WebTorrent for larger transfers.

### Bluetooth Mesh (Android, iOS, and Chromium browsers)
- **Offline Messaging**: A Bluetooth LE mesh carries public channels and private messages with no internet, cell service, or infrastructure. Nearby devices link directly and relay store-and-forward, so a message reaches peers beyond radio range by hopping through the devices between.
- **Bitchat Bridged**: Wire-compatible with Bitchat, so both apps share one mesh. Noise XX handshakes give per-peer encrypted sessions; announces carry a `nostrLink` so a mesh peer can be matched to its real Nostr identity.
- **Automatic Transport**: Online sends take the internet route and fall back to Bluetooth when it is unavailable. Peers reachable only over the radio stay on the mesh either way.
- **Ghost Mode**: An opt-in "anonymity mode" for the mesh. Every identifier an announce carries — the Noise static key (which the peer ID and fingerprint derive from), the Ed25519 signing key, the advertised Bluetooth name, the nickname, and the `nostrLink` — is replaced with a throwaway value and rotated together on a jittered ~15 minute epoch. The `nostrLink` stays real but ephemeral, so peers can still reach the device without anything resolving to the user's npub. Avatar and banner sharing is refused while active, since a repeated image relinks two epochs faster than any key. Retired identities stay decryptable for up to 8 rotations so late replies still arrive, and a conversation started while ghosted is pinned to the mesh for good.

- **Web Bluetooth**: The PWA joins the same mesh from a laptop or desktop on a Chromium browser (Chrome, Edge, Opera, Brave). The wire format is identical to the mobile apps and Bitchat — the same packets, Noise XX sessions, padding, fragmentation and Ghost Mode. The mesh controls are hidden entirely on browsers that cannot run it (Safari, Firefox).

> A browser can only take the Bluetooth central role: it cannot advertise itself, so it joins as a leaf rather than a full peer. You pick each nearby device once through the browser's own device chooser, after which it reconnects on its own; the phones you are linked to relay for you. Two browsers cannot link to each other directly.

> Ghost Mode makes a device much harder to follow across places and sessions. It is not fully anonymous: the Bluetooth hardware address is controlled by the operating system rather than the app, and timing and social patterns remain correlatable.

### Voice and Video Calls
- **1:1 and Group Calls**: Audio and video calling for private messages and group chats. Call signaling is exchanged over NIP-17 gift wraps and media flows peer-to-peer over WebRTC.

### Lightning Integration
- **Lightning Zaps**: Send Lightning payments to messages and user profiles ([NIP-57](https://github.com/nostr-protocol/nips/blob/master/57.md)).
- **Lightning Addresses**: Set your Lightning address to receive zaps.
- **Flair Shop**: Buy cosmetic message styles, nickname flair, and a supporter badge with Bitcoin over Lightning. Items can be gifted or transferred and recovered with a redeem code.

### Moderation & Privacy
- **User Blocking**: Block unwanted users and channels.
- **Keyword Filtering**: Block messages containing specific keywords or phrases.
- **Flood Protection**: Automatic spam prevention.
- **Image Blur**: Option to blur images from other users until clicked.
- **Group Roles**: Owners and moderators can kick, ban, unban, promote and demote moderators, and transfer ownership. Role checks run both when sending and on every received moderation event.
- **Panic Wipe**: Press and hold the "Your Nym" section for 2 seconds to immediately destroy all local data on the device. There is no confirmation, so it can be triggered fast. It encrypts every local storage value with a random one-time key that is then discarded, overwrites the values with junk, clears localStorage and sessionStorage, overwrites and deletes all IndexedDB databases, clears the caches, unregisters the service worker, and reloads to a fresh first-run state. A short animation shows the progress. A normal single tap still opens the nick editor. If you also use Identity Encryption, any bytes that survive deletion are ciphertext under a key nobody holds.

### Customization
- **Multiple Themes**: Bitchat (Multicolor), Matrix Green, Amber Terminal, Cyberpunk, Hacker Blue, and Ghost (B&W).
- **Chat Layout**: IRC-style or bubble layout, with adjustable text size.
- **Wallpapers**: Built-in patterns or a custom image.
- **Notification Sounds**: Classic Beep, ICQ Uh-Oh, MSN Alert, or Silent.
- **Time Format**: 12-hour or 24-hour display.
- **Auto-Scroll**: Toggle automatic message scrolling.

## Protocol Implementation

### Channels
- Geohash channels: event `kind 20000` with a `['g', geohash]` tag.
- Named (non-geohash) channels: event `kind 23333` with a `['d', channel]` tag.
- Tag `['n', nym]` for the nickname.
- Reactions to channel messages carry a `['k', originalKind]` tag of `20000` or `23333` so the reaction is categorized to the right channel type.

### Private Messages & Group Chats (NIP-17)
- NIP-17 `kind 14` rumor (message content and metadata) sealed inside NIP-59 `kind 1059` gift wraps.
- Each gift wrap uses a one-time ephemeral sender key. The `created_at` timestamp is randomized by up to two hours using a cryptographically secure RNG so relays cannot correlate senders, recipients, or timing.
- Group chats send one gift wrap per member, each individually encrypted to that member's public key.

#### Hybrid Post-Quantum Encryption

NIP-44 v2's symmetric layer (ChaCha20 + HMAC-SHA256 + HKDF-SHA256) has adequate post-quantum margins, but the secp256k1 ECDH that produces its 32-byte conversation key does not — Shor's algorithm solves the elliptic-curve discrete logarithm outright, which would expose every message ever encrypted under a recovered key. Nymchat therefore leaves the NIP-44 payload format untouched and replaces only that derivation.

- **Hybrid key agreement**: the conversation key becomes `HKDF-Extract(salt = "nymchat-pq-v1", ecdh_x || mlkem_shared_secret || mlkem_ciphertext || recipient_mlkem_pubkey || sender_pubkey || recipient_pubkey)`. Folding the KEM ciphertext and both public keys into the input — rather than just concatenating the two shared secrets — makes the combiner transcript-binding in the style of X-Wing and Signal's PQXDH, which blocks KEM re-encapsulation attacks. Security is `max(classical, PQ)`: as strong as today's NIP-44 even if ML-KEM is later broken, and quantum-safe if secp256k1 is.
- **Wire format**: `pq1.<base64url(kem_ciphertext)>.<standard NIP-44 v2 payload>`, used identically at both the seal (`kind 13`) and gift wrap (`kind 1059`) layers. The ciphertext rides in the content rather than a tag, so the event's tag surface stays byte-identical to vanilla NIP-17 and relay filters are unaffected.
- **Capability announcement**: every Nymchat client publishes a signed, replaceable `kind 30078` event tagged `nym-pq` with a NIP-40 expiration, carrying an ML-KEM-768 public key only when post-quantum is possible and enabled. Its *presence* is unforgeable proof the pubkey runs Nymchat; the key's presence separately signals post-quantum. Holding a peer's valid announcement *is* the negotiation — there is no in-band capability exchange and therefore no downgrade surface.
- **Bitchat wrap suppression**: the Bitchat-format wrap exists to reach a peer who might be running Bitchat. A live announcement proves they are not, so it is dropped and only the post-quantum message is sent. A peer with **no** announcement receives both formats exactly as before, so no send can become undeliverable on an inference — which is why this keys on the signed announcement rather than inferring the client from public channel activity, where being wrong means sending someone a message their app cannot open, with no error and no retry. This is automatic and has no setting.
- **Deterministic keys**: the ML-KEM keypair derives from the `nsec` via HKDF, so there is nothing new to back up and every device sharing an identity derives the same key — which is what makes a single replaceable announcement per identity correct.
- **Group chats**: because fan-out already builds an independent wrap per member, a group can mix post-quantum and classical recipients with no protocol change. The classical leg still encrypts to the member's rotating ephemeral pubkey (preserving the metadata protection below) while the KEM leg encapsulates to their identity key, so no new per-message tags are added. A group message is only reported as quantum-resistant when *every* member received a post-quantum wrap.
- **Self-addressed copies**: on an nsec login, the copy of every message kept for your own other devices is post-quantum too, as is the D1 archive behind it — otherwise the archive would be the weakest link, readable by anyone who breaks secp256k1 regardless of how the outbound copy was sealed. The same applies to synced settings, which travel as self-addressed gift wraps of the same shape and carry the conversation list, the group ephemeral keys and the history categories. A settings category close to the 65000-byte relay frame limit falls back to NIP-44 rather than going unpublished, since losing the sync would be a worse trade than losing the post-quantum layer.
- **Fallback**: a post-quantum wrap *replaces* the classical one rather than accompanying it — sending both would hand an attacker the weaker copy. Peers without an announcement (Bitchat, other Nostr clients, older Nymchat builds) receive standard NIP-17, unchanged.
- **Scope**: this protects **confidentiality, not authentication**. Event signatures are still secp256k1/Schnorr, so an adversary who already possessed a cryptographically relevant quantum computer could forge one. What the hybrid exchange defeats is harvest-now-decrypt-later, which is the threat that exists today. This is the same posture as Signal's PQXDH.
- **Requirements**: sending and receiving have different requirements, and the difference is what browser-extension (NIP-07) and remote-signer (NIP-46) logins can do. A NIP-17 message is a *seal* under the identity key inside a *wrap* under a throwaway key the client generates on every send. Only the seal needs the signer, so those logins hybridize the **wrap** — which is the layer that matters, because the wrap is what a recorder stores and reaching the seal means breaking it first. **Receiving** is another matter: the ML-KEM keypair derives from the nsec and opening a message means decapsulating with its secret half, which a signer will not do. So a signer login sends post-quantum, receives classical, and announces no key of its own.
- **Copies addressed to yourself are the exception**: self-wraps, the D1 archive and synced settings are addressed to *us*, so encrypting them post-quantum from a login that cannot decapsulate would lock that device out of its own history. The sharp edge is that a second device holding the nsec may already have announced a key for the same npub — so the key exists and looks usable. The self-key accessor asks the receive-side question rather than the key-exists one.
- **Migration**: unconditional — there is no user setting, only a read-only status line under Privacy & Security. It is all-or-nothing per identity, since once a key is announced other clients encrypt to it, so a second device on the same npub running an older build stops receiving messages until it updates. That device publishes no announcement and is therefore undetectable, so upgrades show a one-time informational notice. `nym_pq_mode` remains an undocumented storage escape hatch, never written by the app, so a field bug can be defused without an emergency release.
- **Cost**: a post-quantum wrap is ~3.6 KB larger per recipient than a classical one, so a 100-member group send grows by roughly 360 KB.

The implementation is verified against the official NIST ACVP vectors for ML-KEM-768, and the PWA and Flutter apps are held to a shared, committed test fixture so the two can never silently diverge.

#### Enhanced Group Chat Security
Nymchat group chats go beyond standard NIP-17 with rotating ephemeral recipient keys to reduce timing-based metadata attacks.

- **Timing-Attack Resistance**: In standard NIP-17, an observer watching relay traffic can see N gift wraps appear at once to N different pubkeys and infer group membership. Nymchat reduces this by rotating recipient pubkeys on every message. Each member generates a fresh ephemeral keypair when they send, advertises the new public key inside the encrypted rumor (`ephemeral_pk` tag), and all future messages to that member are addressed to their ephemeral key instead of their real pubkey. To an outside observer, every message appears to go to and from never-before-seen one-time pubkeys with no link to real identities.
- **Post-Compromise Recovery**: If a device is compromised, the user simply sends a new message. The fresh random ephemeral keypair advertised inside the encrypted rumor (`ephemeral_pk` tag) automatically replaces the old key for all group members, with no out-of-band resync needed.

### Reactions & Zaps
- Reaction events `kind 7` (NIP-25) with a `['k', originalKind]` tag for categorization.
- Lightning zaps `kind 9735` (NIP-57) with invoice generation and payment tracking.

### Calls
- Call setup and signaling are carried inside NIP-17 gift wraps. Audio and video media then flow directly between peers over WebRTC.

## Available Commands

**Basic Commands:**
- `/help` - Show available commands
- `/join <channel>` - Join a channel (e.g. /join #9q5)
- `/j` - Shortcut for /join
- `/pm <nym>` - Open a 1:1 private message (e.g. /pm nym or /pm nym#xxxx)
- `/nick <nym>` - Change your nym
- `/who` - List online nyms in the current channel
- `/w` - Shortcut for /who
- `/clear` - Clear chat messages
- `/leave` - Leave the current channel or group chat
- `/quit` - Disconnect from Nymchat

**Group Chat Commands:**
- `/group @user1 @user2 [name]` - Create a new private group
- `/invite @nym` - In a channel: invite a user to the channel. In a group chat: add a new member
- `/addmember @nym` - Add a member to the current group chat
- `/groupinfo` - Show members of the current group
- `/leave` - Leave and remove yourself from the current group chat

**Group Moderation Commands:**
- `/kick @nym` - Remove a member from the current group
- `/ban @nym` - Ban a member from the current group
- `/unban @nym` - Lift a ban
- `/addmod @nym` - Promote a member to moderator
- `/removemod @nym` - Demote a moderator
- `/transferowner @nym` - Transfer ownership of the group

**Moderation Commands:**
- `/block [nym|#channel]` - Block a user or channel
- `/unblock <nym|#channel>` - Unblock a user or channel

**Social Commands:**
- `/slap <nym>` - Slap someone with a trout
- `/hug <nym>` - Give a warm hug
- `/me <action>` - Action message (e.g. /me is coding)
- `/shrug` - Send a shrug
- `/brb <message>` - Set an away message
- `/back` - Clear the away message
- `/poll` - Create a poll

**Formatting Commands:**
- `/bold <text>` or `/b` - Send bold text
- `/italic <text>` or `/i` - Send italic text
- `/strike <text>` or `/s` - Send strikethrough text
- `/code <text>` or `/c` - Send a code block
- `/quote <text>` or `/q` - Send quoted text

**Lightning Commands:**
- `/zap <nym>` - Send a Lightning zap to a user profile

**Channel Commands:**
- `/share` - Share the current channel URL

## Nymbot

Nymbot is a built-in AI-powered chat bot that responds to `?` commands in any channel. You can also mention **@Nymbot** in a message, or quote-reply to a Nymbot response to continue a conversation.

You can also have a private, end-to-end encrypted 1:1 chat with Nymbot. Private replies are a paid feature funded with credits you buy over Lightning. Type `?balance` to see your credit balance, `?buy` to purchase more, and `?gift @nym` to gift credits to someone else.

The private chat has two tiers. **Standard** replies are auto-routed to the best model for each task and spend standard credits (10 sats each). **Pro** lets you pin every reply to a specific frontier model — Claude Fable 5, Claude Opus 5, Claude Sonnet 5, Claude Haiku 4.5, GPT-5.6 Sol, GPT-5.4 mini, Gemini 3.1 Pro, Gemini 3.6 Flash, Grok 4.6, Kimi K3, Qwen 3.5, or MiniMax M3, and paid with separate Pro credits (100 sats each; replies cost a per-model base of 1–2 credits and scale with reply length, up to a per-model maximum — the maximum is reserved per message and only the actual cost is charged). Pick a model with `?model <name>`, switch back with `?model off`, and buy Pro credits via the Standard/Pro switch in the `?buy` modal.

When a reasoning model shows its chain of thought (the standard tier's reasoning route, or a Pro model that exposes it), the private chat shows it as a collapsed "💭 Reasoning" section above the reply that you can tap to read.

The private chat can also generate media. `?image <description>` sends back a generated picture and `?speak <text>` sends back a spoken voice clip, both charged per generation rather than per reply length: 5 standard credits for an image and 3 for a voice clip. With a Pro model selected you can pick a frontier generator with `?image --model <name> <description>` — Nano Banana Pro, Nano Banana 2, Imagen 4, FLUX 2 Max, FLUX 2 Pro, Seedream 5 Pro, GPT Image 2, Grok Imagine, or Recraft v4 Pro — for 2–3 Pro credits depending on the generator, and `?image models` lists them with prices for free. You can also send Nymbot a picture: when the model you're on can see (all the Claude, GPT, Gemini, Grok and Kimi Pro models, or the creative and translation routes on standard), it receives the actual image and can describe it or answer questions about it.

Pro can also work inside one of your git repositories, Claude Code-style. Type `?git` to connect a provider, choosing either GitHub, GitLab, or Gitea/Forgejo (including Codeberg and self-hosted instances), and pasting a scoped personal access token and selecting a repo and branch. Repo messages then run as a small agent: the model lists, reads, and searches your actual files, and with `?git writes on` it can commit files, create branches, and open pull/merge requests. Repo tasks use up to 6 model calls per message, each billed at the selected model's Pro credit price (only calls actually used are charged). The access token is stored only on your device (Panic Mode wipes it), travels to the Nymbot worker per request, and is never stored server-side or published to relays.

### Bot Commands

**AI & Knowledge:**
- `?ask <question>` - Ask the AI anything (also triggered via `@Nymbot <question>`)
- `?define <word>` - Look up a word's definition, part of speech, and example usage
- `?translate <text>` - Translate text (auto-detects language; English translates to Spanish)
- `?news` - Latest breaking news headlines

**Games & Fun:**
- `?trivia [category]` - Trivia questions (categories: general, history, science, crypto, nostr)
- `?joke` - Random tech or Bitcoin themed joke
- `?riddle` - Random riddle (reply to answer)
- `?wordplay [mode]` - Word games (modes: wordle, anagram, scramble; reply to guess)
- `?roll [NdN]` - Roll dice (e.g. `?roll 2d6`; default 1d6)
- `?flip` - Flip a coin
- `?8ball <question>` - Magic 8-ball
- `?pick <option1> <option2> ...` - Randomly pick from a list of options

**Utility:**
- `?math <expression>` - Calculate a math expression
- `?units <value> <from> to <to>` - Unit converter (e.g. `?units 10 km to mi`)
- `?time` - Current UTC time and Unix timestamp
- `?btc` - Current Bitcoin price

**Channel Activity:**
- `?who` - Who is active in the current channel
- `?summarize` - Summary of the current channel discussion
- `?top` - Top channels by recent message activity
- `?last [N]` - Last N messages across channels (default 10, max 25)
- `?seen <nym|@mention|pubkey>` - Where and when a nym was last seen

**Credits (private Nymbot chat):**
- `?help` - Free local guide to standard premium vs Pro, the git repo integration, and all commands
- `?balance` - Show your standard and Pro credit balances
- `?buy` - Buy credits over Lightning (Standard/Pro switch)
- `?model [name|off]` - Pick a Pro frontier model for replies, or switch back to standard routing
- `?git` - Connect a git repo (GitHub/GitLab/Gitea) so Pro replies can read the code and optionally commit, branch, and open PRs
- `?gift @nym` - Gift credits to another user
- `?transfer @nym` - Transfer your credits (standard and Pro) to another user

**Info:**
- `?help` - List all available bot commands
- `?about` - About Nymchat
- `?nostr` - Random Nostr protocol tips

### Conversational AI

Nymbot is context-aware. When you use `?ask` or `?summarize`, the bot receives the recent channel messages and active user list, so it can answer questions about the current conversation, reference what users said, and summarize discussions.

Quote-reply to any Nymbot response to continue the conversation. The bot carries context from the reply chain (up to six messages of history). You can also quote any message and mention `@Nymbot` to ask the AI about it.

## Mobile App (iOS & Android)

Nymchat is also available as an open source Flutter app for iOS and Android. The source code is in the [`android-ios-app/`](android-ios-app/) directory. The Android APK can be downloaded directly from the [Zapstore](https://zapstore.dev/apps/com.nym.bar).

## Verify Build

The deployed web app is built deterministically, so anyone can confirm that the code running at the live site is exactly what is published in this repository.

How it works:

- `npm run build` emits `dist/build-manifest.json` containing the source `commit`, a `sha256-` hash of every served HTML/JS/CSS asset, and a single `bundleHash` over that asset set, plus `dist/bundle-hash.txt` holding just the `bundleHash`. The output depends only on source content (`builtAt` is the commit time, not the build time), so reproducible rebuilds of the same commit are byte-identical.
- The [Build provenance](../../actions/workflows/build-provenance.yml) GitHub Action independently rebuilds each commit, prints the `bundleHash` to the run summary, and signs build-provenance attestations for `bundle-hash.txt` and the manifest.
- The app's **About** dialog re-fetches each running asset, hashes it in the browser with the Web Crypto API, and compares against the manifest. It then recomputes the `bundleHash` from those locally computed hashes — not from the manifest's claims — and looks it up in this repository's signed attestations via the GitHub API, so a deployment cannot simply vouch for itself with its own manifest. It shows `✓ Verified official app (n/n)` only when every asset matches, the recomputed `bundleHash` is attested by this repository, **and** the page is served from the official domain; a byte-identical mirror on another domain shows `⚠ Verified build · not the official app` (a warning the mirror cannot remove without failing verification), a deployment serving modified files or a self-made manifest shows `✗ Mismatch` or `✗ Unofficial build`, and `⚠ Provenance unreachable` appears when the GitHub API cannot be reached.

To verify a running build yourself:

```sh
git clone https://github.com/Spl0itable/NYM
cd NYM
git checkout <commit shown in the About dialog>
npm ci
npm run build   # prints "Build hash: <bundleHash>"
```

The printed `bundleHash` should match both the hash shown in the app's About dialog and the one in that commit's Build provenance run summary. You can also verify the signed attestation with the GitHub CLI:

```sh
gh attestation verify dist/build-manifest.json --repo Spl0itable/NYM
```

### Android

The Android app cannot check itself the way the web app does. What runs on the device is AOT-compiled machine code, not the Dart in [`android-ios-app/`](android-ios-app/), and no computation available on the device relates one to the other.

What Android *does* expose is the installed APK itself, at `ApplicationInfo.sourceDir`. That makes the same shape of proof available — hash the artifact locally, compare against a hash the developer published and signed — and the published half already exists: the [Zapstore listing](https://zapstore.dev/apps/com.nym.bar). Publishing with `zsp` emits a NIP-82 **kind 3063 Software Asset** event per release, signed with the publisher's Nostr key, carrying the APK's SHA-256 in its `x` tag and the signing certificate's SHA-256 in `apk_certificate_hash`.

So the app's **About** dialog reads that event rather than a manifest of its own:

- It hashes the APK it is running from, opens a one-shot connection to `wss://relay.zapstore.dev`, asks for the kind-3063 assets for `com.nym.bar`, and keeps only those whose Schnorr signature checks out against the **pinned publisher pubkey**. That pin is load-bearing: the relay is public, so anyone can publish an event claiming any hash, and an unpinned lookup would accept whatever was written last.
- It compares the local hash against every published asset — a release built with `--split-per-abi` publishes one per ABI and any of them is a legitimate install. The hash decides, not the version string: a publisher's `version` tag is what they typed, while the hash is what the bytes are.
- It shows **Verified official build** on a match, and **Unrecognised build** only when the publisher *did* release this version and the bytes differ. A version with no published asset yet — the ordinary case for a build newer than the listing — reads as **No published hash yet**, not as a fault.
- The panel prints the APK hash and the signing certificate hash so a reader can repeat both halves off-device.

There is nothing extra to publish: releasing through Zapstore is what arms the check. To verify a release yourself, download the published APK, run `sha256sum` on it, and compare against the `x` tag of that version's asset event on `relay.zapstore.dev`; `keytool -printcert -jarfile <apk>` gives the certificate hash the same event carries.

**Google Play installs cannot be checked this way, and that is not a failure.** Play App Signing re-signs the upload with Google's key and generates a separate set of split APKs for each device, so the bytes installed from Play are not the file the developer built and their hash matches nothing publishable. The app detects a Play install — by the installer package, or by the presence of split APKs, since the installer is missing on restored backups — and says so rather than reporting a mismatch. To check a build yourself, install the APK published directly.

### iOS

iOS cannot do this at all. App Store binaries are FairPlay-encrypted per download and re-signed per install, so a hash computed on the device is device-specific and matches nothing that could be published. The About dialog says so plainly rather than implying a check it never ran. To verify Nymchat's code on Apple hardware, use the web app, which does re-hash everything it is running.

## Warrant Canary

A warrant canary is a statement, published and updated on a fixed schedule, that the Nymchat developer has *not* received any secret government request (such as a National Security Letter or FISA order) that legally prohibits disclosure. Because the Nymchat developer can be compelled to stay silent about such a request but cannot be compelled to lie, the canary going stale or disappearing is itself the signal.

The canary lives in [`canary.json`](canary.json) at the repository root and is fetched directly from GitHub, so its source is auditable in the commit history independently of the deployed site. The About dialog reads it and color-codes the status:

- **Green — All clear**: The canary is signed, current, and the signature matches the Nymchat developer key. No secret request has been received.
- **Yellow — Update overdue / Not all clear**: The canary was not refreshed by its `nextUpdateBy` date, or `allClear` is `false`. A silenced request cannot be ruled out.
- **Red — Signature invalid / Canary removed**: The signature does not match the Nymchat developer key, or the canary file is gone entirely. Treat this as a serious warning.

The signed canary also embeds a **freshness anchor**: the latest Bitcoin block height and hash at signing time. Because that hash could not have been known before the block existed, it proves the canary was signed *after* a specific point in time and was not pre-signed in bulk. The About dialog links the anchor to a block explorer.

## Contributing

Pull requests are welcome.

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## Changelog

See the [releases page](https://github.com/Spl0itable/NYM/releases) for each update's changes.

## Legal

If you choose to use Nymchat on 21 Million LLC operated infrastructure and domain (nymchat.app), your use is subject to the below Terms of Service and Privacy Policy.

- [Terms of Service](https://web.nymchat.app/static/tos)
- [Privacy Policy](https://web.nymchat.app/static/pp)

## Contact

Created and operated by [21 Million LLC](https://nostrservices.com). Lead developer: [@Luxas#a8df](https://nostr.band/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv)

## License

Copyright 21 Million LLC

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details. https://www.gnu.org/licenses/agpl-3.0.html
