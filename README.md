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

NYM is a Progressive Web App (PWA) chat messenger that uses Nostr's ephemeral events (kinds 20000 and 23333) and persistent communities (kinds 4550 and 34550) for public/private channels and NIP-04 encrypted events (kind 4) for private messages. No registration, no accounts, no persistence - just pick a nym and start chatting. Or, connect using Nostr Extension for persistent identity.

![NYM Screenshot](https://nym.bar/images/NYM.png)

## Features

- **Ephemeral Identity** - Generate temporary keypairs and pseudonym per session or use Nostr extension
- **Ephemeral Channels** - Standard channels and geohash-based location channels
- **Community Channels** - Public channels and private channels, with moderation tools
- **Reactions** - React to messages
- **Themes** - Pick a desired theme from settings
- **Private Messaging** - Encrypted DMs using NIP-04
- **Bitchat Bridge** - Compatible with Jack Dorsey's Bitchat

## Protocol Implementation

- Ephemeral geohash event `kind 20000` and standard channel event `kind 23333`
- Tags: `['n', nym]` for nickname, `['d', channel]` for standard channel, `['g', geohash]` for geohash channel

## Available Commands

```
/help     - Show available commands
/join     - Join a channel (e.g., /join random or /join #geohash)
/j        - Shortcut for /join
/pm       - Send private message (e.g., /pm nym)
/nick     - Change your nym (e.g., /nick newnick)
/who      - List online nyms in current channel
/w        - Shortcut for /who
/clear    - Clear chat messages
/block    - Block a user (e.g., /block nym)
/unblock  - Unblock a user (e.g., /unblock nym)
/slap     - Slap someone with a trout (e.g., /slap nym)
/me       - Action message (e.g., /me is coding)
/shrug    - Send a shrug ¯\_(ツ)_/¯
/bold     - Send bold text (e.g., /bold text)
/b        - Shortcut for /bold
/italic   - Send italic text (e.g., /italic text)
/i        - Shortcut for /italic
/strike   - Send strikethrough text (e.g., /strike text)
/s        - Shortcut for /strike
/code     - Send code block (e.g., /code text)
/c        - Shortcut for /code
/quote    - Send quoted text (e.g., /quote text)
/q        - Shortcut for /quote
/quit     - Disconnect from NYM
```

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

Created by [@Luxas](https://nostr.band/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv)
