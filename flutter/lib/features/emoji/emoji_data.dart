// Built-in unicode emoji dataset, shortcode map and recents helpers, matching the PWA's data.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted recents key.
const String kRecentEmojisKey = 'nym_recent_emojis';

/// Recents cap.
const int kRecentEmojisCap = 24;

/// Picker category order; section titles are these keys capitalized.
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

// Tables are dense on purpose; keep this file out of format passes (`dart format off` needs language 3.7).
/// Built-in unicode emoji by category, in the PWA's exact order.
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

/// Shortcode to emoji, powering picker name search.
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
  // `'wave'` is 🌊 in the PWA (last duplicate key wins), so 👋 is keyed `wave_hand`.
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
  // Aliases
  'ok': '👌', 'money': '🤑', 'hearts': '💕', 'celebrate': '🙌',
  'sunglasses': '😎', 'nauseous': '🤢', 'cold_sweat': '😰',
  'scream_cat': '🙀', 'exploding': '🤯', 'sunset': '🌆',
};

const Map<String, List<String>> kEmojiExtraNames = <String, List<String>>{
  '🫢': <String>['face_with_open_eyes_and_hand_over_mouth'], '😦': <String>['frowning_face_with_open_mouth'],
  '👨‍👩‍👦': <String>['family_man_woman_boy'], '👨‍👩‍👧': <String>['family_man_woman_girl'],
  '👨‍👩‍👧‍👦': <String>['family_man_woman_girl_boy'], '👨‍👩‍👦‍👦': <String>['family_man_woman_boy_boy'],
  '👨‍👩‍👧‍👧': <String>['family_man_woman_girl_girl'], '🤟': <String>['love_you_gesture'],
  '🔈': <String>['speaker_low_volume'], '🔉': <String>['speaker_medium_volume'], '📢': <String>['loudspeaker'],
  '📣': <String>['megaphone'], '📯': <String>['postal_horn'], '🔯': <String>['dotted_six_pointed_star'],
  '🕎': <String>['menorah'], '☦️': <String>['orthodox_cross'], '🛐': <String>['place_of_worship'],
  '⛎': <String>['ophiuchus'], '♈': <String>['aries'], '♉': <String>['taurus'], '♊': <String>['gemini'],
  '♋': <String>['cancer'], '♌': <String>['leo'], '♍': <String>['virgo'], '♎': <String>['libra'],
  '♏': <String>['scorpio'], '♐': <String>['sagittarius'], '♑': <String>['capricorn'],
  '♒': <String>['aquarius'], '♓': <String>['pisces'], '🆔': <String>['id_button'],
  '🉑': <String>['japanese_acceptable_button'], '📴': <String>['mobile_phone_off'],
  '📳': <String>['vibration_mode'], '🈶': <String>['japanese_not_free_of_charge_button'],
  '🈚': <String>['japanese_free_of_charge_button'], '🈸': <String>['japanese_application_button'],
  '🈺': <String>['japanese_open_for_business_button'], '🈷️': <String>['japanese_monthly_amount_button'],
  '✴️': <String>['eight_pointed_star'], '🆚': <String>['vs_button'], '🉐': <String>['japanese_bargain_button'],
  '㊙️': <String>['japanese_secret_button'], '㊗️': <String>['japanese_congratulations_button'],
  '🈴': <String>['japanese_passing_grade_button'], '🈵': <String>['japanese_no_vacancy_button'],
  '🈹': <String>['japanese_discount_button'], '🈲': <String>['japanese_prohibited_button'],
  '🅰️': <String>['a_button_blood_type'], '🅱️': <String>['b_button_blood_type'],
  '🆎': <String>['ab_button_blood_type'], '🆑': <String>['cl_button'], '🅾️': <String>['o_button_blood_type'],
  '🆘': <String>['sos_button'], '⭕': <String>['hollow_red_circle'], '🛑': <String>['stop_sign'],
  '⛔': <String>['no_entry'], '📛': <String>['name_badge'], '🚫': <String>['prohibited'],
  '♨️': <String>['hot_springs'], '🚷': <String>['no_pedestrians'], '🚯': <String>['no_littering'],
  '🚳': <String>['no_bicycles'], '🚱': <String>['non_potable_water'], '🔞': <String>['no_one_under_eighteen'],
  '📵': <String>['no_mobile_phones'], '🚭': <String>['no_smoking'], '❕': <String>['white_exclamation_mark'],
  '❔': <String>['white_question_mark'], '🔅': <String>['dim_button'], '🔆': <String>['bright_button'],
  '〽️': <String>['part_alternation_mark'], '🚸': <String>['children_crossing'],
  '🔱': <String>['trident_emblem'], '⚜️': <String>['fleur_de_lis'],
  '🔰': <String>['japanese_symbol_for_beginner'], '🈯': <String>['japanese_reserved_button'],
  '💹': <String>['chart_increasing_with_yen'], '❇️': <String>['sparkle'],
  '✳️': <String>['eight_spoked_asterisk'], '❎': <String>['cross_mark_button'],
  '🌐': <String>['globe_with_meridians'], '💠': <String>['diamond_with_a_dot'], 'Ⓜ️': <String>['circled_m'],
  '🌀': <String>['cyclone'], '🏧': <String>['atm_sign'], '🚾': <String>['water_closet'],
  '♿': <String>['wheelchair_symbol'], '🅿️': <String>['p_button'], '🛗': <String>['elevator'],
  '🈳': <String>['japanese_vacancy_button'], '🈂️': <String>['japanese_service_charge_button'],
  '🛂': <String>['passport_control'], '🛃': <String>['customs'], '🛄': <String>['baggage_claim'],
  '🛅': <String>['left_luggage'], '🚹': <String>['mens_room'], '🚺': <String>['womens_room'],
  '🚼': <String>['baby_symbol'], '⚧️': <String>['transgender_symbol'], '🚻': <String>['restroom'],
  '🚮': <String>['litter_in_bin_sign'], '🎦': <String>['cinema'], '📶': <String>['antenna_bars'],
  '🈁': <String>['japanese_here_button'], '🔣': <String>['input_symbols'], 'ℹ️': <String>['information'],
  '🔤': <String>['input_latin_letters'], '🔡': <String>['input_latin_lowercase'],
  '🔠': <String>['input_latin_uppercase'], '🆖': <String>['ng_button'], '🆗': <String>['ok_button'],
  '🆙': <String>['up_button'], '🆒': <String>['cool_button'], '🆕': <String>['new_button'],
  '🆓': <String>['free_button'], '0️⃣': <String>['zero', 'keycap_0'], '1️⃣': <String>['one', 'keycap_1'],
  '2️⃣': <String>['two', 'keycap_2'], '3️⃣': <String>['three', 'keycap_3'],
  '4️⃣': <String>['four', 'keycap_4'], '5️⃣': <String>['five', 'keycap_5'],
  '6️⃣': <String>['six', 'keycap_6'], '7️⃣': <String>['seven', 'keycap_7'],
  '8️⃣': <String>['eight', 'keycap_8'], '9️⃣': <String>['nine', 'keycap_9'], '🔟': <String>['keycap_10'],
  '🔢': <String>['input_numbers'], '#️⃣': <String>['hash', 'keycap_hash'],
  '*️⃣': <String>['asterisk', 'keycap_asterisk'], '⏏️': <String>['eject_button'],
  '▶️': <String>['play_button'], '⏸️': <String>['pause_button'], '⏯️': <String>['play_or_pause_button'],
  '⏹️': <String>['stop_button'], '⏺️': <String>['record_button'], '⏭️': <String>['next_track_button'],
  '⏮️': <String>['last_track_button'], '⏩': <String>['fast_forward_button'],
  '⏪': <String>['fast_reverse_button'], '⏫': <String>['fast_up_button'], '⏬': <String>['fast_down_button'],
  '◀️': <String>['reverse_button'], '🔼': <String>['upwards_button'], '🔽': <String>['downwards_button'],
  '➡️': <String>['right_arrow'], '⬅️': <String>['left_arrow'], '⬆️': <String>['up_arrow'],
  '⬇️': <String>['down_arrow'], '↗️': <String>['up_right_arrow'], '↘️': <String>['down_right_arrow'],
  '↙️': <String>['down_left_arrow'], '↖️': <String>['up_left_arrow'], '↕️': <String>['up_down_arrow'],
  '↔️': <String>['left_right_arrow'], '↩️': <String>['right_arrow_curving_left'],
  '↪️': <String>['left_arrow_curving_right'], '⤴️': <String>['right_arrow_curving_up'],
  '⤵️': <String>['right_arrow_curving_down'], '🔀': <String>['shuffle_tracks_button'],
  '🔁': <String>['repeat_button'], '🔂': <String>['repeat_single_button'],
  '🔄': <String>['counterclockwise_arrows_button'], '🔃': <String>['clockwise_vertical_arrows'],
  '➕': <String>['plus'], '➖': <String>['minus'], '➗': <String>['divide'], '✖️': <String>['multiply'],
  '🟰': <String>['heavy_equals_sign'], '💲': <String>['heavy_dollar_sign'], '💱': <String>['currency_exchange'],
  '〰️': <String>['wavy_dash'], '➰': <String>['curly_loop'], '➿': <String>['double_curly_loop'],
  '🔚': <String>['end_arrow'], '🔙': <String>['back_arrow'], '🔛': <String>['on_arrow'],
  '🔝': <String>['top_arrow'], '🔜': <String>['soon_arrow'], '✔️': <String>['check_mark'],
  '☑️': <String>['check_box_with_check'], '🔘': <String>['radio_button'], '🔴': <String>['red_circle'],
  '🟠': <String>['orange_circle'], '🟡': <String>['yellow_circle'], '🟢': <String>['green_circle'],
  '🔵': <String>['blue_circle'], '🟣': <String>['purple_circle'], '⚫': <String>['black_circle'],
  '⚪': <String>['white_circle'], '🟤': <String>['brown_circle'], '🔺': <String>['red_triangle_pointed_up'],
  '🔻': <String>['red_triangle_pointed_down'], '🔸': <String>['small_orange_diamond'],
  '🔹': <String>['small_blue_diamond'], '🔶': <String>['large_orange_diamond'],
  '🔷': <String>['large_blue_diamond'], '🔳': <String>['white_square_button'],
  '🔲': <String>['black_square_button'], '▪️': <String>['black_small_square'],
  '▫️': <String>['white_small_square'], '◾': <String>['black_medium_small_square'],
  '◽': <String>['white_medium_small_square'], '◼️': <String>['black_medium_square'],
  '◻️': <String>['white_medium_square'], '🟥': <String>['red_square'], '🟧': <String>['orange_square'],
  '🟨': <String>['yellow_square'], '🟩': <String>['green_square'], '🟦': <String>['blue_square'],
  '🟪': <String>['purple_square'], '⬛': <String>['black_large_square'], '⬜': <String>['white_large_square'],
  '🟫': <String>['brown_square'], '🎴': <String>['flower_playing_cards'], '🗜️': <String>['clamp'],
  '💽': <String>['computer_disk'], '💾': <String>['floppy_disk'], '📞': <String>['telephone_receiver'],
  '💸': <String>['money_with_wings'], '⚒️': <String>['hammer_and_pick'], '🚬': <String>['cigarette'],
  '📿': <String>['prayer_beads'], '🪭': <String>['folding_hand_fan'], '🪮': <String>['hair_pick'],
  '🍰': <String>['shortcake'], '🪂': <String>['parachute'], '🏄': <String>['person_surfing'],
  '🏊': <String>['person_swimming'], '🚣': <String>['person_rowing_boat'], '🚴': <String>['person_biking'],
  '🚵': <String>['person_mountain_biking'], '🦯': <String>['white_cane'], '🦽': <String>['manual_wheelchair'],
  '🦼': <String>['motorized_wheelchair'], '🚍': <String>['oncoming_bus'], '🚘': <String>['oncoming_automobile'],
  '🚖': <String>['oncoming_taxi'], '🚡': <String>['aerial_tramway'], '🚠': <String>['mountain_cableway'],
  '🚟': <String>['suspension_railway'], '🚃': <String>['railway_car'], '🚋': <String>['tram_car'],
  '🚈': <String>['light_rail'], '🚂': <String>['locomotive'], '🏘️': <String>['houses'],
  '🏤': <String>['post_office'], '🗾': <String>['map_of_japan'], '🏞️': <String>['national_park'],
  '🌇': <String>['sunset_over_buildings'], '🏙️': <String>['cityscape'], '🌁': <String>['foggy'],
  '🇧🇪': <String>['belgium'], '🇦🇹': <String>['austria'], '🇰🇪': <String>['kenya'], '🇨🇱': <String>['chile'],
  '🇨🇴': <String>['colombia'], '🇵🇪': <String>['peru'], '🇻🇪': <String>['venezuela'],
  '🇲🇾': <String>['malaysia'], '🇵🇰': <String>['pakistan'], '🇧🇩': <String>['bangladesh'],
  '🇨🇿': <String>['czechia'], '🇭🇺': <String>['hungary'], '🇷🇴': <String>['romania'], '🇭🇷': <String>['croatia'],
  '🇷🇸': <String>['serbia'], '🇧🇬': <String>['bulgaria'], '🇸🇰': <String>['slovakia'],
  '🇸🇮': <String>['slovenia'], '🇱🇹': <String>['lithuania'], '🇱🇻': <String>['latvia'],
  '🇪🇪': <String>['estonia'], '🇮🇸': <String>['iceland'], '🇱🇺': <String>['luxembourg'],
  '🇲🇹': <String>['malta'], '🇨🇾': <String>['cyprus'], '🇹🇹': <String>['trinidad_and_tobago'],
  '🇧🇸': <String>['bahamas'], '🇧🇧': <String>['barbados'], '🇩🇴': <String>['dominican_republic'],
  '🇭🇹': <String>['haiti'], '🇵🇦': <String>['panama'], '🇨🇷': <String>['costa_rica'],
  '🇬🇹': <String>['guatemala'], '🇭🇳': <String>['honduras'], '🇸🇻': <String>['el_salvador'],
  '🇳🇮': <String>['nicaragua'], '🇧🇴': <String>['bolivia'], '🇪🇨': <String>['ecuador'],
  '🇺🇾': <String>['uruguay'], '🇵🇾': <String>['paraguay'], '🇬🇾': <String>['guyana'],
};

