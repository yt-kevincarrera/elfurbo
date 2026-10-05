import { formatCode, type InviteRecord } from "./model";

/** El nombre y la descripción los escribe cualquiera que pida un servidor: siempre escapados. */
export function escapeHtml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const STYLE = `body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f5132;color:#fff;
font-family:system-ui,sans-serif;text-align:center;padding:16px;box-sizing:border-box}
main{max-width:420px}h1{font-size:1.6rem;margin:.2em 0}p{line-height:1.5;opacity:.92}
.code{font-size:2rem;letter-spacing:.15em;font-weight:700;background:#fff;color:#0f5132;
border-radius:12px;padding:.4em .6em;display:inline-block;margin:.4em 0}
a.button{display:inline-block;margin-top:1em;background:#ffc107;color:#000;font-weight:700;
padding:.8em 1.4em;border-radius:999px;text-decoration:none}`;

function layout(body: string) {
  return `<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>El Furbo · Invitación</title><style>${STYLE}</style></head>
<body><main>${body}</main></body></html>`;
}

export function invitePage(invite: InviteRecord | null) {
  if (!invite) {
    return layout(`<h1>⚽ Invitación no válida</h1>
<p>Esta invitación no existe, caducó o ya se usó. Pídele otra a quien te la mandó.</p>`);
  }
  const code = formatCode(invite.code);
  const description = invite.club.description ? `<p>${escapeHtml(invite.club.description)}</p>` : "";
  return layout(`<p>Te invitaron a jugar con</p><h1>⚽ ${escapeHtml(invite.club.name)}</h1>${description}
<p>Tu código de invitación:</p><div class="code">${code}</div>
<p><a class="button" href="elfurbo://invite/${invite.code}">Abrir en El Furbo</a></p>
<p>¿No tienes la app? Pídele el APK a quien te invitó, instálala, entra y escribe el código en
"Tengo un código de invitación".</p>`);
}
