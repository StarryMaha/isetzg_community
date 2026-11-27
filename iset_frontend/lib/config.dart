/// Address of the centralized backend.
///
/// Build for a physical phone with:
///   flutter run --dart-define=ISET_API_BASE_URL=http://YOUR_LAN_IP:3000
///
/// The checked-in default is machine-neutral so LAN addresses are not committed.
const String apiBaseUrl = String.fromEnvironment(
  'ISET_API_BASE_URL',
  defaultValue: 'http://localhost:3000',
);

String apiUrl(String path) => '$apiBaseUrl$path';
