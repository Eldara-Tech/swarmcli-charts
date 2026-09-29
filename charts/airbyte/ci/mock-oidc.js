// Minimal OIDC discovery for the airbyte chart's e2e (ci/e2e-setup.sh deploys it as the
// `airbyte-e2e-oidc` service on traefik-public, where oauth2-proxy can reach it).
//
// oauth2-proxy runs OIDC discovery against --oidc-issuer-url (and every --extra-jwt-issuers
// entry) at startup and exits when it fails, so the chart cannot converge without an issuer.
// Nobody logs in during the e2e, so the discovery document and an empty key set are all it
// needs. ISSUER must equal the chart's oauth2.issuerUrl exactly: the document is checked
// against it.
//
// No dependencies — Node's built-in http only (runs on a stock node:alpine image).
const http = require('http');

const issuer = process.env.ISSUER;
const discovery = JSON.stringify({
  issuer,
  authorization_endpoint: `${issuer}/protocol/openid-connect/auth`,
  token_endpoint: `${issuer}/protocol/openid-connect/token`,
  userinfo_endpoint: `${issuer}/protocol/openid-connect/userinfo`,
  jwks_uri: `${issuer}/protocol/openid-connect/certs`,
  response_types_supported: ['code'],
  subject_types_supported: ['public'],
  id_token_signing_alg_values_supported: ['RS256'],
});

http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  let body = null;
  if (path.endsWith('/.well-known/openid-configuration')) body = discovery;
  else if (path.endsWith('/protocol/openid-connect/certs')) body = '{"keys":[]}';
  console.log(`${req.method} ${path} -> ${body ? 200 : 404}`);
  res.writeHead(body ? 200 : 404, { 'Content-Type': 'application/json' });
  res.end(body || '{}');
}).listen(8080);
