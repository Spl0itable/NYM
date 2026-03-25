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

A lightweight, yet feature-rich, ephemeral chat client built on [Nostr](https://github.com/nostr-protocol/nostr) protocol, bridged with [Bitchat](https://bitchat.free) for anonymous, temporary messaging.

## Overview

Nymchat, also known as NYM (Nostr Ynstant Messenger), is a Progressive Web App (PWA) chat messenger that uses [Nostr](https://github.com/nostr-protocol/nostr)'s ephemeral events (kind 20000) for regular and geohash-based location channels and [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) encrypted events (kind 1059) for private messages. No registration required - just pick a nym and start chatting.

![Nymchat Screenshot](https://nymchat.app/images/nymchat-app.png)

## Features

### Identity
- **Ephemeral Identity** - Generate temporary keypairs and pseudonyms per session
- **Auto-Ephemeral Mode** - Auto-start ephemeral sessions without a welcome screen

### Channels
- **Regular Channels** - Non-geohash channels (kind 20000)
- **Geohash Channels** - Location-based channels using geohash encoding (kind 20000)
- **Channel Sharing** - Generate shareable URLs for channels
- **Channel Pinning** - Pin frequently used channels to the top of your list
- **Proximity Sorting** - Sort geohash channels by distance from your location

### Messaging
- **Private Messages** - End-to-end encrypted 1:1 PMs using [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) (kind 14 rumor format) wrapped in NIP-59 gift wraps
- **Private Group Chats** - End-to-end encrypted multi-party group chats via [NIP-59](https://github.com/nostr-protocol/nips/blob/master/59.md); each message is individually gift-wrapped per member with an ephemeral sender key and a randomized envelope timestamp (±2 h) so relays cannot correlate group membership or timing
- **Rich Text** - Markdown support for bold, italic, strikethrough, code blocks, and quotes
- **Message Reactions** - React to messages with emojis ([NIP-25](https://github.com/nostr-protocol/nips/blob/master/25.md))
- **Auto-Reply** - Set away messages with `/brb` command
- **Image/Video Sharing** - Upload and share images or video

### Lightning Integration
- **Lightning Zaps** - Send Lightning payments to messages and user profiles ([NIP-57](https://github.com/nostr-protocol/nips/blob/master/57.md))
- **Lightning Addresses** - Set your Lightning address for receiving zaps
- **QR Invoice Display** - Visual QR codes for Lightning invoices

### Moderation & Privacy
- **User Blocking** - Block unwanted users and channels
- **Keyword Filtering** - Block messages containing specific keywords or phrases
- **Flood Protection** - Automatic spam prevention
- **Image Blur** - Option to blur images from other users until clicked

### Customization
- **Multiple Themes** - Matrix Green, Amber, Cyberpunk, Hacker Blue, Ghost (B&W), Bitchat (Multicolor)
- **Notification Sounds** - Classic Beep, ICQ Uh-Oh, MSN Alert, or Silent
- **Time Format** - 12-hour or 24-hour time display
- **Auto-Scroll** - Toggle automatic message scrolling

## Protocol Implementation

### Channels
- Regular event `kind 20000` with `['g', channel]` tag
- Geohash event `kind 20000` with `['g', geohash]` tag
- Tag `['n', nym]` for nickname

### Private Messages & Group Chats
- NIP-17 `kind 14` rumor (message content + metadata) sealed inside NIP-59 `kind 1059` gift wraps
- Each gift wrap uses a one-time ephemeral sender key; the `created_at` timestamp is randomized ±2 hours so relays cannot correlate senders, recipients, or timing
- Group chats send one gift wrap per member — each individually encrypted to that member's public key

### Reactions & Zaps
- Reaction events `kind 7` (NIP-25) with `['k', originalKind]` tag for proper categorization
- Lightning zaps `kind 9735` (NIP-57) with full invoice generation and payment tracking

## Available Commands

**Basic Commands:**
- `/help` - Show available commands
- `/join <channel>` - Join a channel (e.g., /join #9q5)
- `/j` - Shortcut for /join
- `/pm <nym>` - Open a 1:1 private message (e.g., /pm nym or /pm nym#xxxx)
- `/nick <nym>` - Change your nym
- `/who` - List online nyms in current channel
- `/w` - Shortcut for /who
- `/clear` - Clear chat messages
- `/leave` - Leave current channel or group chat
- `/quit` - Disconnect from Nymchat

**Group Chat Commands:**
- `/invite @nym` - In a channel: invite user to the channel. In a group chat: add a new member to the group
- `/leave` - Leave and remove yourself from the current group chat

**Moderation Commands:**
- `/block [nym|#channel]` - Block a user or channel
- `/unblock <nym|#channel>` - Unblock a user or channel

**Social Commands:**
- `/slap <nym>` - Slap someone with a trout
- `/hug <nym>` - Give a warm hug
- `/me <action>` - Action message (e.g., /me is coding)
- `/shrug` - Send a shrug ¯\_(ツ)_/¯
- `/brb <message>` - Set away message
- `/back` - Clear away message
- `/poll` - Create a poll

**Formatting Commands:**
- `/bold <text>` or `/b` - Send bold text
- `/italic <text>` or `/i` - Send italic text
- `/strike <text>` or `/s` - Send strikethrough text
- `/code <text>` or `/c` - Send code block
- `/quote <text>` or `/q` - Send quoted text

**Lightning Commands:**
- `/zap <nym>` - Send Lightning zap to user profile

**Channel Commands:**
- `/share` - Share current channel URL

## Nymbot

Nymbot is a built-in AI-powered chat bot available exclusively through the site ([nymchat.app](https://nymchat.app)) and the official iOS/Android apps. It is not available when running the PWA locally, as it relies on Cloudflare Workers AI infrastructure.

Nymbot responds to `?` commands in any channel. You can also mention **@Nymbot** in a message or quote-reply to a Nymbot response to continue a conversation.

### Bot Commands

**AI & Knowledge:**
- `?ask <question>` - Ask the AI anything (also triggered via `@Nymbot <question>`)
- `?define <word>` - Look up a word's definition, part of speech, and example usage
- `?translate <text>` - Translate text (auto-detects language; English text translates to Spanish)
- `?news` - Latest breaking news headlines

**Games & Fun:**
- `?trivia [category]` - Trivia questions (categories: general, history, science, crypto, nostr)
- `?joke` - Random tech/Bitcoin-themed joke
- `?riddle` - Random riddle — reply to answer
- `?wordplay [mode]` - Word games (modes: wordle, anagram, scramble) — reply to guess
- `?guess <word>` - Submit a guess for an active wordplay challenge (or just reply to the challenge)
- `?roll [NdN]` - Roll dice (e.g., `?roll 2d6`; default 1d6)
- `?flip` - Flip a coin
- `?8ball <question>` - Magic 8-ball
- `?pick <option1> <option2> ...` - Randomly pick from a list of options

**Utility:**
- `?math <expression>` - Calculate a math expression
- `?units <value> <from> to <to>` - Unit converter (e.g., `?units 10 km to mi`)
- `?time` - Current UTC time and Unix timestamp
- `?btc` - Current Bitcoin price

**Channel Activity:**
- `?who` - Who's active in the current channel
- `?summarize` - Summary of the current channel discussion
- `?top` - Top channels by recent message activity
- `?last [N]` - Last N messages across channels (default 10, max 25)
- `?seen <nym|@mention|pubkey>` - Where and when a nym was last seen

**Info:**
- `?help` - List all available bot commands
- `?about` - About Nymchat
- `?nostr` - Random Nostr protocol tips

### Conversational AI

Nymbot is context-aware — when you use `?ask` or `?summarize`, the bot receives the recent channel messages and active user list, so it can answer questions about the current conversation, reference what users said, and summarize discussions intelligently.

Quote-reply to any Nymbot response to continue the conversation — the bot automatically carries context from the reply chain (up to 6 messages of history). You can also quote any message and mention `@Nymbot` to ask the AI about it.

## Running PWA Locally

You can load Nymchat directly on your own machine by opening the `index.html` file in your browser:

1. Clone or download this repository
2. Open `index.html` in any modern web browser (Chrome, Firefox, Safari, Edge)
3. That's it — Nymchat will connect to the Nostr relay network and you can start chatting

No build tools, web server, or dependencies are required. The entire web app is self-contained in the `index.html`, `css/`, and `js/` directories.

## Mobile App (iOS & Android)

Nymchat is also available as an open source Flutter app for iOS and Android. The source code is located in the [`android-ios-app/`](android-ios-app/) directory.

The Flutter app is a native shell wrapper around the Nymchat PWA, providing:
- **Push Notifications** - Native push notifications for new messages
- **Native Performance** - Smooth, native-feeling experience on both platforms

### Building the Flutter App

1. Ensure you have the [Flutter SDK](https://flutter.dev/docs/get-started/install) installed (requires SDK ^3.6.0)
2. Navigate to the app directory:
   ```
   cd android-ios-app
   ```
3. Install dependencies:
   ```
   flutter pub get
   ```
4. Run on your device or emulator:
   ```
   flutter run
   ```
   
## Contributing

Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## Changelog

See the [releases page](https://github.com/Spl0itable/NYM/releases) for each update's changes.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Legal

If you choose to use Nymchat on 21 Million LLC operated infrastructure and domain (nymchat.app), your use is subject to the below Terms of Service and Privacy Policy.

- [Terms of Service](https://web.nymchat.app/static/tos)
- [Privacy Policy](https://web.nymchat.app/static/pp)

## Contact

Created and operated by 21 Million LLC - Lead developer: [@Luxas#a8df](https://nostr.band/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv)