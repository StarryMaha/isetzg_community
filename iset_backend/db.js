const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');
const db = new Database('iset.db');

// Create tables
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    password TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_id INTEGER NOT NULL,
    receiver_id INTEGER NOT NULL,
    content TEXT NOT NULL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (sender_id) REFERENCES users(id),
    FOREIGN KEY (receiver_id) REFERENCES users(id)
  );
`);

// One-time migration: hash any legacy plaintext passwords already in the DB.
// Existing accounts keep working after the switch to bcrypt.
const legacy = db.prepare("SELECT id, password FROM users WHERE password NOT LIKE '$2a$%' AND password NOT LIKE '$2b$%'").all();
const hashLegacy = db.prepare('UPDATE users SET password = ? WHERE id = ?');
const migrate = db.transaction((rows) => {
  for (const row of rows) {
    hashLegacy.run(bcrypt.hashSync(row.password, 10), row.id);
  }
});
if (legacy.length) migrate(legacy);

module.exports = db;
