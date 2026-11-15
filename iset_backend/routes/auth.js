const express = require('express');
const jwt = require('jsonwebtoken');
const db = require('../db');

const router = express.Router();
const JWT_SECRET = 'your-secret-key-change-this-in-production';

// Register
router.post('/register', (req, res) => {
  const { student_id, name, password } = req.body;
  
  if (!student_id || !name || !password) {
    return res.status(400).json({ error: 'All fields required' });
  }

  try {
    const stmt = db.prepare('INSERT INTO users (student_id, name, password) VALUES (?, ?, ?)');
    const result = stmt.run(student_id, name, password);
    
    res.json({ 
      message: 'User registered', 
      user_id: result.lastInsertRowid 
    });
  } catch (error) {
    if (error.message.includes('UNIQUE')) {
      return res.status(400).json({ error: 'Student ID already exists' });
    }
    res.status(500).json({ error: 'Registration failed' });
  }
});

// Login
router.post('/login', (req, res) => {
  const { student_id, password } = req.body;
  
  const user = db.prepare('SELECT * FROM users WHERE student_id = ? AND password = ?').get(student_id, password);
  
  if (!user) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }

  const token = jwt.sign({ user_id: user.id, student_id: user.student_id }, JWT_SECRET, { expiresIn: '7d' });
  
  res.json({ 
    token, 
    user: { 
      id: user.id, 
      student_id: user.student_id, 
      name: user.name 
    } 
  });
});

module.exports = router;

// Get all users (requires authentication)
router.get('/users', (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];
  
  if (!token) {
    return res.status(401).json({ error: 'Token required' });
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    const users = db.prepare('SELECT id, student_id, name FROM users WHERE id != ?').all(decoded.user_id);
    res.json({ users });
  } catch (error) {
    res.status(401).json({ error: 'Invalid token' });
  }
});