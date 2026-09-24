class PinRequiredException implements Exception {
  final String message;
  PinRequiredException([this.message = 'PIN required']);
  @override
  String toString() => message;
}
