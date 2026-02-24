```
███╗   ██╗██╗   ██╗███╗   ███╗
████╗  ██║╚██╗ ██╔╝████╗ ████║
██╔██╗ ██║ ╚████╔╝ ██╔████╔██║
██║╚██╗██║  ╚██╔╝  ██║╚██╔╝██║
██║ ╚████║   ██║   ██║ ╚═╝ ██║
╚═╝  ╚═══╝   ╚═╝   ╚═╝     ╚═╝
```

# Nostr Ynstant Messenger

A lightweight ephemeral chat client built on Nostr protocol, bridging with [Bitchat](https://bitchat.free) for anonymous, temporary messaging.

## Overview

NYM is a Progressive Web App (PWA) chat messenger that uses Nostr's ephemeral events (kind 20000) for geohash-based location channels and [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md) encrypted events (kind 1059) for private messages. No registration required - just pick a nym and start chatting.

![NYM Screenshot](https://nym.bar/images/NYM.png)

## Features

### Identity
- **Ephemeral Identity** - Generate temporary keypairs and pseudonyms per session
- **Auto-Ephemeral Mode** - Auto-start ephemeral sessions without a welcome screen

### Channels
- **Geohash Channels** - Location-based channels using geohash encoding (kind 20000)
- **Channel Sharing** - Generate shareable URLs for channels
- **Channel Pinning** - Pin frequently used channels to the top of your list
- **Proximity Sorting** - Sort geohash channels by distance from your location

### Messaging
- **Private Messages** - End-to-end encrypted PMs using NIP-17
- **Rich Text** - Markdown support for bold, italic, strikethrough, code blocks, and quotes
- **Message Reactions** - React to messages with emojis (NIP-25)
- **Auto-Reply** - Set away messages with `/brb` command
- **Image Sharing** - Upload and share images via blossom.band

### Lightning Integration
- **Lightning Zaps** - Send Lightning payments to messages and user profiles (NIP-57)
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

### Geohash Channels
- Geohash event `kind 20000` with `['g', geohash]` tag
- Tags: `['n', nym]` for nickname, `['client', 'NYM']` for client identification

### Private Messages
- NIP-17 encrypted direct messages `kind 1059`
- End-to-end encryption with recipient's public key

### Reactions & Zaps
- Reaction events `kind 7` (NIP-25) with `['k', originalKind]` tag for proper categorization
- Lightning zaps `kind 9735` (NIP-57) with full invoice generation and payment tracking

## Available Commands

**Basic Commands:**
- `/help` - Show available commands
- `/join <channel>` - Join a geohash channel (e.g., /join #9q5)
- `/j` - Shortcut for /join
- `/pm <nym>` - Send private message (e.g., /pm nym or /pm nym#xxxx)
- `/nick <nym>` - Change your nym
- `/who` - List online nyms in current channel
- `/w` - Shortcut for /who
- `/clear` - Clear chat messages
- `/leave` - Leave current channel
- `/quit` - Disconnect from NYM

**Moderation Commands:**
- `/block [nym|#channel]` - Block a user or channel
- `/unblock <nym|#channel>` - Unblock a user or channel

**Social Commands:**
- `/slap <nym>` - Slap someone with a trout
- `/me <action>` - Action message (e.g., /me is coding)
- `/shrug` - Send a shrug ¯\_(ツ)_/¯
- `/brb <message>` - Set away message
- `/back` - Clear away message
- `/invite <nym>` - Invite user to current channel

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

## Contributing

Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Legal

- [Terms of Service](TOS.md)
- [Privacy Policy](PP.md)

## Contact

Created and operated by 21 Million LLC - Lead developer: [@Luxas](https://nostr.band/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv)