# ISET Community App - front-end

Flutter UI with backend authentication and user directory. Remaining community screens still use mock data.

Run the backend first (`cd ..\iset_backend` then `node server.js`), then set `apiBaseUrl` in `lib/config.dart` to the backend address reachable from your device.

## Run
1. Create the platform folders once, inside this folder:
   flutter create . --platforms=android,windows
2. flutter pub get
3. flutter run            (or: flutter run -d windows)

## Structure
lib/main.dart                      app + session gate
lib/config.dart                    backend base URL
lib/services/api_client.dart       HTTP calls to the backend
lib/state/auth_provider.dart       session state + persistence
lib/theme.dart                     colors (edit to match your logo) + placeholder logo
lib/screens/login_screen.dart      login + "continue without an account" (public mode)
lib/screens/shell.dart             bottom navigation (guests see Home only)
lib/screens/home_screen.dart       header, search, connection status, shortcuts, announcement, events
lib/screens/community_screens.dart chats, groups, files, profile, locked view

## Not yet integrated
- Chats/groups/files lists are still hard-coded (Phase 2+).
