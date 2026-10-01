import '../api/api_client.dart';

/// Texto para mostrar de cualquier error de la API o de la red.
String describeError(Object e) {
  if (e is OfflineException) {
    return 'Sin conexión. Prueba otra vez cuando tengas señal.';
  }
  if (e is ApiException) {
    final fields = e.fieldErrors.values.expand((m) => m).toList();
    return fields.isEmpty ? e.message : fields.join('\n');
  }
  return 'Algo salió mal. Inténtalo de nuevo.';
}
