// Enrollment endpoint for app attestation.

import { CLIENT_CORS_HEADERS, verifyClientAuth } from "./_shared.js";
import { isNymchatClient } from "./_client.js";
import {
  BADGE_TTL_DAYS,
  ATTESTED_PLATFORMS,
  PLATFORMS,
  authorityPubkey,
  authoritySecret,
  issueBadge,
  issueChallenge,
  verifyChallenge,
  verifyAppAttest,
  verifyPlayIntegrity,
  enrollPowBits,
  enrollPowOk,
  buildManifestFiles,
  buildProbePaths,
  verifyBuildProof,
  attestDb,
  ensureAttestSchema,
  deviceAtCap,
  recordAttestation,
  lookupAttestations,
  listRevoked,
  isRevoked
} from "./_attest.js";

const JSON_HEADERS = { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS };
const DAY_MS = 86400000;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function isHex64(s) {
  return typeof s === "string" && /^[0-9a-f]{64}$/.test(s);
}

function authTag(auth, name) {
  const tags = auth && Array.isArray(auth.tags) ? auth.tags : [];
  for (const t of tags) if (Array.isArray(t) && t[0] === name) return t[1];
  return null;
}

const ENROLL_AUTH_MAX_AGE_SEC = 600;

async function handleEnroll(context, body) {
  const { request, env } = context;
  const db = attestDb(env);
  if (!db) return json({ error: "Ledger unavailable" }, 503);
  if (!authoritySecret(env)) return json({ error: "Attestation not configured" }, 503);

  const pubkey = typeof body.pubkey === "string" ? body.pubkey.toLowerCase() : "";
  const platform = typeof body.platform === "string" ? body.platform.toLowerCase() : "";
  const challenge = typeof body.challenge === "string" ? body.challenge : "";
  if (!isHex64(pubkey)) return json({ error: "Bad pubkey" }, 400);
  if (!PLATFORMS.has(platform)) return json({ error: "Bad platform" }, 400);

  // The auth event proves the pubkey asked for this, and carrying the challenge
  // in a tag means a captured auth cannot be paired with a fresh challenge.
  if (!verifyClientAuth(body.auth, pubkey, { action: "attest-enroll", url: request.url, maxAgeSec: ENROLL_AUTH_MAX_AGE_SEC })) {
    return json({ error: "Bad auth" }, 401);
  }
  if (authTag(body.auth, "challenge") !== challenge) return json({ error: "Auth/challenge mismatch" }, 401);
  if (!verifyChallenge(env, pubkey, challenge)) return json({ error: "Bad challenge" }, 401);

  await ensureAttestSchema(db);
  // A revoked key stays revoked until an operator clears the row; letting it
  // re-enroll would make revocation a speed bump rather than a decision.
  if (await isRevoked(db, pubkey)) return json({ error: "Revoked" }, 403);

  let tier = "origin";
  let deviceId = null;
  // Why a native install is on the challenged tier rather than attested: the
  // platform verdict when the app was not recognized, or the refusal the app
  // reports when it comes back for the build-proof path after one.
  let reason = null;

  // A native app that could not produce a platform proof (no Play Services,
  // no Secure Enclave, a refused verdict) enrolls on the build-proof path
  // like the web app does, but is still recorded as the platform it is.
  const hasPlatformProof = platform === "ios"
    ? typeof body.keyId === "string" && typeof body.attestation === "string"
    : platform === "android" ? typeof body.token === "string" && body.token.length > 0 : false;
  if (ATTESTED_PLATFORMS.has(platform) && !hasPlatformProof && typeof body.refusal === "string") {
    reason = body.refusal.replace(/[^\w .:()-]/g, "").slice(0, 80) || null;
  }

  const platformResult = ATTESTED_PLATFORMS.has(platform) && hasPlatformProof
    ? (platform === "ios"
      ? await verifyAppAttest(env, { keyId: body.keyId, attestation: body.attestation, challenge })
      : await verifyPlayIntegrity(env, { token: body.token, challenge }))
    : null;

  const sideloaded = platformResult && !platformResult.ok
    && (platformResult.reason === "app-not-recognized"
      || platformResult.reason === "signature-mismatch");

  if (platformResult && platformResult.ok) {
    tier = "attested";
    deviceId = platformResult.deviceId || null;
    if (await deviceAtCap(db, deviceId, pubkey)) return json({ error: "Device enrollment cap" }, 429);
  } else if (platformResult && !sideloaded) {
    return json({ error: "Attestation failed", reason: platformResult.reason }, 403);
  } else if (sideloaded) {
    if (!enrollPowOk(env, body.auth)) {
      return json({ error: "Enrollment work insufficient", need: enrollPowBits(env) }, 403);
    }
    tier = "challenged";
    reason = platformResult.reason;
  } else {
    if (!isNymchatClient(request, env)) return json({ error: "Forbidden" }, 403);
    if (!enrollPowOk(env, body.auth)) {
      return json({ error: "Enrollment work insufficient", need: enrollPowBits(env) }, 403);
    }
    const proof = await verifyBuildProof(new URL(request.url).origin, challenge, body.build, env);
    if (!proof.ok) return json({ error: "Build proof failed", reason: proof.reason }, 403);
    tier = "challenged";
  }

  const expiresAt = Date.now() + BADGE_TTL_DAYS * DAY_MS;
  await recordAttestation(db, { pubkey, platform, tier, deviceId, expiresAt, reason });
  const badge = issueBadge(env, pubkey, tier);
  if (!badge) return json({ error: "Attestation not configured" }, 503);

  return json({ badge, tier, platform, expiresAt, authority: authorityPubkey(env) });
}

