const NONCE_BYTES = 16;

function makeNonce() {
  const bytes = new Uint8Array(NONCE_BYTES);
  crypto.getRandomValues(bytes);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function withNonce(policy, nonce) {
  return policy.replace(/(^|;)(\s*)script-src\b/i, (m, sep, ws) => `${sep}${ws}script-src 'nonce-${nonce}'`);
}

async function onRequest(context) {
  const { request, next } = context;
  if (request.method !== 'GET' && request.method !== 'HEAD') return next();

  const resp = await next();
  const type = resp.headers.get('content-type') || '';
  if (!/^text\/html\b/i.test(type)) return resp;
  const policy = resp.headers.get('content-security-policy');
  if (!policy || !/\bscript-src\b/i.test(policy)) return resp;

  const nonce = makeNonce();
  const out = new Response(resp.body, resp);
  out.headers.set('content-security-policy', withNonce(policy, nonce));

  return new HTMLRewriter()
    .on('meta[http-equiv="Content-Security-Policy"]', {
      element(el) {
        const content = el.getAttribute('content');
        if (content && /\bscript-src\b/i.test(content)) el.setAttribute('content', withNonce(content, nonce));
      }
    })
    .transform(out);
}

export { onRequest, withNonce };
