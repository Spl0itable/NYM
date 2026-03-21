// Cloudflare Pages Function: Nymchat Bot
// A Nostr bot that connects to relays, subscribes to kind 20000 events,
// and responds to commands from nymchat clients.
//
// Commands:
//   !help              - List available commands
//   !top               - Top channels by message activity
//   !last              - Last 10 messages across all channels
//   !ask <question>    - Ask the AI a question
//   !seen <nickname>   - Where was a person last seen
//   !who               - Who's been active recently
//   !stats             - Bot uptime and statistics
//   !roll [NdN]        - Roll dice (e.g., !roll 2d6)
//   !flip              - Flip a coin
//   !8ball <question>  - Magic 8-ball

import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';

// Nostr Helpers
function getPublicKey(privkeyHex) {
  return bytesToHex(schnorr.getPublicKey(privkeyHex));
}

function serializeEvent(evt) {
  return JSON.stringify([
    0,
    evt.pubkey,
    evt.created_at,
    evt.kind,
    evt.tags,
    evt.content,
  ]);
}

function getEventHash(evt) {
  const serialized = serializeEvent(evt);
  const encoder = new TextEncoder();
  return bytesToHex(sha256(encoder.encode(serialized)));
}

function signEvent(evt, privkeyHex) {
  const hash = getEventHash(evt);
  evt.id = hash;
  evt.sig = bytesToHex(schnorr.sign(hash, privkeyHex));
  return evt;
}

// Default Relays
const BOT_RELAYS = [
  'wss://relay.damus.io',
  'wss://offchain.pub',
  'wss://relay.primal.net',
  'wss://nos.lol',
  'wss://nostr21.com',
  'wss://relay.snort.social',
  'wss://relay.nostr.net',
  'wss://nostr-pub.wellorder.net',
  'wss://relay1.nostrchat.io',
  'wss://relay.0xchat.com',
];

const BOT_NYM = 'nymbot';
const BOT_AVATAR = 'https://nymchat.app/images/NYM-favicon.png';
const BOT_BANNER = 'https://nymchat.app/images/NYM-icon.png';
const BOT_ABOUT = 'Nymchat bot — type !help for commands';
const COMMAND_PREFIX = '!';
const COOLDOWN_MS = 2000; // Per-channel command cooldown
const MAX_STORED_MESSAGES = 500; // Max messages to keep in memory per channel
const MAX_CHANNELS = 1000; // Max channels to track

