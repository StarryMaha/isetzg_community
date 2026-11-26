const jwt = require('jsonwebtoken');

const JWT_SECRET = process.env.JWT_SECRET;

function authRequired(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) {
    return res.status(401).json({ error: 'Token required' });
  }
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch (error) {
    return res.status(401).json({ error: 'Invalid token' });
  }
}

// Named export used by auth routes; default export kept for existing route files.
module.exports = authRequired;
module.exports.authRequired = authRequired;
module.exports.JWT_SECRET = JWT_SECRET;
