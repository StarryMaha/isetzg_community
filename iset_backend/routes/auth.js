const express = require('express');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const db = require('../db');
const { authRequired, JWT_SECRET } = require('../middleware/auth');

const router = express.Router();

// Register
router.post('/register', (req, res) => {
  const { student_id, name, password } = req.body || {};

  if (!student_id || !name || !password) {
    return res.status(400).json({ error: 'All fields required' });
  }
  const sid = String(student_id).trim();
  const displayName = String(name).trim();
  if (!sid || !displayName || String(password).length < 6) {
    return res.status(400).json({ error: 'Invalid input (password must be at least 6 characters)' });
  }

  try {
    const hash = bcrypt.hashSync(String(password), 10);
    const stmt = db.prepare('INSERT INTO users (student_id, name, password) VALUES (?, ?, ?)');
    const result = stmt.run(sid, displayName, hash);

    res.status(201).json({
      message: 'User registered',
      user_id: result.lastInsertRowid
    });
  } catch (error) {
    if (error.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'Student ID already exists' });
    }
    return res.status(500).json({ error: 'Registration failed' });
  }
});

// Login
router.post('/login', (req, res) => {
  const { student_id, password } = req.body || {};

  if (!student_id || !password) {
    return res.status(400).json({ error: 'All fields required' });
  }

  const user = db.prepare('SELECT * FROM users WHERE student_id = ?').get(String(student_id).trim());

  if (!user || !bcrypt.compareSync(String(password), user.password)) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }

  const token = jwt.sign(
    { user_id: user.id, id: user.id, student_id: user.student_id },
    JWT_SECRET,
    { expiresIn: '7d' }
  );

  res.json({
    token,
    user: {
      id: user.id,
      student_id: user.student_id,
      name: user.name
    }
  });
});

// Get all users (protected)
router.get('/users', authRequired, (req, res) => {
  const users = db.prepare('SELECT id, student_id, name FROM users WHERE id != ?').all(req.user.user_id);
  res.json({ users });
});

// Validate/restore a session and fetch current user info (protected)
router.get('/me', authRequired, (req, res) => {
  const user = db.prepare('SELECT id, student_id, name FROM users WHERE id = ?').get(req.user.user_id);
  if (!user) return res.status(401).json({ error: 'User not found' });
  res.json({ user });
});

module.exports = router;
