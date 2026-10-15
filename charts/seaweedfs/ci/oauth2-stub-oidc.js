// A stub OpenID Connect provider for the seaweedfs chart's admin-oauth2 e2e. ci/e2e-setup.sh
// deploys it as the `seaweedfs-e2e-oidc` service on traefik-public, where the chart's
// oauth2-proxy reaches it, over TLS with a certificate from a throwaway CA that the fixture
// hands the proxy as admin.oauth2.caSecret. Unlike airbyte's discovery-only stub it issues
// real RS256 ID tokens, so ci/e2e-check.sh signs in end to end:
//   * /authorize sends the browser straight back to redirect_uri with a code for the `user`
//     query parameter, without a login form: `admin` is in storage-admins, the fixture's
//     allowed group, and `outsider` is not;
//   * /token redeems a code once, and only for the client's id and secret, so a secret that
//     never reached the proxy fails the sign-in;
//   * every token carries iss, aud and the user's groups.
//
// No dependencies — Node's built-in https and crypto only (runs on a stock node:alpine image).
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');

const issuer = process.env.ISSUER;
const clientId = process.env.CLIENT_ID;
const clientSecret = fs.readFileSync(`/run/secrets/${process.env.CLIENT_SECRET_SECRET}`, 'utf8');
const groups = { admin: ['storage-admins'], outsider: ['other-team'] };

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'e2e', alg: 'RS256', use: 'sig' };
const b64u = (s) => Buffer.from(s).toString('base64url');
const sign = (claims) => {
  const unsigned = `${b64u(JSON.stringify({ alg: 'RS256', kid: 'e2e', typ: 'JWT' }))}.${b64u(JSON.stringify(claims))}`;
  return `${unsigned}.${crypto.sign('RSA-SHA256', Buffer.from(unsigned), privateKey).toString('base64url')}`;
};
// RFC 6749 §2.3.1: the client id and secret in a Basic header are form-encoded first.
const formDecode = (s) => new URLSearchParams(`v=${s}`).get('v');
const codes = new Map();

const discovery = JSON.stringify({
  issuer,
  authorization_endpoint: `${issuer}/authorize`,
  token_endpoint: `${issuer}/token`,
  jwks_uri: `${issuer}/jwks`,
  response_types_supported: ['code'],
  subject_types_supported: ['public'],
  id_token_signing_alg_values_supported: ['RS256'],
  code_challenge_methods_supported: ['S256'],
});

const tls = { key: fs.readFileSync('/run/secrets/seaweedfs-e2e-oidc-key'), cert: fs.readFileSync('/run/secrets/seaweedfs-e2e-oidc-cert') };
https.createServer(tls, (req, res) => {
  const url = new URL(req.url, issuer);
  const send = (status, body, headers = {}) => {
    console.log(`${req.method} ${url.pathname} -> ${status}`);
    res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
    res.end(body);
  };
  if (url.pathname === '/.well-known/openid-configuration') return send(200, discovery);
  if (url.pathname === '/jwks') return send(200, JSON.stringify({ keys: [jwk] }));
  if (url.pathname === '/authorize') {
    const q = url.searchParams;
    if (!groups[q.get('user')] || q.get('client_id') !== clientId) return send(400, '{"error":"invalid_request"}');
    const code = crypto.randomBytes(16).toString('hex');
    codes.set(code, { user: q.get('user'), nonce: q.get('nonce') });
    const back = new URL(q.get('redirect_uri'));
    back.searchParams.set('code', code);
    back.searchParams.set('state', q.get('state'));
    return send(302, '', { Location: back.toString() });
  }
  if (url.pathname === '/token' && req.method === 'POST') {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', () => {
      const form = new URLSearchParams(raw);
      let id = form.get('client_id');
      let secret = form.get('client_secret');
      const auth = req.headers.authorization || '';
      if (auth.startsWith('Basic ')) {
        const pair = Buffer.from(auth.slice(6), 'base64').toString();
        id = formDecode(pair.slice(0, pair.indexOf(':')));
        secret = formDecode(pair.slice(pair.indexOf(':') + 1));
      }
      const grant = codes.get(form.get('code'));
      codes.delete(form.get('code'));
      if (id !== clientId || secret !== clientSecret || !grant) return send(401, '{"error":"invalid_client"}');
      const now = Math.floor(Date.now() / 1000);
      const claims = {
        iss: issuer, sub: grant.user, aud: clientId, azp: clientId, iat: now, exp: now + 300,
        email: `${grant.user}@e2e.test`, email_verified: true, preferred_username: grant.user, groups: groups[grant.user],
      };
      if (grant.nonce) claims.nonce = grant.nonce;
      return send(200, JSON.stringify({ access_token: sign(claims), id_token: sign(claims), token_type: 'Bearer', expires_in: 300 }));
    });
    return undefined;
  }
  return send(404, '{}');
}).listen(8443);
