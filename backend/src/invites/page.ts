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
padding:.8em 1.4em;border-radius:999px;text-decoration:none}
a.ghost{background:transparent;color:#fff;border:2px solid #fff}small a{color:#fff}
h2{font-size:1.1rem;margin:1.2em 0 .3em}.list{text-align:left;display:inline-block;margin:0;padding-left:1.4em}
.list li{margin:.25em 0}table{margin:0 auto;border-collapse:collapse}td,th{padding:.25em .5em}td.team{text-align:left}`;

export function layout(body: string, title = "El Furbo · Invitación") {
  return `<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title><style>${STYLE}</style></head>
<body><main>${body}</main></body></html>`;
}

/** Bajar la app, también cuando la invitación ya no vale (el que llegó aquí la quiere). */
export const DOWNLOAD = `<p><a class="button ghost" href="/app/download">Descargar El Furbo</a></p>
<p><small>¿Teléfono viejo y no instala? <a href="/app/download?abi=armeabi-v7a">Prueba esta otra</a>.</small></p>`;

/** Para quien baja la app desde el navegador y algo falla. */
export function downloadErrorPage(message: string) {
  return layout(`<h1>⚽ No se pudo bajar la app</h1><p>${escapeHtml(message)}</p>`);
}

export function invitePage(invite: InviteRecord | null) {
  if (!invite) {
    return layout(`<h1>⚽ Invitación no válida</h1>
<p>Esta invitación no existe, caducó o ya se usó. Pídele otra a quien te la mandó.</p>
<p>Mientras tanto, ya puedes ir bajando la app:</p>${DOWNLOAD}`);
  }
  const code = formatCode(invite.code);
  const description = invite.club.description ? `<p>${escapeHtml(invite.club.description)}</p>` : "";
  return layout(`<p>Te invitaron a jugar con</p><h1>⚽ ${escapeHtml(invite.club.name)}</h1>${description}
<p>Tu código de invitación:</p><div class="code">${code}</div>
<p><a class="button" href="elfurbo://invite/${invite.code}">Abrir en El Furbo</a></p>
<p>¿No tienes la app? Bájala, instálala y vuelve a esta página (o escribe el código en
"Tengo un código de invitación").</p>
${DOWNLOAD}`);
}
