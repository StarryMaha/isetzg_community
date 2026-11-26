# ISET backend

1. Copy `.env.example` to `.env` and set a real `JWT_SECRET`.
2. `npm install`
3. `node server.js`

The SQLite database (`iset.db`) is created automatically on first run and is not committed.
Auth API: `/api/auth/register`, `/api/auth/login`, `/api/auth/me`, `/api/auth/users`.
Messaging: Socket.IO (JWT via `Authorization` header or `auth.token`) plus `GET /api/messages/:userId` for history.
