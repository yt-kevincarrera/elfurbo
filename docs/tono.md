# Tono de El Furbo

La app la usa un grupo de socios en Cuba. Tiene que sonar a cómo hablamos
nosotros, no a un manual en español neutro. Informal y cubano, pero sin pasarse:
si una frase suena a anuncio de turismo o a alguien imitando el acento, se cambia.

## Reglas

- **Siempre tú.** Nunca usted, nunca vos ("cargá", "tenés", "elegí" están mal).
- **El sabor va en los momentos sueltos:** saludos, pantallas vacías, avisos
  ("Listo, …"), errores y confirmaciones. Ahí cabe una frase con gracia.
- **Los botones dicen qué hacen:** Entrar, Guardar, Crear jornada, Borrar.
  Un botón no es sitio para jerga ("Dale" solo como "OK" en un aviso que no hace nada).
- **Claro antes que gracioso.** Un error tiene que decir qué pasó y qué hacer.
  Si la gracia lo enreda, fuera.
- **Una pizca por pantalla, como máximo.** Si todos los textos llevan jerga, cansa.
- **Nada de malas palabras** ni doble sentido. Nada de "asere", "consorte" o
  "yuma" en la interfaz: en boca de una app suenan forzados.
- **Diminutivos en -ico** cuando pegan: un momentico, un ratico.

## Vocabulario

| En vez de | Decimos |
|---|---|
| Hola, Kevin | ¿Qué bolá, Kevin? |
| Cargando… | Un momentico… |
| Cargar / subir tus goles | Poner tus goles |
| Cancha | Terreno |
| Tardar | Demorar ("esto está demorando más de la cuenta") |
| No funciona | No pincha / se trabó (solo en avisos, no en errores técnicos) |
| Algo salió mal. Inténtalo de nuevo | Algo se trabó. Dale otra vez |
| Listo / Hecho | Listo / Ya está |
| Mucho, muchos | Pila de (con moderación) |
| ¡Excelente! | ¡Tremendo! / ¡Qué clase de…! |
| ¿Estás seguro? | ¿Seguro? / ¿De verdad? |
| No tienes permiso | Eso no lo puedes hacer tú |
| Sin conexión | Sin conexión (es un estado: se queda así de claro) |

## Ejemplos

- Pantalla vacía de jornadas: *"Todavía no hay jornadas. Crea la primera con el botón de abajo."*
- Tras crear una jornada: *"Listo, jornada creada."*
- MVP: *"¡Tremendo partido! Saliste MVP."*
- Al salir con cambios sin enviar: *"Tienes 2 cambios sin enviar. Si sales ahora se pierden. ¿Te vas igual?"*
- Error de red demorado: *"Esto está demorando más de la cuenta. Revisa la conexión."*

## Dónde vive el texto

- App: `lib/ui/**` y `lib/cloud/ui/**`.
- Servidor: `backend/src/http/errors.ts` y los mensajes de los esquemas (zod).
  La app los enseña tal cual, así que siguen estas mismas reglas.
- Página de invitación: `backend/src/invites/page.ts`.
