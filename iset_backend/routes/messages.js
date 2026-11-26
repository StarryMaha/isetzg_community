const express = require('express');
const db = require('../db');
const authenticateToken = require('../middleware/auth');

const router = express.Router();

let io;

// POST /api/messages/send — send a 1-to-1 message
router.post('/send', authenticateToken, (req, res) => {
  const { receiver_id, content } = req.body;
  const sender_id = req.user.id;

  // Validate content
  if (typeof content !== 'string' || content.trim() === '') {
    return res.status(400).json({ error: 'Message content is required' });
  }

  // Validate receiver_id
  const receiverId = Number(receiver_id);
  if (!Number.isInteger(receiverId) || receiverId <= 0) {
    return res.status(400).json({ error: 'Invalid receiver ID' });
  }

  if (receiverId === sender_id) {
    return res.status(400).json({ error: 'Cannot send a message to yourself' });
  }

  try {
    // Check receiver exists
    const receiver = db.prepare('SELECT id FROM users WHERE id = ?').get(receiverId);
    if (!receiver) {
      return res.status(404).json({ error: 'Receiver not found' });
    }

    const result = db
      .prepare('INSERT INTO messages (sender_id, receiver_id, content) VALUES (?, ?, ?)')
      .run(sender_id, receiverId, content);

    const message = db
      .prepare('SELECT id, sender_id, receiver_id, content, timestamp FROM messages WHERE id = ?')
      .get(result.lastInsertRowid);

    // Deliver live to the recipient's room, same as the socket-only path.
    if (io) io.to(`user:${receiverId}`).emit('message:new', message);

    return res.status(201).json(message);
  } catch (error) {
    return res.status(500).json({ error: 'Failed to send message' });
  }
});

// GET /api/messages/:userId — retrieve conversation with a user
router.get('/:userId', authenticateToken, (req, res) => {
  const me = req.user.id;
  const otherId = Number(req.params.userId);

  if (!Number.isInteger(otherId) || otherId <= 0) {
    return res.status(400).json({ error: 'Invalid user ID' });
  }

  try {
    const other = db.prepare('SELECT id FROM users WHERE id = ?').get(otherId);
    if (!other) {
      return res.status(404).json({ error: 'User not found' });
    }

    const messages = db
      .prepare(
        `SELECT id, sender_id, receiver_id, content, timestamp
         FROM messages
         WHERE (sender_id = ? AND receiver_id = ?)
            OR (sender_id = ? AND receiver_id = ?)
         ORDER BY timestamp ASC, id ASC`
      )
      .all(me, otherId, otherId, me);

    return res.json(messages);
  } catch (error) {
    return res.status(500).json({ error: 'Failed to retrieve messages' });
  }
});

module.exports = (socketIo) => {
  io = socketIo;
  return router;
};