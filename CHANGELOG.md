## v2.16.45 - 2025-10-31

Hotfix: user context menu not correctly getting the right user for blocking or slapping

## v2.16.44 - 2025-10-31

Hotfix: slight refactor with hardcoded nostr-tools import

## v2.16.43 - 2025-10-31

Hotfix: bitchat theme user colors made brighter for easier visibility against black background

## v2.16.42 - 2025-10-31

Hotfix: resend REQs on reconnect or app refocus

## v2.16.41 - 2025-10-31

Hotfix: incorrect use of client tag and minor bug fixes

## v2.16.40 - 2025-10-30

Hotfix: checking if user can be zapped not correctly getting lightning address

## v2.16.39 - 2025-10-26

New: forward secrecy (disappearing private messages) added, can be enabled from settings
Hotfix: correctly routes your messages to the right threads

## v2.15.39 - 2025-10-25

New: deprecated NIP-04 private messages for NIP-17 (NIP-44 encrypted and NIP-59 gift wrapped)

## v2.14.39 - 2025-10-25

New: guided tutorial on first-ever session

## v2.13.39 - 2025-10-22

Hotfix: autoscroll bug
Hotfix: nosflare blaster not working

## v2.13.38 - 2025-10-22

Hotfix: retry read relays on reconnection

## v2.13.37 - 2025-10-22

Hotfix: spread out each kind type in REQs

## v2.13.36 - 2025-10-22

Hotfix: tweaked number of events received from relays

## v2.13.35 - 2025-10-22

Hotfix: increased number of events received from relays

## v2.13.34 - 2025-10-21

Hotfix: shared nym.bar links for channels now open within the app and switch to the channel

## v2.13.33 - 2025-10-19

Hotfix: invite community throwing error

## v2.13.32 - 2025-10-19

Hotfix: changed private community channels badge from PRV to PRI

## v2.13.31 - 2025-10-19

Hotfix: reverted half-working awake reconnection mechanism

## v2.13.30 - 2025-10-19

Hotfix: added better notification deep linking

## v2.13.29 - 2025-10-19

Hotfix: kicked users now temp muted for 15min

## v2.13.28 - 2025-10-19

Hotfix: case where kicked users weren't kicked

## v2.13.27 - 2025-10-19

Hotfix: case where unbanned users' messages did show to rest of community

## v2.13.26 - 2025-10-19

Hotfix: case where kicked users weren't kicked

## v2.13.25 - 2025-10-19

New: allow copying user pubkey to clipboard from context menu
New: added copy pubkey to user context menu and updated commands to support pubkey
New: added kind 10000 mute list support for blocked users and keywords
Hotfix: bug where blocked users' nym nicks wouldn't display
Hotfix: reset view on geohash explorer removes last opened location details
Hotfix: prevent nostr profile save data from wiping pre-existing data in kind 0

## v2.12.25 - 2025-10-18

Hotfix: hide your location from legend if location not enabled
Hotfix: add pinch to zoom support to globe for mobile

## v2.12.24 - 2025-10-18

New: geohash channel explorer

## v2.11.24 - 2025-10-17

New: optionally change timestamp format to 12hr from settings
New: terms of service and privacy policy

## v2.10.24 - 2025-10-14

Hotfix: external wallet support in app

## v2.10.23 - 2025-10-14

Hotfix: cleaned up redundant messages

## v2.10.22 - 2025-10-14

Hotfix: case where not all relays are reconnected on app resume

## v2.10.21 - 2025-10-14

Hotfix: enhanced support for flutter app to reconnnect relays

## v2.10.20 - 2025-10-14

Hotfix: enhanced support for flutter app to reconnnect relays

## v2.10.19 - 2025-10-14

Hotfix: case where network disconnection doesn't properly reconnnect relays

## v2.10.18 - 2025-10-14

New: option to auto assign new ephemeral identity on each session restart

## v2.9.18 - 2025-10-14

Hotfix: case where sidebar could get cut off
Hotfix: case where channel name is identical to another channel and isn't routed correctly
Hotfix: only support channels without spaces in name

## v2.9.17 - 2025-10-13

Hotfix: added deeplinking to notifications
Hotfix: no longer shows as json for NIP-04 PMs on other nostr clients

