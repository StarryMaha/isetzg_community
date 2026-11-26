const { Server } = require('socket.io');
const jwt = require('jsonwebtoken');
const db = require('./db');
const { JWT_SECRET } = require('./middleware/auth');

// userId -> Set of connected socket ids
const online = new Map();

function setupRealtime(server) {
  const io = new Server(server, {
    cors: { origin: '*' },
  });

  // Authenticate every socket before it can join a room.
  io.use((socket, next) => {
    const token =
      socket.handshake.auth?.token ||
      socket.handshake.headers.authorization?.split(' ')[1];
    if (!token) return next(new Error('Token required'));
    try {
      const decoded = jwt.verify(token, JWT_SECRET);
      socket.userId = decoded.user_id;
      next();
    } catch (error) {
      next(new Error('Invalid token'));
    }
  });

  const broadcastOnline = () => io.emit('users:online', Array.from(online.keys()));

  io.on('connection', (socket) => {
    const uid = socket.userId;
    socket.join(`user:${uid}`);

    if (!online.has(uid)) online.set(uid, new Set());
    online.get(uid).add(socket.id);
    broadcastOnline();

    // Private one-to-one message, acknowledged to the sender.
    socket.on('message:send', (payload, ack) => {
      const done = typeof ack === 'function' ? ack : () => {};
      try {
        const receiverId = Number(payload?.receiver_id);
        const content = payload?.content;

        if (!Number.isInteger(receiverId) || receiverId <= 0) {
          return done({ ok: false, error: 'Invalid receiver' });
        }
        if (typeof content !== 'string' || !content.trim()) {
          return done({ ok: false, error: 'Message content is required' });
        }
        if (receiverId === uid) {
          return done({ ok: false, error: 'Cannot message yourself' });
        }

        const receiver = db.prepare('SELECT id FROM users WHERE id = ?').get(receiverId);
        if (!receiver) return done({ ok: false, error: 'Receiver not found' });

        const text = content.trim().slice(0, 4000);
        const result = db
          .prepare('INSERT INTO messages (sender_id, receiver_id, content) VALUES (?, ?, ?)')
          .run(uid, receiverId, text);

        const message = db
          .prepare('SELECT id, sender_id, receiver_id, content, timestamp FROM messages WHERE id = ?')
          .get(result.lastInsertRowid);

        // Only the recipient's room receives the live event.
        io.to(`user:${receiverId}`).emit('message:new', message);
        done({ ok: true, message });
      } catch (error) {
        done({ ok: false, error: 'Failed to send message' });
      }
    });

    socket.on('disconnect', () => {
      const sockets = online.get(uid);
      if (sockets) {
        sockets.delete(socket.id);
        if (sockets.size === 0) online.delete(uid);
      }
      broadcastOnline();
    });
  });

  return io;
}

module.exports = { setupRealtime };