async function routeAttestAction(context, body) {
  const { env } = context;
  const action = body && typeof body.action === "string" ? body.action : "";

  if (action === "pubkey") {
    const pk = authorityPubkey(env);
    return pk ? json({ authority: pk }) : json({ error: "Attestation not configured" }, 503);
  }

  if (action === "challenge") {
    const pubkey = typeof body.pubkey === "string" ? body.pubkey.toLowerCase() : "";
    if (!isHex64(pubkey)) return json({ error: "Bad pubkey" }, 400);
    const issued = issueChallenge(env, pubkey);
    if (!issued) return json({ error: "Attestation not configured" }, 503);
    // The paths this enrollment must account for. Derived from the challenge,
    // so nothing is stored between here and the enroll call, and the caller
    // cannot pick which files it is asked about.
    const files = await buildManifestFiles(new URL(context.request.url).origin, env);
    if (files) issued.buildProbe = buildProbePaths(files, issued.challenge, 4);
    // Web clients mine their auth event to this before signing it. Native
    // clients ignore it: hardware attestation is a stronger proof than any
    // amount of hashing, and the per-device cap already bounds them.
    issued.powBits = enrollPowBits(env);
    return json(issued);
  }

  if (action === "enroll") return handleEnroll(context, body);

  if (action === "lookup") {
    const db = attestDb(env);
    if (!db) return json({ error: "Ledger unavailable" }, 503);
    await ensureAttestSchema(db);
    return json({ attested: await lookupAttestations(db, body.pubkeys) });
  }

  if (action === "revoked") {
    const db = attestDb(env);
    if (!db) return json({ error: "Ledger unavailable" }, 503);
    await ensureAttestSchema(db);
    const since = Number(body.since);
    const rows = await listRevoked(db, Number.isFinite(since) ? since : 0);
    return json({
      revoked: rows.map((r) => r.pubkey),
      until: rows.length ? Number(rows[rows.length - 1].revoked_at) : (Number.isFinite(since) ? since : 0)
    });
  }

  return json({ error: "Unknown action" }, 400);
}

async function onRequest(context) {
  const { request } = context;

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CLIENT_CORS_HEADERS });
  }
  if (request.method !== "POST") return json({ error: "POST required" }, 405);
  if (!isNymchatClient(request, context.env)) return json({ error: "Forbidden" }, 403);

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  return routeAttestAction(context, body);
}

export { onRequest, routeAttestAction };
