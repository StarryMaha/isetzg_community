require('dotenv').config();

const express = require('express');
const cors = require('cors');
const authRoutes = require('./routes/auth');
const messageRoutes = require('./routes/messages');
const { setupRealtime } = require('./realtime');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

app.use('/api/auth', authRoutes);

app.get('/', (req, res) => {
    res.json({
        status: 'ISET Backend is running',
        timestamp: new Date()
    });
});

const server = require('http').createServer(app);
const io = setupRealtime(server);

// REST send broadcasts through the same Socket.IO instance as the socket path.
app.use('/api/messages', messageRoutes(io));

app.use((error, req, res, next) => {
    const status = error.status || 500;
    res.status(status).json({ error: status === 400 ? 'Invalid request body' : 'Server error' });
});

server.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
});