## v2.9.16 - 2025-10-13

Hotfix: possible channel name collision with hashtag links
Hotfix: incorrect member count in public/private communities

## v2.9.15 - 2025-10-12

Hotfix: public/private communities not showing unread message count

## v2.9.14 - 2025-10-12

Hotfix: corrected share URL and routing
Hotfix: properly track banned users
Hotfix: show discovered public community channels in sidebar
Other minor quality of life and improvements

## v2.9.13 - 2025-10-11

New: default blurs images, but can unblur by clicking or always unblur from settings
New: support for NIP-72 communities with moderation capabilities

## v1.9.13 - 2025-09-17

Hotfix: corrected background message pruning

## v1.9.12 - 2025-09-06

Hotfix: case where changing nym nick or lightning address could overwrite/remove profile data

## v1.9.11 - 2025-09-06

Hotfix: your own messages are highlighted
New: bitchat style theme (multi-colored users)

## v1.8.11 - 2025-09-06

Hotfix: message formatting bug and GPS coordinate link

## v1.8.10 - 2025-09-05

Hotfix: various minor bug fixes

## v1.8.9 - 2025-09-05

New: nyms now suffixed with last 4 digits of pubkey to align with bitchat
New: invite users to channel through /invite command
New: block channels using `/block #channel` or by adding to list in settings
New: share current channel with others through new URL routing

## v1.7.9 - 2025-09-04

New: geohash channels now show matching GPS coordinates
New: sort geohash channels by proximity to location by enabling access from settings

## v1.6.9 - 2025-09-04

New: shows verified badge for NYM dev

## v1.5.9 - 2025-09-04

Hotfix: blocked users' messages not being removed

## v1.5.8 - 2025-09-04

Hotfix: added some spam filtering

## v1.5.7 - 2025-09-03

Hotfix: zap button wouldn't work on first click
Hotfix: blocked users not being saved to nostr
Hotfix: message input not always displaying on mobile
Hotfix: sidebar now shows "view more" on large lists

## v1.5.6 - 2025-09-02

Hotfix: word wrap issue
Hotfix: memory issue with volume of messages
Hotfix: user settings not saving to nostr
Hotfix: integrated all geolocated relays bitchat uses
Hotfix: order of PMs
Hotfix: geohash room join/creation modal format

## v1.5.5 - 2025-08-30

New: added NSEC login
New: added /zap command
Hotfix: better failed relay connection handling
Hotfix: saving settings no longer nukes persistent identity profile

## v1.4.5 - 2025-08-29

New: zaps! send bitcoin to other nymmers
Hotfix: corrected PM notifications when login with browser extension
Hotfix: borked ascii art

## v1.3.5 - 2025-08-29

Hotfix: channel sorting issue and not keeping current channel focused

## v1.3.4 - 2025-08-28

New: NIP-66 integration for relay discovery
Hotfix: added reactions to PMs

## v1.2.4 - 2025-08-26

Hotfix: saves custom joined/created channels to localstorage
Hotfix: bug that erased reactions on channel switch
Hotfix: made the /brb away message across all channels where mentioned
Hotfix: dynamically adds channels with most activity at top of list
New: added slap capability from context menu

## v1.2.3 - 2025-08-26

Hotfix: revamped emoji selection and added recently used
Hotfix: added all emoji and mapped to names
New: BRB command to set away message and auto reply when mentioned

## v1.1.3 - 2025-08-26

Hotfix: improved mobile responsiveness
Hotfix: improved channel discovery
New: added context menu when clicking nym's nickname

## v1.1.2 - 2025-08-25

Hotfix: corrected standard channel new messages count
New: all sent event messages blasted from Nosflare "send it" relay

## v1.1.1 - 2025-08-25

New: Interoperable with Amethyst and coolr.chat
New: Reactions on messaages
New: Anti-flood feature to temp auto mute bad users
New: Block keywords or phrases
New: Pin favorite channels
New: Sync settings across Nostr if signed in by extension
New: Markdown available in messages
New: Keyboard shortcut : for quickly selecting emoji
New: Ghost theme

## v1.0.1 - 2025-08-23

Hotfix: better support for nostr extension

## v1.0.0 - 2025-08-23

Initial release
