import 'package:flutter/material.dart';

/// Pide el nombre de un jugador sin cuenta. Devuelve null si se cancela o se
/// deja vacío.
Future<String?> askGuestName(BuildContext context) async {
  final name = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Jugador sin cuenta'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Para el que juega con ustedes pero no tiene la app. Le pone los goles el staff, y si algún día se la instala, reclama su perfil con una invitación.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: name,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre'),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Crear'),
        ),
      ],
    ),
  );
  // Sin dispose: el diálogo todavía se está cerrando y el campo lo usa.
  final typed = name.text.trim();
  return ok == true && typed.isNotEmpty ? typed : null;
}
