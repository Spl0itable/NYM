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

# Nymchat

A feature-rich, ephemeral chat client built on the [Nostr](https://github.com/nostr-protocol/nostr) protocol, bridged with [Bitchat](https://bitchat.free) for pseudonymous, temporary messaging.

## Overview

Nymchat, also known as NYM (Nostr Ynstant Messenger), is a Progressive Web App (PWA) chat messenger. It uses [Nostr](https://github.com/nostr-protocol/nostr) ephemeral events for channels (kind 20000 for geohash channels and kind 23333 for non-geohash, named channels) and [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) gift-wrapped events (kind 1059) for private messages and group chats. No registration is required. Pick a nym and start chatting, or log in with an existing Nostr account if you want a persistent identity.

The web app is served as static files plus a set of Cloudflare Pages Functions under `functions/api/`. The Functions act as a privacy proxy for relays and media, generate link previews, run the Nymbot, and store the flair shop and encrypted settings. The same PWA is also wrapped in a Flutter shell for iOS and Android.

![Nymchat Screenshot](https://nymchat.app/images/nymchat-app.png)

## Features

### Identity
- **Ephemeral Identity**: Generate a temporary keypair and pseudonym per session.
- **Auto-Ephemeral Mode**: Auto-start an ephemeral session without a welcome screen.
- **Login with a Nostr Account**: Use a persistent identity via a NIP-07 browser extension (Alby, nos2x, and similar), a NIP-46 remote signer, or by entering an nsec.
- **Optional Identity Encryption**: Encrypt your saved identity's (nsec) private key on a device so it cannot be read from local storage without unlocking. You pick the unlock factor per device: a password, a PIN, a passkey, or a biometric (Face/Touch ID, Windows Hello, Android biometric, or a hardware security key). Passkey and biometric unlock use WebAuthn with the PRF extension to derive the key; password and PIN use PBKDF2. The key stays in memory only for the session and the plaintext key is never written to disk while encryption is on. This is a per-device setting and is not synced, because the unlock factor and the stored key are local to each device, so you enable it separately on each device. After you enable it, the app confirms an unlock right away so you are not locked out if an authenticator turns out not to support PRF. Only a non-sensitive on/off preference syncs across devices, so a new device can offer to set it up too. No password, salt, or credential is ever synced.

### Channels
- **Geohash Channels**: Location-based channels using geohash encoding (kind 20000).
- **Non-Geohash Channels**: Named topic channels (kind 23333).
- **Geohash Explorer**: Browse location channels on an interactive globe.
- **Channel Sharing**: Generate shareable URLs for channels.
- **Channel Favoriting**: Favorite frequently used channels to the top of the list.
- **Proximity Sorting**: Sort geohash channels by distance from your location.

### Messaging
- **Private Messages**: End-to-end encrypted 1:1 PMs using [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) (kind 14 rumor) wrapped in NIP-59 gift wraps.
- **Private Group Chats**: End-to-end encrypted multi-party group chats via [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) and [NIP-59](https://github.com/nostr-protocol/nips/blob/master/59.md) with rotating ephemeral recipient keys and automatic post-compromise recovery. Each message is individually gift-wrapped per member using one-time pubkeys so relays cannot correlate group membership, timing, or real identities.
- **Forward Secrecy and Disappearing Messages**: Optional per-message forward secrecy for DMs and a configurable message time-to-live.
- **Read Receipts and Typing Indicators**: Optional, with per-scope control (everyone, friends only, or off).
- **Rich Text**: Markdown for bold, italic, strikethrough, code blocks, and quotes.
- **Message Reactions**: React to messages with emoji ([NIP-25](https://github.com/nostr-protocol/nips/blob/master/25.md)).
- **Custom Emoji**: NIP-30 custom emoji pack discovery and rendering.
- **Polls**: Create and vote on polls in channels.
- **Message Translation**: Translate received messages on demand.
- **Auto-Reply**: Set an away message with the `/brb` command.
- **Image and Video Sharing**: Upload and share images or video.
- **Peer-to-Peer File Sharing**: Send files directly over WebRTC data channels, with WebTorrent for larger transfers.

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

You can also have a private 1:1 chat with Nymbot. Private replies are a paid feature funded with credits you buy over Lightning. Type `?balance` to see your credit balance, `?buy` to purchase more, and `?gift @nym` to gift credits to someone else.

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
- `?balance` - Show your Nymbot credit balance
- `?buy` - Buy credits over Lightning
- `?gift @nym` - Gift credits to another user
- `?transfer @nym` - Transfer your credits to another user

**Info:**
- `?help` - List all available bot commands
- `?about` - About Nymchat
- `?nostr` - Random Nostr protocol tips

### Conversational AI

Nymbot is context-aware. When you use `?ask` or `?summarize`, the bot receives the recent channel messages and active user list, so it can answer questions about the current conversation, reference what users said, and summarize discussions.

Quote-reply to any Nymbot response to continue the conversation. The bot carries context from the reply chain (up to six messages of history). You can also quote any message and mention `@Nymbot` to ask the AI about it.

## Mobile App (iOS & Android)

Nymchat is also available as an open source Flutter app for iOS and Android. The source code is in the [`android-ios-app/`](android-ios-app/) directory.

## Verify Build

The deployed web app is built deterministically, so anyone can confirm that the code running at the live site and in the iOS and Android apps is exactly what is published in this repository.

How it works:

- `npm run build` emits `dist/build-manifest.json` containing the source `commit`, a `sha256-` hash of every served HTML/JS/CSS asset, and a single `bundleHash` over that asset set, plus `dist/bundle-hash.txt` holding just the `bundleHash`. The output depends only on source content (`builtAt` is the commit time, not the build time), so reproducible rebuilds of the same commit are byte-identical.
- The [Build provenance](../../actions/workflows/build-provenance.yml) GitHub Action independently rebuilds each commit, prints the `bundleHash` to the run summary, and signs build-provenance attestations for `bundle-hash.txt` and the manifest.
- The app's **About** dialog re-fetches each running asset, hashes it in the browser with the Web Crypto API, and compares against the manifest. It then recomputes the `bundleHash` from those locally computed hashes — not from the manifest's claims — and looks it up in this repository's signed attestations via the GitHub API, so a deployment cannot simply vouch for itself with its own manifest. It shows `✓ Verified (n/n)` only when every asset matches **and** the recomputed `bundleHash` is attested by this repository; a deployment serving modified files or a self-made manifest shows `✗ Mismatch` or `✗ Unofficial build` instead, and `⚠ Provenance unreachable` when the GitHub API cannot be reached.

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