/// Reverse map of emoji to shortcodes, for search.
Map<String, List<String>> buildEmojiToNames() {
  final map = <String, List<String>>{};
  kEmojiShortcodeMap.forEach((name, emoji) {
    (map[emoji] ??= <String>[]).add(name);
  });
  kEmojiExtraNames.forEach((emoji, names) {
    map.putIfAbsent(emoji, () => List<String>.of(names));
  });
  return map;
}

/// Removes any existing occurrence, prepends, and caps; most recent first.
List<String> addRecentEmoji(List<String> current, String emoji) {
  final next = <String>[emoji, ...current.where((e) => e != emoji)];
  if (next.length > kRecentEmojisCap) {
    return next.sublist(0, kRecentEmojisCap);
  }
  return next;
}

/// Recents persisted under [kRecentEmojisKey] as a JSON array.
class EmojiRecentsStore {
  EmojiRecentsStore(this._prefs);

  final SharedPreferences _prefs;

  /// Tolerates corrupt JSON.
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

  Future<List<String>> add(String emoji) async {
    final next = addRecentEmoji(load(), emoji);
    await _prefs.setString(kRecentEmojisKey, jsonEncode(next));
    return next;
  }
}

/// Picker favorite keys: default-category keys and custom-pack `pubkey:identifier` keys.
const String kEmojiCategoryFavoritesKey = 'nym_emoji_category_favorites';
const String kEmojiPackFavoritesKey = 'nym_emoji_pack_favorites';

/// JSON string-array favorites in SharedPreferences, for categories and packs.
class EmojiFavoritesStore {
  EmojiFavoritesStore(this._prefs, this._key);

  final SharedPreferences _prefs;
  final String _key;

  /// Favorites in insertion order; tolerates corrupt JSON.
  List<String> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return <String>[];
  }

  bool contains(String key) => load().contains(key);

  /// Toggles [key], persists, and returns the new list.
  Future<List<String>> toggle(String key) async {
    final list = load();
    if (!list.remove(key)) list.add(key);
    await _prefs.setString(_key, jsonEncode(list));
    return list;
  }
}

/// Default categories with favorites first in fav-list order, then declared order.
List<String> orderedEmojiCategories(List<String> favorites) {
  final favSet = favorites.toSet();
  final favored = favorites.where(kEmojiCategoryOrder.contains).toList();
  final rest = kEmojiCategoryOrder.where((c) => !favSet.contains(c)).toList();
  return [...favored, ...rest];
}
