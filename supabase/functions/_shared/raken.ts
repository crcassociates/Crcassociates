// Raken API access for the sync.
//
// HARD RULE: Raken is READ-ONLY. This module can only send GET requests to the
// Raken API. The single exception is requestToken(), the OAuth sign-in that
// gets an access token; it creates or changes no Raken data. Do not add any
// function that sends POST/PATCH/PUT/DELETE to the Raken API.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const RAKEN_API = "https://developer.rakenapp.com/api";
const RAKEN_TOKEN_URL = "https://app.rakenapp.com/oauth/token";
export const RAKEN_AUTHORIZE_URL = "https://app.rakenapp.com/oauth/authorize";

const PAGE_SIZE = 1000; // Raken's maximum page size

export type StoredTokens = {
  access_token: string;
  refresh_token: string;
  expires_at: string; // ISO time
  company_uuid?: string;
  connected_as?: { name: string; email: string; role: string };
  connected_at?: string;
  refreshed_at?: string;
};

export class RakenAuthError extends Error {}

export function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

// Service keys for this project: the legacy service_role key and any new-style secret keys.
function serviceKeys(): string[] {
  const keys: string[] = [];
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) keys.push(legacy);
  const secretKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (secretKeys) {
    try {
      for (const value of Object.values(JSON.parse(secretKeys))) {
        if (typeof value === "string") keys.push(value);
      }
    } catch {
      // Ignore a malformed value; the legacy key may still be present.
    }
  }
  return keys;
}

export function adminClient(): SupabaseClient {
  const key = serviceKeys()[0];
  if (!key) throw new Error("No service key available");
  return createClient(env("SUPABASE_URL"), key, { auth: { persistSession: false } });
}

export function timingSafeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

// True when the caller sent one of this project's service keys.
export function isServiceCaller(req: Request): boolean {
  const auth = req.headers.get("Authorization") ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  const apikey = req.headers.get("apikey") ?? "";
  return serviceKeys().some((k) =>
    (bearer !== "" && timingSafeEqual(bearer, k)) || (apikey !== "" && timingSafeEqual(apikey, k))
  );
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Read-only Raken API calls
// ---------------------------------------------------------------------------

type Params = Record<string, string | number | undefined>;

// The only way this code talks to the Raken API: a GET request.
export async function rakenGet(accessToken: string, path: string, params: Params = {}): Promise<any> {
  if (!path.startsWith("/") || path.includes("://")) throw new Error(`Invalid Raken path: ${path}`);
  const url = new URL(RAKEN_API + path);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== "") url.searchParams.set(key, String(value));
  }

  for (let attempt = 1; ; attempt++) {
    const res = await fetch(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" },
    });
    if (res.ok) return await res.json();

    const text = await res.text();
    if (res.status === 401) throw new RakenAuthError(`Raken rejected the access token (GET ${path})`);
    if (res.status === 429 && attempt < 6) {
      const retryAfter = Number(res.headers.get("Retry-After"));
      await sleep(Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 1000 * 2 ** attempt);
      continue;
    }
    if (res.status >= 500 && attempt < 4) {
      await sleep(1000 * attempt);
      continue;
    }
    const error = new Error(`Raken GET ${path} failed: HTTP ${res.status} ${text.slice(0, 300)}`);
    (error as Error & { status?: number }).status = res.status;
    throw error;
  }
}

// ---------------------------------------------------------------------------
// OAuth sign-in (the one allowed non-GET call)
// ---------------------------------------------------------------------------

type TokenRequest =
  | { grant_type: "authorization_code"; code: string; redirect_uri: string }
  | { grant_type: "refresh_token"; refresh_token: string };

export async function requestToken(request: TokenRequest): Promise<{
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
}> {
  const res = await fetch(RAKEN_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams({
      ...request,
      client_id: env("Client_ID"),
      client_secret: env("Raken_secret"),
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) {
    // Never include token values in errors.
    const reason = body.error_description ?? body.error ?? `HTTP ${res.status}`;
    if (body.error === "invalid_grant") {
      throw new RakenAuthError(`Raken sign-in expired or was revoked (${reason}). Connect Raken again.`);
    }
    throw new RakenAuthError(`Raken sign-in failed: ${reason}`);
  }
  return body;
}

export function expiresAt(expiresIn: number | undefined): string {
  return new Date(Date.now() + (expiresIn ?? 36000) * 1000).toISOString();
}

export async function loadTokens(db: SupabaseClient): Promise<StoredTokens | null> {
  const { data, error } = await db.rpc("raken_tokens_get");
  if (error) throw new Error(`Could not read Raken tokens: ${error.message}`);
  return (data as StoredTokens | null) ?? null;
}

export async function saveTokens(db: SupabaseClient, tokens: StoredTokens): Promise<void> {
  const { error } = await db.rpc("raken_tokens_save", { p_tokens: tokens });
  if (error) throw new Error(`Could not save Raken tokens: ${error.message}`);
}

// Read-only Raken client that keeps its access token fresh.
export class RakenClient {
  private constructor(private db: SupabaseClient, private tokens: StoredTokens) {}

  static async create(db: SupabaseClient): Promise<RakenClient> {
    const tokens = await loadTokens(db);
    if (!tokens) throw new RakenAuthError("Raken is not connected yet. Run the connect step first.");
    const client = new RakenClient(db, tokens);
    if (Date.parse(tokens.expires_at) - Date.now() < 5 * 60 * 1000) await client.refresh();
    return client;
  }

  private async refresh(): Promise<void> {
    const result = await requestToken({ grant_type: "refresh_token", refresh_token: this.tokens.refresh_token });
    this.tokens = {
      ...this.tokens,
      access_token: result.access_token,
      // Raken may rotate the refresh token; the old one then stops working.
      refresh_token: result.refresh_token ?? this.tokens.refresh_token,
      expires_at: expiresAt(result.expires_in),
      refreshed_at: new Date().toISOString(),
    };
    await saveTokens(this.db, this.tokens);
  }

  async get(path: string, params: Params = {}): Promise<any> {
    try {
      return await rakenGet(this.tokens.access_token, path, params);
    } catch (error) {
      if (!(error instanceof RakenAuthError)) throw error;
      await this.refresh();
      return await rakenGet(this.tokens.access_token, path, params);
    }
  }

  // Reads every page of a list endpoint.
  async getAll(path: string, params: Params = {}): Promise<any[]> {
    const all: any[] = [];
    for (let offset = 0; ; ) {
      const page = await this.get(path, { ...params, limit: PAGE_SIZE, offset });
      const items: any[] = Array.isArray(page?.collection) ? page.collection : [];
      all.push(...items);
      const total = Number(page?.page?.totalElements);
      if (items.length < PAGE_SIZE || (Number.isFinite(total) && all.length >= total)) break;
      offset += items.length;
    }
    return all;
  }
}
