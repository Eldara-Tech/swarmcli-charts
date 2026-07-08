// Minimal mock Ollama API for the openclaw chart's backend e2e (ci/e2e-setup.sh deploys
// it as the `mock-ollama` service on the ai-internal overlay). It implements just enough
// of the Ollama HTTP API for OpenClaw's model discovery (/api/tags, /api/show) and a
// canned chat/generate, and logs EVERY request as a greppable line to stdout — the smoke
// check (ci/e2e-check.sh) reads `docker service logs mock-ollama` to prove the gateway,
// once pointed at this backend via OpenClaw config, actually dialed it over the overlay.
// No dependencies — Node's built-in http only (runs on a stock node:alpine image).
const http = require('http');

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    // One line per request; the smoke check greps for "MOCK-OLLAMA <METHOD> <path>".
    console.log(`MOCK-OLLAMA ${req.method} ${req.url}`);
    const path = req.url.split('?')[0];
    res.setHeader('Content-Type', 'application/json');
    if (path === '/api/tags') {
      res.end(JSON.stringify({ models: [{
        name: 'mockllama:latest', model: 'mockllama:latest', size: 1,
        details: { family: 'llama', parameter_size: '1B', quantization_level: 'Q4_0' },
      }] }));
    } else if (path === '/api/show') {
      res.end(JSON.stringify({
        details: { family: 'llama' },
        model_info: { 'general.context_length': 4096 },
        capabilities: ['completion'],
      }));
    } else if (path === '/api/chat') {
      res.end(JSON.stringify({
        model: 'mockllama:latest', done: true,
        message: { role: 'assistant', content: 'ok' },
      }));
    } else if (path === '/api/generate') {
      res.end(JSON.stringify({ model: 'mockllama:latest', done: true, response: 'ok' }));
    } else {
      res.end(JSON.stringify({ ok: true }));
    }
  });
});

server.listen(11434, '0.0.0.0', () => console.log('MOCK-OLLAMA listening on 11434'));
