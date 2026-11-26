import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import '../services/api_client.dart';

enum AuthStatus { initializing, authenticated, guest, unauthenticated }

class AuthProvider extends ChangeNotifier {
  AuthProvider(this._api, this._prefs);

  static const _tokenKey = 'auth_token';
  static const _idKey = 'user_id';
  static const _sidKey = 'student_id';
  static const _nameKey = 'user_name';
  static const _guestKey = 'guest';

  final ApiClient _api;
  final SharedPreferences _prefs;

  AuthStatus _status = AuthStatus.initializing;
  AppUser? _user;
  String? _error;
  bool _busy = false;

  AuthStatus get status => _status;
  AppUser? get user => _user;
  String? get error => _error;
  bool get busy => _busy;
  String? get token => _prefs.getString(_tokenKey);
  bool get isGuest => _status == AuthStatus.guest;

  Future<void> restore() async {
    if (_prefs.getBool(_guestKey) == true) {
      _status = AuthStatus.guest;
      notifyListeners();
      return;
    }
    final token = _prefs.getString(_tokenKey);
    if (token == null) {
      _status = AuthStatus.unauthenticated;
      notifyListeners();
      return;
    }
    try {
      _user = await _api.fetchMe(token);
      _status = AuthStatus.authenticated;
    } on ApiException catch (e) {
      await _clearSession();
      _error = e.message;
      _status = AuthStatus.unauthenticated;
    }
    notifyListeners();
  }

  Future<bool> login(String studentId, String password) async {
    _startRequest();
    try {
      final result = await _api.login(studentId: studentId, password: password);
      await _saveSession(result.token, result.user);
      _status = AuthStatus.authenticated;
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } finally {
      _finishRequest();
    }
  }

  Future<bool> register(String studentId, String name, String password) async {
    _startRequest();
    try {
      await _api.register(studentId: studentId, name: name, password: password);
      final result = await _api.login(studentId: studentId, password: password);
      await _saveSession(result.token, result.user);
      _status = AuthStatus.authenticated;
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } finally {
      _finishRequest();
    }
  }

  Future<void> loginAsGuest() async {
    await _clearSession();
    await _prefs.setBool(_guestKey, true);
    _status = AuthStatus.guest;
    _error = null;
    notifyListeners();
  }

  Future<void> showLogin() async {
    await _prefs.remove(_guestKey);
    _status = AuthStatus.unauthenticated;
    _error = null;
    notifyListeners();
  }

  Future<void> signOut() async {
    await _clearSession();
    _status = AuthStatus.unauthenticated;
    _error = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _startRequest() {
    _busy = true;
    _error = null;
    notifyListeners();
  }

  void _finishRequest() {
    _busy = false;
    notifyListeners();
  }

  Future<void> _saveSession(String token, AppUser user) async {
    await _prefs.setString(_tokenKey, token);
    await _prefs.setInt(_idKey, user.id);
    await _prefs.setString(_sidKey, user.studentId);
    await _prefs.setString(_nameKey, user.name);
    await _prefs.remove(_guestKey);
    _user = user;
  }

  Future<void> _clearSession() async {
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_idKey);
    await _prefs.remove(_sidKey);
    await _prefs.remove(_nameKey);
    await _prefs.remove(_guestKey);
    _user = null;
  }
}
