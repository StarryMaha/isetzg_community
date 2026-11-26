const express = require('express');
const db = require('../db');
const authenticateToken = require('../middleware/auth');

const router = express.Router();

// GET /api/users — list all registered students except the authenticated user
router.get('/', authenticateToken, (req, res) => {
  try {
    const users = db
      .prepare('SELECT id, student_id, name FROM users WHERE id != ?')
      .all(req.user.id);
    res.json(users);
  } catch (error) {
    res.status(500).json({ error: 'Failed to retrieve users' });
  }
});

module.exports = router;