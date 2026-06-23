// Built-in unicode emoji dataset + shortcode map + recents helpers.
//
// PRECISE 1:1 port of the PWA's data. Category list, ordering, and the full
// emoji arrays come from `js/app.js` `this.allEmojis` (lines 780-794). The
// shortcode→emoji map (`emojiMap`, lines 795-1033) drives the picker's name
// search. Recents behavior mirrors `js/modules/reactions.js`
// (`loadRecentEmojis`/`addToRecentEmojis`/`_recentEmojisForPicker`, lines
// 128-159) keyed on localStorage `nym_recent_emojis` (≤24).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// localStorage key the PWA persists recents under (reactions.js:136).
const String kRecentEmojisKey = 'nym_recent_emojis';

/// Hard cap the PWA stores (reactions.js:145).
const int kRecentEmojisCap = 24;

/// Ordered category list, identical order to `allEmojis` in app.js:780.
/// Section titles in the picker are these keys, capitalized (emoji.js:551).
const List<String> kEmojiCategoryOrder = <String>[
  'smileys',
  'people',
  'gestures',
  'hearts',
  'symbols',
  'objects',
  'clothing',
  'nature',
  'food',
  'activities',
  'travel',
  'weather',
  'flags',
];

/// Built-in unicode emoji grouped by category, in the PWA's exact order.
/// Verbatim from `js/app.js` `this.allEmojis` (lines 781-793).
const Map<String, List<String>> kEmojisByCategory = <String, List<String>>{
  'smileys': <String>[
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '☺️', '😚', '😙', '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🫣', '🤫', '🤔', '🫡', '🤐', '🤨', '😐', '😑', '😶', '🫥', '😏', '😒', '🙄', '😬', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '😵‍💫', '🤯', '🤠', '🥳', '🥸', '😎', '🤓', '🧐', '😕', '🫤', '😟', '☹️', '🙁', '😮', '😯', '😲', '😳', '🥺', '🥹', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '☠️', '💩', '🤡', '👹', '👺', '👻', '👽', '👾', '🤖', '🎃', '😺', '😸', '😹', '😻', '😼', '😽', '🙀', '😿', '😾',
  ],
  'people': <String>[
    '👶', '🧒', '👦', '👧', '🧑', '👱', '👨', '🧔', '👩', '🧓', '👴', '👵', '🙍', '🙎', '🙅', '🙆', '💁', '🙋', '🧏', '🙇', '🤦', '🤷', '👮', '🕵️', '💂', '🥷', '👷', '🫅', '🤴', '👸', '👳', '👲', '🧕', '🤵', '👰', '🤰', '🫃', '🫄', '🤱', '👼', '🎅', '🤶', '🦸', '🦹', '🧙', '🧚', '🧛', '🧜', '🧝', '🧞', '🧟', '🧌', '💆', '💇', '🚶', '🧍', '🧎', '🏃', '💃', '🕺', '🕴️', '👯', '🧖', '🧗', '🤸', '🏌️', '🏇', '⛷️', '🏂', '🏋️', '🤼', '🤽', '🤾', '🤺', '⛹️', '🧘', '🛀', '🛌', '👭', '👫', '👬', '💏', '💑', '👪', '👨‍👩‍👦', '👨‍👩‍👧', '👨‍👩‍👧‍👦', '👨‍👩‍👦‍👦', '👨‍👩‍👧‍👧', '🗣️', '👤', '👥', '🫂',
  ],
  'gestures': <String>[
    '👍', '👎', '👌', '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '🫵', '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳', '🫴', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦾', '🦿', '🦵', '🦶', '👂', '🦻', '👃', '🧠', '🫀', '🫁', '🦷', '🦴', '👀', '👁️', '👅', '👄', '🫦', '💋',
  ],
  'hearts': <String>[
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '❤️‍🔥', '❤️‍🩹', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '♥️',
  ],
  'symbols': <String>[
    '💯', '💢', '💥', '💫', '💦', '💨', '🕳️', '💣', '💬', '👁️‍🗨️', '🗨️', '🗯️', '💭', '💤', '✨', '🌟', '💫', '⭐', '🌠', '🔥', '☄️', '🎆', '🎇', '🎈', '🎉', '🎊', '🎋', '🎍', '🎎', '🎏', '🎐', '🎑', '🧧', '🎀', '🎁', '🎗️', '🎟️', '🎫', '🔮', '🧿', '🪬', '🎮', '🕹️', '🎰', '🎲', '♟️', '🧩', '🧸', '🪅', '🪩', '🪆', '♠️', '♥️', '♦️', '♣️', '🀄', '🃏', '🔇', '🔈', '🔉', '🔊', '📢', '📣', '📯', '🔔', '🔕', '🎵', '🎶', '🎼', '☮️', '✝️', '☪️', '🕉️', '☸️', '✡️', '🔯', '🕎', '☯️', '☦️', '🛐', '⛎', '♈', '♉', '♊', '♋', '♌', '♍', '♎', '♏', '♐', '♑', '♒', '♓', '🆔', '⚛️', '🉑', '☢️', '☣️', '📴', '📳', '🈶', '🈚', '🈸', '🈺', '🈷️', '✴️', '🆚', '💮', '🉐', '㊙️', '㊗️', '🈴', '🈵', '🈹', '🈲', '🅰️', '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌', '⭕', '🛑', '⛔', '📛', '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱', '🔞', '📵', '🚭', '❗', '❕', '❓', '❔', '‼️', '⁉️', '🔅', '🔆', '〽️', '⚠️', '🚸', '🔱', '⚜️', '🔰', '♻️', '✅', '🈯', '💹', '❇️', '✳️', '❎', '🌐', '💠', 'Ⓜ️', '🌀', '💤', '🏧', '🚾', '♿', '🅿️', '🛗', '🈳', '🈂️', '🛂', '🛃', '🛄', '🛅', '🚹', '🚺', '🚼', '⚧️', '🚻', '🚮', '🎦', '📶', '🈁', '🔣', 'ℹ️', '🔤', '🔡', '🔠', '🆖', '🆗', '🆙', '🆒', '🆕', '🆓', '0️⃣', '1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟', '🔢', '#️⃣', '*️⃣', '⏏️', '▶️', '⏸️', '⏯️', '⏹️', '⏺️', '⏭️', '⏮️', '⏩', '⏪', '⏫', '⏬', '◀️', '🔼', '🔽', '➡️', '⬅️', '⬆️', '⬇️', '↗️', '↘️', '↙️', '↖️', '↕️', '↔️', '↩️', '↪️', '⤴️', '⤵️', '🔀', '🔁', '🔂', '🔄', '🔃', '➕', '➖', '➗', '✖️', '🟰', '♾️', '💲', '💱', '™️', '©️', '®️', '〰️', '➰', '➿', '🔚', '🔙', '🔛', '🔝', '🔜', '✔️', '☑️', '🔘', '🔴', '🟠', '🟡', '🟢', '🔵', '🟣', '⚫', '⚪', '🟤', '🔺', '🔻', '🔸', '🔹', '🔶', '🔷', '🔳', '🔲', '▪️', '▫️', '◾', '◽', '◼️', '◻️', '🟥', '🟧', '🟨', '🟩', '🟦', '🟪', '⬛', '⬜', '🟫', '🔈', '🔉', '🔊', '🔇', '📣', '📢', '🔔', '🔕', '🃏', '🀄', '🎴', '🔁', '🔂', '🔀',
  ],
  'objects': <String>[
    '⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '🖲️', '🕹️', '🗜️', '💽', '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📞', '☎️', '📟', '📠', '📺', '📻', '🎙️', '🎚️', '🎛️', '⏱️', '⏲️', '⏰', '🕰️', '⌛', '⏳', '📡', '🔋', '🪫', '🔌', '💡', '🔦', '🕯️', '🪔', '🧯', '🛢️', '💸', '💵', '💴', '💶', '💷', '🪙', '💰', '💳', '🪪', '🧾', '💎', '⚖️', '🪜', '🧰', '🪛', '🔧', '🔨', '⚒️', '🛠️', '⛏️', '🪚', '🔩', '⚙️', '🪤', '⛓️', '🧲', '🔫', '💣', '🧨', '🪓', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️', '🪦', '⚱️', '🏺', '🔮', '📿', '🧿', '🪬', '💈', '⚗️', '🔭', '🔬', '🕳️', '🩻', '🩹', '🩺', '💊', '💉', '🩸', '🌡️', '🧬', '🦠', '🧫', '🧪', '🏷️', '🔖', '🚽', '🪠', '🚿', '🛁', '🛀', '🪥', '🪒', '🧻', '🧼', '🫧', '🪣', '🧽', '🧴', '🛏️', '🛋️', '🪑', '🚪', '🪞', '🪟', '🧹', '🧺', '🧯', '🛒', '🚬', '⚰️', '⚱️', '🗿', '🪧', '🪪',
  ],
  'clothing': <String>[
    '👓', '🕶️', '🥽', '🥼', '🦺', '👔', '👕', '👖', '🧣', '🧤', '🧥', '🧦', '👗', '👘', '🥻', '🩱', '🩲', '🩳', '👙', '👚', '👛', '👜', '👝', '🛍️', '🎒', '🩴', '👞', '👟', '🥾', '🥿', '👠', '👡', '🩰', '👢', '👑', '👒', '🎩', '🎓', '🧢', '🪖', '⛑️', '📿', '💄', '💍', '💎', '🪭', '🪮',
  ],
  'nature': <String>[
    '🐵', '🐒', '🦍', '🦧', '🐶', '🐕', '🦮', '🐕‍🦺', '🐩', '🐺', '🦊', '🦝', '🐱', '🐈', '🐈‍⬛', '🦁', '🐯', '🐅', '🐆', '🐴', '🐎', '🦄', '🦓', '🦌', '🫎', '🦬', '🐮', '🐂', '🐃', '🐄', '🐷', '🐖', '🐗', '🐽', '🐏', '🐑', '🐐', '🐪', '🐫', '🦙', '🦒', '🐘', '🦣', '🦏', '🦛', '🐭', '🐁', '🐀', '🐹', '🐰', '🐇', '🐿️', '🦫', '🦔', '🦇', '🐻', '🐻‍❄️', '🐨', '🐼', '🦥', '🦦', '🦨', '🦘', '🦡', '🐾', '🦃', '🐔', '🐓', '🐣', '🐤', '🐥', '🐦', '🐧', '🕊️', '🦅', '🦆', '🦢', '🦉', '🦤', '🪶', '🦩', '🦚', '🦜', '🪽', '🐦‍⬛', '🪿', '🐸', '🐊', '🐢', '🦎', '🐍', '🐲', '🐉', '🦕', '🦖', '🐳', '🐋', '🐬', '🦭', '🐟', '🐠', '🐡', '🦈', '🐙', '🐚', '🪸', '🪼', '🐌', '🦋', '🐛', '🐜', '🐝', '🪲', '🐞', '🦗', '🪳', '🕷️', '🕸️', '🦂', '🦟', '🪰', '🪱', '🦠', '💐', '🌸', '💮', '🏵️', '🌹', '🥀', '🌺', '🌻', '🌼', '🌷', '🪷', '🌱', '🪴', '🌲', '🌳', '🌴', '🌵', '🌾', '🌿', '☘️', '🍀', '🍁', '🍂', '🍃', '🪹', '🪺', '🍄', '🪨', '🪵',
  ],
  'food': <String>[
    '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶️', '🫑', '🌽', '🥕', '🧄', '🧅', '🥔', '🍠', '🫘', '🥐', '🥯', '🍞', '🫓', '🥖', '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🦴', '🌭', '🍔', '🍟', '🍕', '🫔', '🥪', '🥙', '🧆', '🌮', '🌯', '🫕', '🥗', '🥘', '🫙', '🥫', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟', '🦪', '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁', '🍰', '🎂', '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰', '🥜', '🍯', '🥛', '🍼', '🫗', '☕', '🫖', '🍵', '🧃', '🥤', '🧋', '🍶', '🍺', '🍻', '🥂', '🍷', '🥃', '🍸', '🍹', '🧉', '🍾', '🧊', '🥄', '🍴', '🍽️', '🥣', '🥡', '🥢', '🫙',
  ],
  'activities': <String>[
    '⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🪀', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🪃', '🥅', '⛳', '🪁', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂', '🏋️', '🤼', '🤸', '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽', '🚣', '🧗', '🚴', '🚵', '🎪', '🎭', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹', '🥁', '🪘', '🎷', '🎺', '🪗', '🎸', '🪕', '🎻', '🪈', '🎲', '🎯', '🎳', '🎰', '🧩',
  ],
  'travel': <String>[
    '🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚', '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍️', '🛺', '🛞', '🚨', '🚔', '🚍', '🚘', '🚖', '🛞', '🚡', '🚠', '🚟', '🚃', '🚋', '🚞', '🚝', '🚄', '🚅', '🚈', '🚂', '🚆', '🚇', '🚊', '🚉', '✈️', '🛫', '🛬', '🛩️', '💺', '🛰️', '🚀', '🛸', '🚁', '🛶', '⛵', '🚤', '🛥️', '🛳️', '⛴️', '🚢', '⚓', '🪝', '⛽', '🚧', '🚦', '🚥', '🚏', '🗺️', '🗿', '🗽', '🗼', '🏰', '🏯', '🏟️', '🎡', '🎢', '🎠', '⛲', '⛱️', '🏖️', '🏝️', '🏜️', '🌋', '⛰️', '🏔️', '🗻', '🏕️', '🛖', '🏠', '🏡', '🏘️', '🏚️', '🏗️', '🏭', '🏢', '🏬', '🏣', '🏤', '🏥', '🏦', '🏨', '🏪', '🏫', '🏩', '💒', '🏛️', '⛪', '🕌', '🕍', '🛕', '🕋', '⛩️', '🛤️', '🛣️', '🗾', '🎑', '🏞️', '🌅', '🌄', '🌠', '🎇', '🎆', '🌇', '🌆', '🏙️', '🌃', '🌌', '🌉', '🌁',
  ],
  'weather': <String>[
    '☀️', '🌤️', '⛅', '🌥️', '☁️', '🌦️', '🌧️', '⛈️', '🌩️', '🌨️', '❄️', '☃️', '⛄', '🌬️', '💨', '🌪️', '🌫️', '🌈', '☔', '💧', '🌊', '🔥', '🌙', '🌛', '🌜', '🌚', '🌕', '🌖', '🌗', '🌘', '🌑', '🌒', '🌓', '🌔', '🌍', '🌎', '🌏', '🪐', '⭐', '🌟', '✨', '💫', '☄️',
  ],
  'flags': <String>[
    '🏳️', '🏴', '🏁', '🚩', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️', '🇺🇸', '🇬🇧', '🇨🇦', '🇦🇺', '🇩🇪', '🇫🇷', '🇯🇵', '🇰🇷', '🇨🇳', '🇮🇳', '🇧🇷', '🇲🇽', '🇪🇸', '🇮🇹', '🇷🇺', '🇸🇪', '🇳🇴', '🇩🇰', '🇫🇮', '🇳🇱', '🇧🇪', '🇦🇹', '🇨🇭', '🇵🇱', '🇺🇦', '🇹🇷', '🇬🇷', '🇵🇹', '🇮🇪', '🇿🇦', '🇳🇬', '🇪🇬', '🇰🇪', '🇦🇷', '🇨🇱', '🇨🇴', '🇵🇪', '🇻🇪', '🇹🇭', '🇻🇳', '🇮🇩', '🇵🇭', '🇲🇾', '🇸🇬', '🇳🇿', '🇸🇦', '🇦🇪', '🇮🇱', '🇵🇰', '🇧🇩', '🇭🇰', '🇹🇼', '🇨🇿', '🇭🇺', '🇷🇴', '🇭🇷', '🇷🇸', '🇧🇬', '🇸🇰', '🇸🇮', '🇱🇹', '🇱🇻', '🇪🇪', '🇮🇸', '🇱🇺', '🇲🇹', '🇨🇾', '🇯🇲', '🇹🇹', '🇧🇸', '🇧🇧', '🇵🇷', '🇨🇺', '🇩🇴', '🇭🇹', '🇵🇦', '🇨🇷', '🇬🇹', '🇭🇳', '🇸🇻', '🇳🇮', '🇧🇴', '🇪🇨', '🇺🇾', '🇵🇾', '🇬🇾',
  ],
};

