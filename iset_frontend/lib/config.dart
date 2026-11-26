/// Address of the centralized backend.
///
/// Android emulator: 10.0.2.2:3000
/// Physical device / Windows: replace with the machine's LAN IP (e.g. 192.168.1.10:3000)
/// and run the backend with ` node server.js ` on that machine.
const String apiBaseUrl = 'http://192.168.1.8:3000';

String apiUrl(String path) => '$apiBaseUrl$path';
