// Minimal mock of the GitLab runner API, for the gitlab-runner chart's e2e
// (ci/e2e-check.sh deploys it as the `mock-gitlab` service on the release's own overlay).
//
// It exists because of something worth stating plainly: a gitlab-runner with an EMPTY
// token, a bogus token or an unresolvable url starts, mints a system ID and reports
// Running forever. Convergence therefore proves nothing about the one thing this chart
// does — carry an operator's token from a Swarm secret into config.toml and on into an
// authenticated API call. So the runner is pointed at this mock, which logs the token it
// actually received, and the smoke check compares that against the secret's contents.
//
// The runner posts its job requests to POST /api/v4/jobs/request with a JSON body whose
// `token` field is the runner authentication token; 204 means "no jobs for you", which
// keeps the runner polling happily without ever trying to run a build.
//
// No dependencies — Node's built-in http only (runs on a stock node:alpine image).
const http = require('http');

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    let token = '';
    let systemId = '';
    try {
      const parsed = JSON.parse(body || '{}');
      token = parsed.token || '';
      systemId = (parsed.info && parsed.info.system_id) || '';
    } catch {
      // A body that is not JSON is still worth logging as a request.
    }
    // One line per request; the smoke check greps for "MOCK-GITLAB <METHOD> <path>" and
    // reads token=<value> off it.
    console.log(`MOCK-GITLAB ${req.method} ${req.url} token=${token} system_id=${systemId}`);

    const path = req.url.split('?')[0];
    if (path === '/api/v4/jobs/request') {
      // 204 = no job available. The runner logs nothing alarming and keeps polling.
      res.statusCode = 204;
      res.end();
      return;
    }
    if (path === '/api/v4/runners/verify') {
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ id: 1, token, token_expires_at: null }));
      return;
    }
    res.statusCode = 404;
    res.setHeader('Content-Type', 'application/json');
    res.end('{}');
  });
});

server.listen(8080, () => console.log('MOCK-GITLAB listening 8080'));