/// Shortcode → emoji map, powering name search in the picker. Verbatim subset
/// from `js/app.js` `this.emojiMap` (lines 795-1033). Used to derive
/// emoji→names for the search index (emoji.js `_getEmojiToNames`).
const Map<String, String> kEmojiShortcodeMap = <String, String>{
  // Smileys & faces
  'grinning': '😀', 'smiley': '😃', 'grin': '😄', 'beaming': '😁', 'laughing': '😆',
  'sweat_smile': '😅', 'rofl': '🤣', 'laugh': '😂', 'slightly_smiling': '🙂', 'upside_down': '🙃',
  'wink': '😉', 'smile': '😊', 'innocent': '😇', 'heart_eyes': '🥰', 'love': '😍',
  'star_struck': '🤩', 'kiss': '😘', 'kissing': '😗', 'relaxed': '☺️', 'kissing_closed': '😚',
  'kissing_smiling': '😙', 'holding_tears': '🥲', 'yum': '😋', 'stuck_out': '😛', 'stuck_out_wink': '😜',
  'zany': '🤪', 'stuck_out_closed': '😝', 'money_face': '🤑', 'hug': '🤗', 'shush': '🤭',
  'peeking': '🫣', 'quiet': '🤫', 'thinking': '🤔', 'salute': '🫡', 'zipper': '🤐',
  'raised_eyebrow': '🤨', 'neutral': '😐', 'expressionless': '😑', 'no_mouth': '😶', 'dotted_face': '🫥',
  'smirk': '😏', 'unamused': '😒', 'eye_roll': '🙄', 'grimace': '😬', 'lying': '🤥',
  'relieved': '😌', 'pensive': '😔', 'sleepy': '😪', 'drool': '🤤', 'sleeping': '😴',
  'mask': '😷', 'thermometer': '🤒', 'bandage': '🤕', 'sick': '🤢', 'vomit': '🤮',
  'sneeze': '🤧', 'hot': '🥵', 'cold': '🥶', 'woozy': '🥴', 'dizzy': '😵',
  'spiral_eyes': '😵‍💫', 'mind_blown': '🤯', 'cowboy': '🤠', 'partying': '🥳', 'disguise': '🥸',
  'cool': '😎', 'nerd': '🤓', 'monocle': '🧐', 'confused': '😕', 'diagonal_mouth': '🫤',
  'worried': '😟', 'frowning': '☹️', 'slightly_frowning': '🙁', 'shocked': '😮', 'surprised': '😯',
  'astonished': '😲', 'flushed': '😳', 'pleading': '🥺', 'face_holding_tears': '🥹', 'anguished': '😧',
  'fearful': '😨', 'anxious': '😰', 'sad': '😥', 'cry': '😢', 'sob': '😭',
  'scream': '😱', 'confounded': '😖', 'persevere': '😣', 'disappointed': '😞', 'sweat': '😓',
  'weary': '😩', 'tired': '😫', 'yawn': '🥱', 'triumph': '😤', 'pouting': '😡',
  'angry': '😠', 'rage': '🤬', 'devil': '😈', 'imp': '👿', 'skull': '💀',
  'skull_crossbones': '☠️', 'poop': '💩', 'clown': '🤡', 'ogre': '👹', 'goblin': '👺',
  'ghost': '👻', 'alien': '👽', 'space_invader': '👾', 'robot': '🤖', 'jack': '🎃',
  'cat_smile': '😺', 'cat_grin': '😸', 'cat_joy': '😹', 'cat_love': '😻', 'cat_smirk': '😼',
  'cat_kiss': '😽', 'cat_scream': '🙀', 'cat_cry': '😿', 'cat_angry': '😾',
  // People
  'baby': '👶', 'child': '🧒', 'boy': '👦', 'girl': '👧', 'person': '🧑',
  'blond': '👱', 'man': '👨', 'bearded': '🧔', 'woman': '👩', 'older_person': '🧓',
  'old_man': '👴', 'old_woman': '👵', 'frowning_person': '🙍', 'pouting_person': '🙎', 'no_good': '🙅',
  'ok_person': '🙆', 'tipping': '💁', 'raising_hand': '🙋', 'deaf_person': '🧏', 'bowing': '🙇',
  'facepalm': '🤦', 'shrug': '🤷', 'police_officer': '👮', 'detective': '🕵️', 'guard': '💂',
  'ninja': '🥷', 'construction': '👷', 'royalty': '🫅', 'prince': '🤴', 'princess': '👸',
  'turban': '👳', 'skullcap': '👲', 'headscarf': '🧕', 'tuxedo': '🤵', 'bride': '👰',
  'pregnant': '🤰', 'pregnant_man': '🫃', 'pregnant_person': '🫄', 'breast_feeding': '🤱', 'angel': '👼',
  'santa': '🎅', 'mrs_claus': '🤶', 'superhero': '🦸', 'supervillain': '🦹', 'mage': '🧙',
  'fairy': '🧚', 'vampire': '🧛', 'merperson': '🧜', 'elf': '🧝', 'genie': '🧞',
  'zombie': '🧟', 'troll': '🧌', 'massage': '💆', 'haircut': '💇', 'walking': '🚶',
  'standing': '🧍', 'kneeling': '🧎', 'running': '🏃', 'dancer': '💃', 'man_dancing': '🕺',
  'levitate': '🕴️', 'people_dancing': '👯', 'sauna': '🧖', 'climbing': '🧗', 'cartwheeling': '🤸',
  'golfer': '🏌️', 'horse_racing': '🏇', 'skier': '⛷️', 'snowboarder': '🏂', 'weight_lifter': '🏋️',
  'wrestlers': '🤼', 'water_polo': '🤽', 'handball': '🤾', 'fencer': '🤺', 'basketball_player': '⛹️',
  'meditating': '🧘', 'bath': '🛀', 'sleeping_person': '🛌', 'women_holding_hands': '👭', 'couple': '👫',
  'men_holding_hands': '👬', 'kiss_couple': '💏', 'couple_heart': '💑', 'family': '👪',
  'speaking_head': '🗣️', 'silhouette': '👤', 'silhouettes': '👥', 'people_hugging': '🫂',
  // Gestures & body
  'thumbsup': '👍', 'thumbsdown': '👎', 'ok_hand': '👌', 'pinched': '🤌', 'pinch': '🤏',
  'peace': '✌️', 'crossed': '🤞', 'hand_with_fingers': '🫰', 'rock_on': '🤟', 'metal': '🤘',
  'call': '🤙', 'left': '👈', 'right': '👉', 'up': '👆', 'middle_finger': '🖕',
  // NOTE: `'wave'` resolves to 🌊 (weather) in the PWA because JS object
  // literals keep the last duplicate key; the gestures 👋 here is keyed
  // `wave_hand` so the const map stays valid while preserving 👋's name.
  'down': '👇', 'point': '☝️', 'point_at_you': '🫵', 'wave_hand': '👋', 'backhand': '🤚',
  'fingers_splayed': '🖐️', 'hand': '✋', 'vulcan': '🖖', 'rightward_hand': '🫱', 'leftward_hand': '🫲',
  'palm_down': '🫳', 'palm_up': '🫴', 'clap': '👏', 'raised': '🙌', 'heart_hands': '🫶',
  'open': '👐', 'palms': '🤲', 'handshake': '🤝', 'pray': '🙏', 'writing': '✍️',
  'nail_polish': '💅', 'selfie': '🤳', 'muscle': '💪', 'mechanical_arm': '🦾', 'mechanical_leg': '🦿',
  'leg': '🦵', 'foot': '🦶', 'ear': '👂', 'hearing_aid': '🦻', 'nose': '👃',
  'brain': '🧠', 'anatomical_heart': '🫀', 'lungs': '🫁', 'tooth': '🦷', 'bone': '🦴',
  'eyes': '👀', 'eye': '👁️', 'tongue': '👅', 'lips': '👄', 'biting_lip': '🫦', 'kiss_mark': '💋',
  // Hearts
  'heart': '❤️', 'orange_heart': '🧡', 'yellow_heart': '💛', 'green_heart': '💚',
  'blue_heart': '💙', 'purple_heart': '💜', 'black_heart': '🖤', 'white_heart': '🤍',
  'brown_heart': '🤎', 'heart_on_fire': '❤️‍🔥', 'mending_heart': '❤️‍🩹', 'broken': '💔',
  'exclamation_heart': '❣️', 'two_hearts': '💕', 'revolving': '💞', 'heartbeat': '💓',
  'growing': '💗', 'sparkling': '💖', 'cupid': '💘', 'gift_heart': '💝', 'heart_decoration': '💟',
  // Symbols & misc
  '100': '💯', 'anger': '💢', 'boom': '💥', 'dizzy_symbol': '💫', 'sweat_drops': '💦',
  'dash': '💨', 'hole': '🕳️', 'bomb': '💣', 'speech': '💬', 'eye_speech': '👁️‍🗨️',
  'left_speech': '🗨️', 'right_anger': '🗯️', 'thought': '💭', 'zzz': '💤',
  'sparkles': '✨', 'stars': '🌟', 'star': '⭐', 'shooting_star': '🌠', 'fire': '🔥',
  'comet': '☄️', 'fireworks': '🎆', 'sparkler': '🎇', 'balloon': '🎈', 'party': '🎉',
  'tada': '🎊', 'tanabata': '🎋', 'pine': '🎍', 'dolls': '🎎', 'carp_streamer': '🎏',
  'wind_chime': '🎐', 'moon_viewing': '🎑', 'red_envelope': '🧧', 'ribbon': '🎀', 'gift': '🎁',
  'reminder_ribbon': '🎗️', 'ticket': '🎟️', 'admission': '🎫', 'crystal_ball': '🔮', 'nazar': '🧿',
  'hamsa': '🪬', 'gaming': '🎮', 'joystick': '🕹️', 'slot': '🎰', 'dice': '🎲',
  'chess': '♟️', 'puzzle': '🧩', 'teddy': '🧸', 'pinata': '🪅', 'mirror_ball': '🪩',
  'nesting_dolls': '🪆', 'spades': '♠️', 'hearts_suit': '♥️', 'diamonds': '♦️', 'clubs': '♣️',
  'mahjong': '🀄', 'joker': '🃏', 'music': '🎵', 'notes': '🎶', 'musical_score': '🎼',
  'warning': '⚠️', 'check': '✅', 'x': '❌', 'question': '❓', 'exclamation': '❗',
  'bangbang': '‼️', 'interrobang': '⁉️', 'lightning': '⚡', 'trophy': '🏆', 'medal': '🥇',
  'silver_medal': '🥈', 'bronze_medal': '🥉', 'sports_medal': '🏅', 'military_medal': '🎖️',
  'copyright': '©️', 'registered': '®️', 'tm': '™️', 'infinity': '♾️',
  'peace_symbol': '☮️', 'cross': '✝️', 'star_crescent': '☪️', 'om': '🕉️', 'wheel_dharma': '☸️',
  'star_david': '✡️', 'yin_yang': '☯️', 'atom': '⚛️', 'radioactive': '☢️', 'biohazard': '☣️',
  'recycle': '♻️',
  // Objects
  'watch': '⌚', 'phone': '📱', 'calling': '📲', 'computer': '💻', 'keyboard': '⌨️',
  'desktop': '🖥️', 'printer': '🖨️', 'mouse': '🖱️', 'trackball': '🖲️', 'cd': '💿',
  'dvd': '📀', 'vhs': '📼', 'camera': '📷', 'camera_flash': '📸', 'video': '📹',
  'movie': '🎥', 'projector': '📽️', 'film': '🎞️', 'telephone': '☎️', 'pager': '📟',
  'fax': '📠', 'tv': '📺', 'radio': '📻', 'microphone': '🎙️', 'level_slider': '🎚️',
  'control_knobs': '🎛️', 'stopwatch': '⏱️', 'timer': '⏲️', 'alarm': '⏰', 'mantelpiece_clock': '🕰️',
  'hourglass': '⌛', 'hourglass_flowing': '⏳', 'satellite_dish': '📡', 'battery': '🔋', 'low_battery': '🪫',
  'plug': '🔌', 'bulb': '💡', 'flashlight': '🔦', 'candle': '🕯️', 'lamp': '🪔',
  'fire_extinguisher': '🧯', 'oil': '🛢️', 'dollar': '💵', 'yen': '💴', 'euro': '💶',
  'pound': '💷', 'coin': '🪙', 'money_bag': '💰', 'credit_card': '💳', 'id_card': '🪪',
  'receipt': '🧾', 'gem': '💎', 'balance': '⚖️', 'ladder': '🪜', 'toolbox': '🧰',
  'screwdriver': '🪛', 'wrench': '🔧', 'hammer': '🔨', 'hammer_wrench': '🛠️', 'pick': '⛏️',
  'saw': '🪚', 'nut_bolt': '🔩', 'gear': '⚙️', 'mousetrap': '🪤', 'chains': '⛓️',
  'magnet': '🧲', 'gun': '🔫', 'firecracker': '🧨', 'axe': '🪓',
  'knife': '🔪', 'dagger': '🗡️', 'crossed_swords': '⚔️', 'shield': '🛡️', 'coffin': '⚰️',
  'headstone': '🪦', 'urn': '⚱️', 'amphora': '🏺', 'barber': '💈', 'alembic': '⚗️',
  'telescope': '🔭', 'microscope': '🔬', 'xray': '🩻', 'adhesive': '🩹', 'stethoscope': '🩺',
  'pill': '💊', 'syringe': '💉', 'drop_blood': '🩸', 'thermometer_obj': '🌡️', 'dna': '🧬',
  'microbe': '🦠', 'petri': '🧫', 'test_tube': '🧪', 'label': '🏷️', 'bookmark': '🔖',
  'toilet': '🚽', 'plunger': '🪠', 'shower': '🚿', 'bathtub': '🛁', 'toothbrush': '🪥',
  'razor': '🪒', 'roll': '🧻', 'soap': '🧼', 'bubbles': '🫧', 'bucket': '🪣',
  'sponge': '🧽', 'lotion': '🧴', 'bed': '🛏️', 'couch': '🛋️', 'chair': '🪑',
  'door': '🚪', 'mirror': '🪞', 'window': '🪟', 'broom': '🧹', 'basket': '🧺',
  'cart': '🛒', 'moai': '🗿', 'placard': '🪧',
  'book': '📖', 'books': '📚', 'newspaper': '📰', 'scroll': '📜', 'memo': '📝',
  'pencil': '✏️', 'pen': '🖊️', 'paintbrush': '🖌️', 'crayon': '🖍️', 'scissors': '✂️',
  'pushpin': '📌', 'paperclip': '📎', 'link': '🔗', 'lock': '🔒', 'unlock': '🔓',
  'key': '🔑', 'old_key': '🗝️', 'mag': '🔍', 'bell': '🔔', 'no_bell': '🔕',
  'speaker': '🔊', 'mute': '🔇',
  // Clothing
  'glasses': '👓', 'sunglasses_obj': '🕶️', 'goggles': '🥽', 'lab_coat': '🥼', 'safety_vest': '🦺',
  'necktie': '👔', 'tshirt': '👕', 'jeans': '👖', 'scarf': '🧣', 'gloves': '🧤',
  'coat': '🧥', 'socks': '🧦', 'dress': '👗', 'kimono': '👘', 'sari': '🥻',
  'swimsuit': '🩱', 'briefs': '🩲', 'shorts': '🩳', 'bikini': '👙', 'blouse': '👚',
  'purse': '👛', 'handbag': '👜', 'pouch': '👝', 'shopping': '🛍️', 'backpack': '🎒',
  'thong_sandal': '🩴', 'shoe': '👞', 'sneaker': '👟', 'hiking_boot': '🥾', 'flat_shoe': '🥿',
  'heel': '👠', 'sandal': '👡', 'ballet': '🩰', 'boot': '👢', 'crown': '👑',
  'womans_hat': '👒', 'top_hat': '🎩', 'graduation': '🎓', 'cap': '🧢', 'helmet': '🪖',
  'rescue_helmet': '⛑️', 'lipstick': '💄', 'ring': '💍',
  // Nature & animals
  'monkey_face': '🐵', 'monkey': '🐒', 'gorilla': '🦍', 'orangutan': '🦧', 'dog': '🐶',
  'dog2': '🐕', 'guide_dog': '🦮', 'service_dog': '🐕‍🦺', 'poodle': '🐩', 'wolf': '🐺',
  'fox': '🦊', 'raccoon': '🦝', 'cat': '🐱', 'cat2': '🐈', 'black_cat': '🐈‍⬛',
  'lion': '🦁', 'tiger': '🐯', 'tiger2': '🐅', 'leopard': '🐆', 'horse': '🐴',
  'horse2': '🐎', 'unicorn': '🦄', 'zebra': '🦓', 'deer': '🦌', 'moose': '🫎',
  'bison': '🦬', 'cow': '🐮', 'ox': '🐂', 'water_buffalo': '🐃', 'cow2': '🐄',
  'pig': '🐷', 'pig2': '🐖', 'boar': '🐗', 'pig_nose': '🐽', 'ram': '🐏',
  'sheep': '🐑', 'goat': '🐐', 'camel': '🐪', 'two_hump_camel': '🐫', 'llama': '🦙',
  'giraffe': '🦒', 'elephant': '🐘', 'mammoth': '🦣', 'rhino': '🦏', 'hippo': '🦛',
  'mouse_face': '🐭', 'mouse2': '🐁', 'rat': '🐀', 'hamster': '🐹', 'rabbit': '🐰',
  'rabbit2': '🐇', 'chipmunk': '🐿️', 'beaver': '🦫', 'hedgehog': '🦔', 'bat': '🦇',
  'bear': '🐻', 'polar_bear': '🐻‍❄️', 'koala': '🐨', 'panda': '🐼', 'sloth': '🦥',
  'otter': '🦦', 'skunk': '🦨', 'kangaroo': '🦘', 'badger': '🦡', 'paw_prints': '🐾',
  'turkey': '🦃', 'chicken': '🐔', 'rooster': '🐓', 'hatching_chick': '🐣', 'baby_chick': '🐤',
  'chick': '🐥', 'bird': '🐦', 'penguin': '🐧', 'dove': '🕊️', 'eagle': '🦅',
  'duck': '🦆', 'swan': '🦢', 'owl': '🦉', 'dodo': '🦤', 'feather': '🪶',
  'flamingo': '🦩', 'peacock': '🦚', 'parrot': '🦜', 'wing': '🪽', 'black_bird': '🐦‍⬛',
  'goose': '🪿', 'frog': '🐸', 'crocodile': '🐊', 'turtle': '🐢', 'lizard': '🦎',
  'snake': '🐍', 'dragon_face': '🐲', 'dragon': '🐉', 'sauropod': '🦕', 'trex': '🦖',
  'whale': '🐳', 'whale2': '🐋', 'dolphin': '🐬', 'seal': '🦭', 'fish': '🐟',
  'tropical_fish': '🐠', 'blowfish': '🐡', 'shark': '🦈', 'octopus': '🐙', 'shell': '🐚',
  'coral': '🪸', 'jellyfish': '🪼', 'snail': '🐌', 'butterfly': '🦋', 'bug': '🐛',
  'ant': '🐜', 'bee': '🐝', 'beetle': '🪲', 'ladybug': '🐞', 'cricket': '🦗',
  'cockroach': '🪳', 'spider': '🕷️', 'web': '🕸️', 'scorpion': '🦂', 'mosquito': '🦟',
  'fly': '🪰', 'worm': '🪱', 'bouquet': '💐', 'cherry_blossom': '🌸', 'flower_white': '💮',
  'rosette': '🏵️', 'rose': '🌹', 'wilted': '🥀', 'hibiscus': '🌺', 'sunflower': '🌻',
  'blossom': '🌼', 'tulip': '🌷', 'lotus': '🪷', 'seedling': '🌱', 'potted_plant': '🪴',
  'evergreen': '🌲', 'deciduous': '🌳', 'palm': '🌴', 'cactus': '🌵', 'rice': '🌾',
  'herb': '🌿', 'shamrock': '☘️', 'four_leaf': '🍀', 'maple_leaf': '🍁', 'fallen_leaf': '🍂',
  'leaves': '🍃', 'nest': '🪹', 'nest_eggs': '🪺', 'mushroom': '🍄', 'rock': '🪨', 'wood': '🪵',
  // Food & drink
  'green_apple': '🍏', 'apple': '🍎', 'pear': '🍐', 'orange': '🍊', 'lemon': '🍋',
  'banana': '🍌', 'watermelon': '🍉', 'grapes': '🍇', 'strawberry': '🍓', 'blueberries': '🫐',
  'melon': '🍈', 'cherry': '🍒', 'peach': '🍑', 'mango': '🥭', 'pineapple': '🍍',
  'coconut': '🥥', 'kiwi': '🥝', 'tomato': '🍅', 'eggplant': '🍆', 'avocado': '🥑',
  'broccoli': '🥦', 'leafy_green': '🥬', 'cucumber': '🥒', 'hot_pepper': '🌶️', 'bell_pepper': '🫑',
  'corn': '🌽', 'carrot': '🥕', 'garlic': '🧄', 'onion': '🧅', 'potato': '🥔',
  'sweet_potato': '🍠', 'beans': '🫘', 'croissant': '🥐', 'bagel': '🥯', 'bread': '🍞',
  'flatbread': '🫓', 'baguette': '🥖', 'pretzel': '🥨', 'cheese': '🧀', 'egg': '🥚',
  'cooking': '🍳', 'butter': '🧈', 'pancakes': '🥞', 'waffle': '🧇', 'bacon': '🥓',
  'steak': '🥩', 'poultry_leg': '🍗', 'meat': '🍖', 'hotdog': '🌭',
  'hamburger': '🍔', 'fries': '🍟', 'pizza': '🍕', 'tamale': '🫔', 'sandwich': '🥪',
  'pita': '🥙', 'falafel': '🧆', 'taco': '🌮', 'burrito': '🌯', 'fondue': '🫕',
  'salad': '🥗', 'stew': '🥘', 'jar': '🫙', 'canned': '🥫', 'spaghetti': '🍝',
  'ramen': '🍜', 'soup': '🍲', 'curry': '🍛', 'sushi': '🍣', 'bento': '🍱',
  'dumpling': '🥟', 'oyster': '🦪', 'shrimp': '🍤', 'rice_ball': '🍙', 'rice_bowl': '🍚',
  'rice_cracker': '🍘', 'fish_cake': '🍥', 'fortune_cookie': '🥠', 'moon_cake': '🥮', 'oden': '🍢',
  'dango': '🍡', 'ice_shaved': '🍧', 'ice_cream': '🍨', 'cone': '🍦', 'pie': '🥧',
  'cupcake': '🧁', 'cake': '🎂', 'birthday': '🎂', 'custard': '🍮', 'lollipop': '🍭',
  'candy': '🍬', 'chocolate': '🍫', 'popcorn': '🍿', 'donut': '🍩', 'cookie': '🍪',
  'chestnut': '🌰', 'peanuts': '🥜', 'honey': '🍯', 'milk': '🥛', 'baby_bottle': '🍼',
  'pouring_liquid': '🫗', 'coffee': '☕', 'teapot': '🫖', 'tea': '🍵', 'juice': '🧃',
  'cup_straw': '🥤', 'boba': '🧋', 'sake': '🍶', 'beer': '🍺', 'beers': '🍻',
  'clinking': '🥂', 'wine': '🍷', 'tumbler': '🥃', 'cocktail': '🍸', 'tropical': '🍹',
  'mate': '🧉', 'champagne': '🍾', 'ice_cube': '🧊', 'spoon': '🥄', 'fork_knife': '🍴',
  'plate': '🍽️', 'bowl_spoon': '🥣', 'takeout': '🥡', 'chopsticks': '🥢',
  // Activities & sports
  'soccer': '⚽', 'basketball': '🏀', 'football': '🏈', 'baseball': '⚾', 'softball': '🥎',
  'tennis': '🎾', 'volleyball': '🏐', 'rugby': '🏉', 'flying_disc': '🥏', 'pool': '🎱',
  'yo_yo': '🪀', 'ping_pong': '🏓', 'badminton': '🏸', 'hockey': '🏒', 'field_hockey': '🏑',
  'lacrosse': '🥍', 'cricket_game': '🏏', 'boomerang': '🪃', 'goal_net': '🥅', 'golf': '⛳',
  'kite': '🪁', 'bow_arrow': '🏹', 'fishing': '🎣', 'diving_mask': '🤿', 'boxing': '🥊',
  'martial_arts': '🥋', 'running_shirt': '🎽', 'skateboard': '🛹', 'roller_skate': '🛼', 'sled': '🛷',
  'ice_skate': '⛸️', 'curling': '🥌', 'ski': '🎿', 'circus': '🎪', 'performing_arts': '🎭',
  'art': '🎨', 'clapper': '🎬', 'microphone2': '🎤', 'headphones': '🎧', 'piano': '🎹',
  'drum': '🥁', 'long_drum': '🪘', 'sax': '🎷', 'trumpet': '🎺', 'accordion': '🪗',
  'guitar': '🎸', 'banjo': '🪕', 'violin': '🎻', 'flute': '🪈', 'dart': '🎯',
  'bowling': '🎳',
  // Travel & places
  'car': '🚗', 'taxi': '🚕', 'suv': '🚙', 'bus': '🚌', 'trolleybus': '🚎',
  'racing': '🏎️', 'police_car': '🚓', 'ambulance': '🚑', 'firetruck': '🚒', 'minibus': '🚐',
  'pickup_truck': '🛻', 'truck': '🚚', 'articulated': '🚛', 'tractor': '🚜', 'scooter': '🛴',
  'bike': '🚲', 'motor_scooter': '🛵', 'motorcycle': '🏍️', 'auto_rickshaw': '🛺', 'wheel': '🛞',
  'police_light': '🚨', 'oncoming_police': '🚔', 'train': '🚆', 'metro': '🚇', 'tram': '🚊',
  'station': '🚉', 'bullet_train': '🚄', 'high_speed': '🚅', 'monorail': '🚝', 'railway': '🚞',
  'airplane': '✈️', 'departure': '🛫', 'arrival': '🛬', 'small_airplane': '🛩️', 'seat': '💺',
  'satellite': '🛰️', 'rocket': '🚀', 'ufo': '🛸', 'helicopter': '🚁', 'canoe': '🛶',
  'boat': '⛵', 'speedboat': '🚤', 'motor_boat': '🛥️', 'passenger_ship': '🛳️', 'ferry': '⛴️',
  'ship': '🚢', 'anchor': '⚓', 'hook': '🪝', 'fuel_pump': '⛽', 'construction_sign': '🚧',
  'traffic_light': '🚦', 'vertical_traffic': '🚥', 'bus_stop': '🚏', 'world_map': '🗺️',
  'statue_liberty': '🗽', 'tokyo_tower': '🗼', 'castle': '🏰', 'japanese_castle': '🏯',
  'stadium': '🏟️', 'ferris_wheel': '🎡', 'roller_coaster': '🎢', 'carousel': '🎠', 'fountain': '⛲',
  'beach_umbrella': '⛱️', 'beach': '🏖️', 'island': '🏝️', 'desert': '🏜️', 'volcano': '🌋',
  'mountain': '⛰️', 'snow_mountain': '🏔️', 'mount_fuji': '🗻', 'camping': '🏕️', 'hut': '🛖',
  'house': '🏠', 'house_garden': '🏡', 'derelict': '🏚️', 'building_construction': '🏗️', 'factory': '🏭',
  'office': '🏢', 'department_store': '🏬', 'post_office': '🏣', 'hospital': '🏥', 'bank': '🏦',
  'hotel': '🏨', 'convenience': '🏪', 'school': '🏫', 'love_hotel': '🏩', 'wedding': '💒',
  'classical': '🏛️', 'church': '⛪', 'mosque': '🕌', 'synagogue': '🕍', 'hindu_temple': '🛕',
  'kaaba': '🕋', 'shinto_shrine': '⛩️', 'railway_track': '🛤️', 'road': '🛣️',
  'sunrise': '🌅', 'sunrise_city': '🌄', 'night': '🌃', 'milky_way': '🌌', 'bridge_night': '🌉',
  // Weather
  'sun': '☀️', 'sun_clouds': '🌤️', 'partly_cloudy': '⛅', 'sun_behind_cloud': '🌥️', 'cloud': '☁️',
  'sun_rain': '🌦️', 'rain': '🌧️', 'thunder': '⛈️', 'lightning_cloud': '🌩️', 'snow_cloud': '🌨️',
  'snow': '❄️', 'snowman_snow': '☃️', 'snowman': '⛄', 'wind_face': '🌬️', 'wind': '💨',
  'tornado': '🌪️', 'fog': '🌫️', 'rainbow': '🌈', 'umbrella_rain': '☔', 'droplet': '💧',
  'wave': '🌊', 'moon': '🌙', 'crescent_moon': '🌛', 'last_quarter_face': '🌜', 'new_moon_face': '🌚',
  'full_moon': '🌕', 'waning_gibbous': '🌖', 'last_quarter': '🌗', 'waning_crescent': '🌘',
  'new_moon': '🌑', 'waxing_crescent': '🌒', 'first_quarter': '🌓', 'waxing_gibbous': '🌔',
  'earth_africa': '🌍', 'earth_americas': '🌎', 'earth_asia': '🌏', 'ringed_planet': '🪐',
  // Flags
  'white_flag': '🏳️', 'black_flag': '🏴', 'checkered_flag': '🏁', 'triangular_flag': '🚩',
  'rainbow_flag': '🏳️‍🌈', 'transgender_flag': '🏳️‍⚧️', 'pirate_flag': '🏴‍☠️',
  'us': '🇺🇸', 'gb': '🇬🇧', 'ca': '🇨🇦', 'au': '🇦🇺', 'de': '🇩🇪',
  'fr': '🇫🇷', 'jp': '🇯🇵', 'kr': '🇰🇷', 'cn': '🇨🇳', 'india': '🇮🇳',
  'br': '🇧🇷', 'mx': '🇲🇽', 'es': '🇪🇸', 'it': '🇮🇹', 'ru': '🇷🇺',
  'se': '🇸🇪', 'no': '🇳🇴', 'dk': '🇩🇰', 'fi': '🇫🇮', 'nl': '🇳🇱',
  'ch': '🇨🇭', 'pl': '🇵🇱', 'ua': '🇺🇦', 'tr': '🇹🇷', 'gr': '🇬🇷',
  'pt': '🇵🇹', 'ie': '🇮🇪', 'za': '🇿🇦', 'ng': '🇳🇬', 'eg': '🇪🇬',
  'ar': '🇦🇷', 'th': '🇹🇭', 'vn': '🇻🇳', 'id': '🇮🇩', 'ph': '🇵🇭',
  'sg': '🇸🇬', 'nz': '🇳🇿', 'sa': '🇸🇦', 'ae': '🇦🇪', 'il': '🇮🇱',
  'tw': '🇹🇼', 'hk': '🇭🇰', 'pr': '🇵🇷', 'cu': '🇨🇺', 'jm': '🇯🇲',
  // Aliases (emoji.js app.js:1030+)
  'ok': '👌', 'money': '🤑', 'hearts': '💕', 'celebrate': '🙌',
  'sunglasses': '😎', 'nauseous': '🤢', 'cold_sweat': '😰',
  'scream_cat': '🙀', 'exploding': '🤯', 'sunset': '🌆',
};

