export var AT_REST_SIDE_KEYS = [
  "pendingTool", "followUps", "sources", "plan", "steerOffer", "staged", "actions",
  "team", "serverRuns", "checkpoint", "text", "reply", "draft", "summary", "prompt", "label"
];

export function atRestSplit(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { rest: body, side: null };
  var rest = {};
  var side = {};
  var any = false;
  Object.keys(body).forEach(function (k) {
    if (AT_REST_SIDE_KEYS.indexOf(k) >= 0) {
      if (body[k] !== undefined) {
        side[k] = body[k];
        any = true;
      }
    } else {
      rest[k] = body[k];
    }
  });
  return { rest: rest, side: any ? side : null };
}

export function atRestJoin(body, side) {
  if (!side || typeof side !== "object" || !body || typeof body !== "object" || Array.isArray(body)) return body;
  return Object.assign({}, body, side);
}

export class LiveStore {
  constructor(maxEntries, maxChars) {
    this.maxEntries = maxEntries;
    this.maxChars = maxChars;
    this.map = new Map();
    this.chars = 0;
  }

  get(key, now) {
    var e = this.map.get(key);
    if (!e) return null;
    if (e.exp < now) {
      this.delete(key);
      return null;
    }
    return e.value;
  }

  set(key, value, exp, chars) {
    this.delete(key);
    var size = Math.max(1, Math.floor(Number(chars) || 0));
    if (size > this.maxChars) return false;
    this.map.set(key, { value: value, exp: exp, chars: size });
    this.chars += size;
    while (this.map.size > this.maxEntries || this.chars > this.maxChars) {
      this.delete(this.map.keys().next().value);
    }
    return true;
  }

  delete(key) {
    var e = this.map.get(key);
    if (!e) return;
    this.map.delete(key);
    this.chars -= e.chars;
  }

  sweep(now) {
    for (var [k, e] of this.map) {
      if (e.exp < now) this.delete(k);
    }
  }
}
