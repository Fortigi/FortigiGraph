import express from 'express';
import cors from 'cors';
import permissionsRouter from './routes/permissions.js';

const app = express();
const port = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

app.use('/api', permissionsRouter);

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', mode: process.env.USE_SQL === 'true' ? 'sql' : 'mock' });
});

app.listen(port, () => {
  console.log(`FortigiGraph UI API running on http://localhost:${port}`);
  console.log(`Mode: ${process.env.USE_SQL === 'true' ? 'SQL' : 'Mock data'}`);
});
