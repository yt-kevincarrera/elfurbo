import { exports } from "cloudflare:workers";

type ApiInit = { method?: string; body?: unknown; token?: string; ip?: string };

/** Llama al Worker como lo haría la app. `body` string se manda tal cual (para JSON roto). */
export async function api(path: string, init: ApiInit = {}) {
  const headers: Record<string, string> = {};
  if (init.body !== undefined) headers["content-type"] = "application/json";
  if (init.token) headers.authorization = `Bearer ${init.token}`;
  if (init.ip) headers["cf-connecting-ip"] = init.ip;
  const res = await exports.default.fetch(`https://api.test${path}`, {
    method: init.method ?? (init.body !== undefined ? "POST" : "GET"),
    headers,
    body:
      init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body),
  });
  const text = await res.text();
  return { status: res.status, headers: res.headers, body: text ? JSON.parse(text) : null };
}
