```
███╗   ██╗██╗   ██╗███╗   ███╗
████╗  ██║╚██╗ ██╔╝████╗ ████║
██╔██╗ ██║ ╚████╔╝ ██╔████╔██║
██║╚██╗██║  ╚██╔╝  ██║╚██╔╝██║
██║ ╚████║   ██║   ██║ ╚═╝ ██║
╚═╝  ╚═══╝   ╚═╝   ╚═╝     ╚═╝
```

# Nostr Ynstant Messenger

A lightweight ephemeral and persistent chat client built on Nostr protocol, bridging with [Bitchat](https://bitchat.free) for anonymous, temporary messaging.

## Overview

NYM is a Progressive Web App (PWA) chat messenger that uses Nostr's ephemeral events (kinds 20000 and 23333), persistent communities (kinds 4550 and 34550), and NIP-04 encrypted events (kind 4) for private messages. No registration required - just pick a nym and start chatting, or connect using a Nostr extension for persistent identity.

![NYM Screenshot](https://nym.bar/images/NYM.png)

## Features

### Identity & Connection
- **Ephemeral Identity** - Generate temporary keypairs and pseudonyms per session
- **Persistent Identity** - Connect via Nostr extension (Alby, nos2x) or NSEC private key
- **Auto-Ephemeral Mode** - Option to skip welcome screen and auto-start ephemeral sessions
- **Profile Sync** - Lightning addresses and settings synced across devices for persistent users

### Channels & Communities
- **Ephemeral Channels** - Standard channels (kind 23333) and geohash-based location channels (kind 20000)
- **Community Channels** - Public and private persistent communities (kinds 4550, 34550) with moderation tools
- **Channel Sharing** - Generate shareable URLs for channels and communities
- **Channel Pinning** - Pin frequently used channels to the top of your list
- **Proximity Sorting** - Sort geohash channels by distance from your location

### Messaging
- **Private Messages** - End-to-end encrypted PMs using NIP-04
- **Rich Text** - Markdown support for bold, italic, strikethrough, code blocks, and quotes
- **Message Reactions** - React to messages with emojis (NIP-25)
- **Auto-Reply** - Set away messages with `/brb` command
- **Image Sharing** - Upload and share images via nostrmedia.com

### Lightning Integration
- **Lightning Zaps** - Send Lightning payments to messages and user profiles (NIP-57)
- **Lightning Addresses** - Set your Lightning address for receiving zaps
- **QR Invoice Display** - Visual QR codes for Lightning invoices

### Moderation & Privacy
- **User Blocking** - Block unwanted users and channels
- **Keyword Filtering** - Block messages containing specific keywords or phrases
- **Community Moderation** - Kick, ban, and manage moderators (admins and mods only)
- **Community-Specific Filters** - Custom keyword blocking per community
- **Flood Protection** - Automatic spam prevention
- **Image Blur** - Option to blur images from other users until clicked

### Customization
- **Multiple Themes** - Matrix Green, Amber, Cyberpunk, Hacker Blue, Ghost (B&W), Bitchat (Multicolor)
- **Notification Sounds** - Classic Beep, ICQ Uh-Oh, MSN Alert, or Silent
- **Time Format** - 12-hour or 24-hour time display
- **Auto-Scroll** - Toggle automatic message scrolling

## Protocol Implementation

### Ephemeral Channels
- Geohash event `kind 20000` with `['g', geohash]` tag
- Standard channel event `kind 23333` with `['d', channel]` tag
- Tags: `['n', nym]` for nickname, `['client', 'NYM']` for client identification

### Community Channels
- Community definition `kind 34550` (NIP-72)
- Community posts `kind 4550` with `['a', communityReference]` tag
- Moderation events `kind 1984` (NIP-56) for bans, kicks, and moderator actions
- Support for public and private communities with member management

### Private Messages
- NIP-04 encrypted direct messages `kind 4`
- End-to-end encryption with recipient's public key

### Reactions & Zaps
- Reaction events `kind 7` (NIP-25) with `['k', originalKind]` tag for proper categorization
- Lightning zaps `kind 9735` (NIP-57) with full invoice generation and payment tracking

## Available Commands

**Basic Commands:**
- `/help` - Show available commands
- `/join <channel>` - Join a channel (e.g., /join random or /join #geohash)
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

**Community Commands (requires persistent identity):**
- `/createcommunity <name> ["description"] [--private]` or `/cc` - Create a community
- `/addmod <nym>` - Add moderator to community (admin only)
- `/removemod <nym>` - Remove moderator (admin only)
- `/kick <nym>` - Kick user from community (admin/mod)
- `/ban <nym>` - Ban user from community (admin/mod)
- `/unban <nym>` - Unban user from community (admin/mod)
- `/invitecommunity <nym>` - Invite user to private community
- `/communityinfo` or `/ci` - Show community information
- `/members` - List community members (admin/mod)
- `/mods` - List community moderators
- `/communitysettings` or `/cs` - Manage community settings (admin only)

## Technical Details

- **Relay Support** - Connects to multiple Nostr relays for redundancy and discovery
- **Relay Monitoring** - Uses NIP-66 for automatic relay discovery
- **PWA Support** - Install as a standalone app on mobile and desktop
- **Responsive Design** - Mobile-first interface with swipe gestures
- **Message Deduplication** - Prevents duplicate messages across relays
- **Automatic Reconnection** - Handles network interruptions gracefully

## Contributing

Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

Created and operated by 21 Million LLC - Lead developer: [@Luxas](https://nostr.band/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv)