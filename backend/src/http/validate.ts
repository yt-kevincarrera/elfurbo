import type { Context } from "hono";
import { z } from "zod";
import { errors } from "./errors";

/** Lee el cuerpo JSON y lo valida. Cualquier fallo es un 400 `invalid_input`, nunca un 500. */
export async function readJson<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    throw errors.invalidInput();
  }
  const parsed = schema.safeParse(body);
  if (!parsed.success) throw errors.invalidInput(z.flattenError(parsed.error).fieldErrors);
  return parsed.data;
}

/** IP del cliente según Cloudflare. En local y en tests puede faltar. */
export function clientIp(c: Context): string {
  return c.req.header("cf-connecting-ip") ?? "unknown";
}
