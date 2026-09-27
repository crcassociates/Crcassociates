// Connects this project to Raken with Raken's one-time browser approval (OAuth).
//
//   POST /raken-auth                          Service key required. Returns a Raken approval link.
//   GET  /raken-auth/callback/<state>?code=   Raken sends the approver back here after approval.
//
// HARD RULE: Raken is READ-ONLY. This function only signs in and reads the
// approver's own user info. It never changes anything in Raken.

import {
  adminClient,
  env,
  expiresAt,
  isServiceCaller,
  json,
  loadTokens,
  RAKEN_AUTHORIZE_URL,
  rakenGet,
  requestToken,
  saveTokens,
  timingSafeEqual,
} from "../_shared/raken.ts";

const LINK_TTL_MS = 15 * 60 * 1000;
const ADMIN_ROLES = ["ROLE_ACCOUNT_ADMIN", "ROLE_ADMIN"];

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sign(payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env("Raken_secret")),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return base64url(new Uint8Array(signature));
}

// State "<expiry>.<nonce>.<signature>" proves the approval was started from here.
async function createState(): Promise<string> {
  const payload = `${Date.now() + LINK_TTL_MS}.${base64url(crypto.getRandomValues(new Uint8Array(16)))}`;
  return `${payload}.${await sign(payload)}`;
}

async function isValidState(state: string): Promise<boolean> {
  const [expiry, nonce, signature, ...rest] = state.split(".");
  if (!expiry || !nonce || !signature || rest.length > 0) return false;
  if (!(Number(expiry) > Date.now())) return false;
  return timingSafeEqual(await sign(`${expiry}.${nonce}`), signature);
}

// The state is part of the path, so it survives however Raken appends ?code=.
function callbackUrl(state: string): string {
  return `${env("SUPABASE_URL")}/functions/v1/raken-auth/callback/${state}`;
}

// Supabase serves function pages as plain text, so replies are plain text.
function text(message: string, status = 200): Response {
  return new Response(`${message}\n`, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const callback = url.pathname.match(/\/raken-auth\/callback\/([^/]+)\/?$/);

  if (req.method === "GET" && callback) return await handleCallback(url, callback[1]);

  if (req.method === "POST") {
    if (!isServiceCaller(req)) return json({ error: "Not allowed" }, 401);
    const state = await createState();
    const link = new URL(RAKEN_AUTHORIZE_URL);
    link.searchParams.set("response_type", "code");
    link.searchParams.set("client_id", env("Client_ID"));
    link.searchParams.set("redirect_uri", callbackUrl(state));
    link.searchParams.set("state", state);
    return json({ authorize_url: link.toString(), expires_in_minutes: LINK_TTL_MS / 60000 });
  }

  return json({ error: "Not found" }, 404);
});

async function handleCallback(url: URL, state: string): Promise<Response> {
  const rakenError = url.searchParams.get("error");
  if (rakenError) return text(`Raken approval was cancelled or failed (${rakenError}). Nothing was changed.`, 400);

  const code = url.searchParams.get("code");
  if (!code) return text("Raken did not send an approval code. Nothing was changed.", 400);
  if (!(await isValidState(state))) {
    return text("This approval link has expired or is not valid. Ask for a new link. Nothing was changed.", 400);
  }

  try {
    const tokens = await requestToken({ grant_type: "authorization_code", code, redirect_uri: callbackUrl(state) });
    // Read-only: find out who approved, to confirm the right account.
    const info = await rakenGet(tokens.access_token, "/userInfo");

    const db = adminClient();
    const existing = await loadTokens(db);
    if (existing?.company_uuid && info.companyUuid && existing.company_uuid !== info.companyUuid) {
      return text("This Raken account belongs to a different company than the one already connected. Nothing was changed.", 409);
    }

    const name = [info.firstName, info.lastName].filter(Boolean).join(" ") || "unknown user";
    await saveTokens(db, {
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token ?? "",
      expires_at: expiresAt(tokens.expires_in),
      company_uuid: info.companyUuid,
      connected_as: { name, email: info.email ?? "", role: info.role ?? "" },
      connected_at: new Date().toISOString(),
    });

    const roleNote = ADMIN_ROLES.includes(info.role)
      ? ""
      : `\n\nNote: this account's role is ${info.role}. The sync only sees what this account can see; ` +
        "an Account Administrator is recommended.";
    return text(`Raken is connected for the read-only sync, as ${name} (${info.email}).${roleNote}\n\nYou can close this window.`);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    console.error("Raken connect failed:", message);
    return text(`Connecting Raken failed: ${message}`, 500);
  }
}