/// Reverse map emoji → list of shortcodes (names), used for search.
/// Mirrors emoji.js `_getEmojiToNames` (lines 521-530).
Map<String, List<String>> buildEmojiToNames() {
  final map = <String, List<String>>{};
  kEmojiShortcodeMap.forEach((name, emoji) {
    (map[emoji] ??= <String>[]).add(name);
  });
  return map;
}

/// Pure recents helper, mirroring `addToRecentEmojis` (reactions.js:142-148):
/// remove any existing occurrence, prepend, cap to [kRecentEmojisCap].
/// Most-recent-first.
List<String> addRecentEmoji(List<String> current, String emoji) {
  final next = <String>[emoji, ...current.where((e) => e != emoji)];
  if (next.length > kRecentEmojisCap) {
    return next.sublist(0, kRecentEmojisCap);
  }
  return next;
}

/// Storage-backed recents, persisted under [kRecentEmojisKey] as a JSON array,
/// matching the PWA's localStorage contract (reactions.js:128-140).
class EmojiRecentsStore {
  EmojiRecentsStore(this._prefs);

  final SharedPreferences _prefs;

  /// Load recents (reactions.js `loadRecentEmojis`). Tolerates corrupt JSON.
  List<String> load() {
    final raw = _prefs.getString(kRecentEmojisKey);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return <String>[];
  }

  /// Add an emoji to recents and persist (reactions.js `addToRecentEmojis` +
  /// `saveRecentEmojis`). Returns the new list.
  Future<List<String>> add(String emoji) async {
    final next = addRecentEmoji(load(), emoji);
    await _prefs.setString(kRecentEmojisKey, jsonEncode(next));
    return next;
  }
}