// Main Handler
export async function onRequest(context) {
  const { request } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response(JSON.stringify({
      status: 'ok',
      info: 'Nymchat Bot endpoint. Connect via WebSocket to activate.',
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Get bot private key from environment
  const privkey = context.env.BOT_PRIVKEY;
  if (!privkey) {
    server.send(JSON.stringify(['BOT:ERROR', 'BOT_PRIVKEY environment variable not set']));
    server.close(1008, 'Missing BOT_PRIVKEY');
    return new Response(null, { status: 101, webSocket: client });
  }

  let pubkey;
  try {
    pubkey = getPublicKey(privkey);
  } catch (e) {
    server.send(JSON.stringify(['BOT:ERROR', 'Invalid BOT_PRIVKEY: ' + e.message]));
    server.close(1008, 'Invalid BOT_PRIVKEY');
    return new Response(null, { status: 101, webSocket: client });
  }

  // Bot state
  const state = {
    serverOpen: true,
    pubkey,
    privkey,
    profilePublished: false,
    startedAt: Date.now(),
    messagesProcessed: 0,
    commandsHandled: 0,
    channelMessages: new Map(),   // geohash -> [{ nym, content, created_at, pubkey }]
    nymActivity: new Map(),       // nym -> { lastSeen, channel, lastMessage }
    channelActivity: new Map(),   // geohash -> { count, lastActive }
    commandCooldowns: new Map(),  // geohash -> lastCommandTimestamp
    upstreams: new Map(),         // relayUrl -> WebSocket
    seenEvents: new Set(),
    ai: context.env.AI || null,
  };

  // Send status to controller
  function sendStatus(msg) {
    try {
      if (state.serverOpen && server.readyState === 1) {
        server.send(JSON.stringify(['BOT:STATUS', msg]));
      }
    } catch { /* noop */ }
  }

  sendStatus(`Bot activated. Pubkey: ${pubkey}`);
  sendStatus(`Connecting to ${BOT_RELAYS.length} relays...`);

  // Connect to all relays
  for (const relayUrl of BOT_RELAYS) {
    connectToRelay(relayUrl, state, server, sendStatus, context);
  }

  // Keepalive ping
  const keepalive = setInterval(() => {
    try {
      if (state.serverOpen && server.readyState === 1) {
        server.send(JSON.stringify(['BOT:PING', Date.now()]));
      } else {
        clearInterval(keepalive);
      }
    } catch {
      clearInterval(keepalive);
    }
  }, 30000);

  // Handle controller messages
  server.addEventListener('message', (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (Array.isArray(msg) && msg[0] === 'BOT:STATUS_REQ') {
        sendStatus({
          uptime: Math.floor((Date.now() - state.startedAt) / 1000),
          messagesProcessed: state.messagesProcessed,
          commandsHandled: state.commandsHandled,
          connectedRelays: [...state.upstreams.entries()]
            .filter(([, ws]) => ws.readyState === WebSocket.OPEN).length,
          channelsTracked: state.channelActivity.size,
          nymsTracked: state.nymActivity.size,
        });
      }
    } catch { /* noop */ }
  });

  // Cleanup on disconnect
  function cleanup() {
    state.serverOpen = false;
    clearInterval(keepalive);
    for (const [, ws] of state.upstreams) {
      try { ws.close(); } catch { /* noop */ }
    }
    state.upstreams.clear();
  }

  server.addEventListener('close', cleanup);
  server.addEventListener('error', cleanup);

  return new Response(null, { status: 101, webSocket: client });
}

// Relay Connection
function connectToRelay(relayUrl, state, server, sendStatus, context) {
  if (state.upstreams.has(relayUrl)) return;

  try {
    const ws = new WebSocket(relayUrl);
    state.upstreams.set(relayUrl, ws);

    const timeout = setTimeout(() => {
      if (ws.readyState !== WebSocket.OPEN) {
        try { ws.close(); } catch { /* noop */ }
        state.upstreams.delete(relayUrl);
      }
    }, 10000);

    ws.addEventListener('open', () => {
      clearTimeout(timeout);
      sendStatus(`Connected to ${relayUrl}`);

      // Publish kind 0 profile on first relay connection
      if (!state.profilePublished) {
        state.profilePublished = true;
        publishProfile(state);
        sendStatus(`Published nymbot profile (pubkey: ${state.pubkey.slice(0, 8)}...)`);
      }

      // Subscribe to kind 20000 events (last 1 hour)
      const since = Math.floor(Date.now() / 1000) - 3600;
      const subId = 'bot-' + Math.random().toString(36).slice(2, 8);
      ws.send(JSON.stringify([
        'REQ', subId,
        { kinds: [20000], since, limit: 200 }
      ]));
    });

    ws.addEventListener('message', (event) => {
      handleRelayMessage(event.data, relayUrl, state, sendStatus, context);
    });

    ws.addEventListener('close', () => {
      clearTimeout(timeout);
      state.upstreams.delete(relayUrl);
      // Reconnect after delay
      if (state.serverOpen) {
        setTimeout(() => connectToRelay(relayUrl, state, server, sendStatus, context), 5000);
      }
    });

    ws.addEventListener('error', () => {
      clearTimeout(timeout);
      state.upstreams.delete(relayUrl);
    });
  } catch {
    state.upstreams.delete(relayUrl);
  }
}

// Relay Message Handler
function handleRelayMessage(raw, relayUrl, state, sendStatus, context) {
  if (typeof raw !== 'string') return;

  let msg;
  try {
    msg = JSON.parse(raw);
  } catch { return; }

  if (!Array.isArray(msg)) return;

  if (msg[0] === 'EVENT' && msg.length >= 3) {
    const event = msg[2];
    if (!event || event.kind !== 20000) return;

    // Dedup
    if (state.seenEvents.has(event.id)) return;
    state.seenEvents.add(event.id);

    // Trim seen events
    if (state.seenEvents.size > 10000) {
      const arr = [...state.seenEvents];
      state.seenEvents = new Set(arr.slice(-8000));
    }

    // Ignore our own messages
    if (event.pubkey === state.pubkey) return;

    // Check for nymchat client tag — only process nymchat messages
    const clientTag = event.tags.find(t => t[0] === 'client');
    if (!clientTag || clientTag[1] !== 'nymchat') return;

    state.messagesProcessed++;

    // Extract event metadata
    const nymTag = event.tags.find(t => t[0] === 'n');
    const geoTag = event.tags.find(t => t[0] === 'g');
    const nym = nymTag ? nymTag[1] : 'anon';
    const geohash = geoTag ? geoTag[1] : 'nym';
    const content = (event.content || '').trim();

    // Track activity
    trackMessage(state, nym, geohash, content, event.created_at, event.pubkey);

    // Check for commands
    if (content.startsWith(COMMAND_PREFIX)) {
      processCommand(content, nym, geohash, state, sendStatus, context);
    }
  }
}

// Activity Tracking
function trackMessage(state, nym, geohash, content, created_at, pubkey) {
  // Track per-channel messages
  if (!state.channelMessages.has(geohash)) {
    if (state.channelMessages.size >= MAX_CHANNELS) {
      // Evict least active channel
      let oldestChannel = null;
      let oldestTime = Infinity;
      for (const [ch, msgs] of state.channelMessages) {
        if (msgs.length > 0 && msgs[msgs.length - 1].created_at < oldestTime) {
          oldestTime = msgs[msgs.length - 1].created_at;
          oldestChannel = ch;
        }
      }
      if (oldestChannel) state.channelMessages.delete(oldestChannel);
    }
    state.channelMessages.set(geohash, []);
  }

  const msgs = state.channelMessages.get(geohash);
  msgs.push({ nym, content, created_at, pubkey });
  if (msgs.length > MAX_STORED_MESSAGES) {
    msgs.splice(0, msgs.length - MAX_STORED_MESSAGES);
  }

  // Track nym activity
  state.nymActivity.set(nym.toLowerCase(), {
    nym, // preserve original casing
    lastSeen: created_at,
    channel: geohash,
    lastMessage: content.length > 100 ? content.slice(0, 100) + '...' : content,
    pubkey,
  });

  // Track channel activity
  const chActivity = state.channelActivity.get(geohash) || { count: 0, lastActive: 0 };
  chActivity.count++;
  chActivity.lastActive = created_at;
  state.channelActivity.set(geohash, chActivity);
}

// Command Processing
async function processCommand(content, nym, geohash, state, sendStatus, context) {
  // Cooldown per channel
  const now = Date.now();
  const lastCmd = state.commandCooldowns.get(geohash) || 0;
  if (now - lastCmd < COOLDOWN_MS) return;
  state.commandCooldowns.set(geohash, now);

  const parts = content.slice(COMMAND_PREFIX.length).trim().split(/\s+/);
  const command = parts[0].toLowerCase();
  const args = parts.slice(1).join(' ');

  let response;

  try {
    switch (command) {
      case 'help':
        response = handleHelp();
        break;
      case 'top':
        response = handleTop(state);
        break;
      case 'last':
        response = handleLast(state, args);
        break;
      case 'ask':
        response = await handleAsk(args, state, context);
        break;
      case 'seen':
        response = handleSeen(args, state);
        break;
      case 'who':
        response = handleWho(state);
        break;
      case 'stats':
        response = handleStats(state);
        break;
      case 'roll':
        response = handleRoll(args);
        break;
      case 'flip':
        response = handleFlip();
        break;
      case '8ball':
        response = handleEightBall(args);
        break;
      default:
        return; // Unknown command, ignore
    }
  } catch (e) {
    response = `Error processing command: ${e.message}`;
    sendStatus(`Command error: ${e.message}`);
  }

  if (response) {
    state.commandsHandled++;
    sendStatus(`Command !${command} from ${nym} in #${geohash}`);
    publishResponse(response, geohash, state);
  }
}

// Command Handlers
function handleHelp() {
  return [
    'nymbot commands:',
    '!top — Top channels by activity',
    '!last [N] — Last N messages (default 10)',
    '!ask <question> — Ask the AI',
    '!seen <nickname> — Find where someone was last seen',
    '!who — Active users recently',
    '!stats — Bot statistics',
    '!roll [NdN] — Roll dice (e.g. 2d6)',
    '!flip — Flip a coin',
    '!8ball <question> — Magic 8-ball',
  ].join('\n');
}

function handleTop(state) {
  if (state.channelActivity.size === 0) {
    return 'No channel activity recorded yet.';
  }

  const sorted = [...state.channelActivity.entries()]
    .sort((a, b) => b[1].count - a[1].count)
    .slice(0, 10);

  const lines = ['Top channels by activity:'];
  sorted.forEach(([geohash, info], i) => {
    const ago = timeSince(info.lastActive);
    lines.push(`${i + 1}. #${geohash} — ${info.count} msgs (last: ${ago})`);
  });

  return lines.join('\n');
}

function handleLast(state, args) {
  const count = Math.min(Math.max(parseInt(args) || 10, 1), 25);

  // Collect all messages across channels
  const allMessages = [];
  for (const [geohash, msgs] of state.channelMessages) {
    for (const msg of msgs) {
      allMessages.push({ ...msg, geohash });
    }
  }

  if (allMessages.length === 0) {
    return 'No messages recorded yet.';
  }

  // Sort by time, most recent last
  allMessages.sort((a, b) => a.created_at - b.created_at);
  const recent = allMessages.slice(-count);

  const lines = [`Last ${recent.length} messages:`];
  for (const msg of recent) {
    const ago = timeSince(msg.created_at);
    const preview = msg.content.length > 80
      ? msg.content.slice(0, 80) + '...'
      : msg.content;
    lines.push(`[#${msg.geohash}] ${msg.nym} (${ago}): ${preview}`);
  }

  return lines.join('\n');
}

async function handleAsk(question, state, context) {
  if (!question.trim()) {
    return 'Usage: !ask <your question>';
  }

  // Try Cloudflare Workers AI first
  if (state.ai) {
    try {
      const result = await state.ai.run('@cf/meta/llama-3.3-70b-instruct-fp8-fast', {
        messages: [
          {
            role: 'system',
            content: 'You are nymbot, a helpful assistant in the Nymchat decentralized chat application built on the Nostr protocol. Keep responses concise (under 300 characters when possible). Be friendly and informative.',
          },
          { role: 'user', content: question },
        ],
        max_tokens: 256,
      });

      if (result && result.response) {
        return result.response;
      }
    } catch (e) {
      // Fall through to fallback
    }
  }

  // Fallback: try free DuckDuckGo-style approach via Cloudflare AI Gateway
  // or return a helpful message about configuring AI
  return `AI is not configured. To enable !ask, add a Workers AI binding named "AI" in your Cloudflare Pages project settings (Settings → Functions → AI bindings). It's free for up to 10,000 neurons/day.`;
}

function handleSeen(nickname, state) {
  if (!nickname.trim()) {
    return 'Usage: !seen <nickname>';
  }

  const key = nickname.trim().toLowerCase();
  const info = state.nymActivity.get(key);

  if (!info) {
    return `Haven't seen "${nickname}" since the bot started.`;
  }

  const ago = timeSince(info.lastSeen);
  return `${info.nym} was last seen in #${info.channel} (${ago}): "${info.lastMessage}"`;
}

function handleWho(state) {
  const oneHourAgo = Math.floor(Date.now() / 1000) - 3600;

  const activeNyms = [...state.nymActivity.values()]
    .filter(info => info.lastSeen > oneHourAgo)
    .sort((a, b) => b.lastSeen - a.lastSeen);

  if (activeNyms.length === 0) {
    return 'No active users in the last hour.';
  }

  const lines = [`Active users (last hour): ${activeNyms.length}`];
  for (const info of activeNyms.slice(0, 20)) {
    const ago = timeSince(info.lastSeen);
    lines.push(`• ${info.nym} in #${info.channel} (${ago})`);
  }

  if (activeNyms.length > 20) {
    lines.push(`...and ${activeNyms.length - 20} more`);
  }

  return lines.join('\n');
}

function handleStats(state) {
  const uptimeSeconds = Math.floor((Date.now() - state.startedAt) / 1000);
  const hours = Math.floor(uptimeSeconds / 3600);
  const minutes = Math.floor((uptimeSeconds % 3600) / 60);
  const seconds = uptimeSeconds % 60;

  const connectedRelays = [...state.upstreams.entries()]
    .filter(([, ws]) => ws.readyState === WebSocket.OPEN).length;

  return [
    'nymbot stats:',
    `Uptime: ${hours}h ${minutes}m ${seconds}s`,
    `Relays: ${connectedRelays}/${BOT_RELAYS.length} connected`,
    `Messages seen: ${state.messagesProcessed}`,
    `Commands handled: ${state.commandsHandled}`,
    `Channels tracked: ${state.channelActivity.size}`,
    `Users tracked: ${state.nymActivity.size}`,
  ].join('\n');
}

function handleRoll(args) {
  let numDice = 1;
  let sides = 6;

  if (args.trim()) {
    const match = args.trim().match(/^(\d+)d(\d+)$/i);
    if (match) {
      numDice = Math.min(parseInt(match[1]), 20);
      sides = Math.min(parseInt(match[2]), 100);
    } else {
      const num = parseInt(args.trim());
      if (!isNaN(num) && num > 0) {
        sides = Math.min(num, 100);
      }
    }
  }

  if (numDice < 1 || sides < 2) {
    return 'Usage: !roll [NdN] (e.g., !roll 2d6)';
  }

  const rolls = [];
  let total = 0;
  for (let i = 0; i < numDice; i++) {
    const val = Math.floor(Math.random() * sides) + 1;
    rolls.push(val);
    total += val;
  }

  if (numDice === 1) {
    return `🎲 Rolled d${sides}: ${total}`;
  }
  return `🎲 Rolled ${numDice}d${sides}: [${rolls.join(', ')}] = ${total}`;
}

function handleFlip() {
  return Math.random() < 0.5 ? '🪙 Heads!' : '🪙 Tails!';
}

function handleEightBall(question) {
  if (!question.trim()) {
    return 'Usage: !8ball <your question>';
  }

  const responses = [
    'It is certain.',
    'It is decidedly so.',
    'Without a doubt.',
    'Yes, definitely.',
    'You may rely on it.',
    'As I see it, yes.',
    'Most likely.',
    'Outlook good.',
    'Yes.',
    'Signs point to yes.',
    'Reply hazy, try again.',
    'Ask again later.',
    'Better not tell you now.',
    'Cannot predict now.',
    'Concentrate and ask again.',
    "Don't count on it.",
    'My reply is no.',
    'My sources say no.',
    'Outlook not so good.',
    'Very doubtful.',
  ];

  const idx = Math.floor(Math.random() * responses.length);
  return `🎱 ${responses[idx]}`;
}

// Publish Profile (Kind 0)
function publishProfile(state) {
  const now = Math.floor(Date.now() / 1000);

  const profileContent = JSON.stringify({
    name: BOT_NYM,
    display_name: BOT_NYM,
    about: BOT_ABOUT,
    picture: BOT_AVATAR,
    banner: BOT_BANNER,
    nip05: '',
    bot: true,
  });

  const event = {
    kind: 0,
    created_at: now,
    tags: [],
    content: profileContent,
    pubkey: state.pubkey,
  };

  const signed = signEvent(event, state.privkey);
  const msg = JSON.stringify(['EVENT', signed]);

  // Publish to all connected relays
  for (const [, ws] of state.upstreams) {
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.send(msg); } catch { /* noop */ }
    }
  }
}

// Publish Response
function publishResponse(content, geohash, state) {
  const now = Math.floor(Date.now() / 1000);

  const event = {
    kind: 20000,
    created_at: now,
    tags: [
      ['n', BOT_NYM],
      ['client', 'nymchat'],
      ['bot', 'nymchat'],
      ['g', geohash],
    ],
    content,
    pubkey: state.pubkey,
  };

  const signed = signEvent(event, state.privkey);

  const msg = JSON.stringify(['EVENT', signed]);

  // Publish to all connected relays
  for (const [, ws] of state.upstreams) {
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.send(msg); } catch { /* noop */ }
    }
  }
}

// Utilities
function timeSince(unixTimestamp) {
  const seconds = Math.floor(Date.now() / 1000) - unixTimestamp;
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}
