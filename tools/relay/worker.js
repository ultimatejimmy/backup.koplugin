/**
 * KOReader Backup Beam Relay - Cloudflare Worker / Serverless Edge Relay
 *
 * Ephemeral, zero-knowledge relay for transferring encrypted KOReader backups
 * between devices using a temporary 6-digit PIN.
 *
 * Storage: Cloudflare Workers KV (distributed across all global edge nodes)
 * Lifecycle: Native 15-minute TTL expiration (0 delete operations consumed on download,
 *            enabling connection-loss retry resilience).
 * Metadata: Single-key metadata storage (1 write per transfer for archives <= 20MB).
 * Multi-part chunking: Supports backups up to 100MB across 20MB KV limit.
 */

const MAX_KV_CHUNK_SIZE = 20 * 1024 * 1024; // 20MB chunks (Cloudflare KV limit is 25MB)
const EXPIRATION_TTL = 900; // 15 minutes (Cloudflare automatically purges keys)

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, HEAD, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, X-Beam-Token',
      'Access-Control-Max-Age': '86400',
    };

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    // Health check (JSON)
    const acceptHeader = request.headers.get('Accept') || '';
    if (path === '/health' || (path === '/' && acceptHeader.includes('application/json'))) {
      return new Response(JSON.stringify({
        status: 'ok',
        service: 'koreader-beam-relay',
        version: '2.5',
        kv_bound: !!env.BEAM_KV,
        oauth_configured: !!env.GDRIVE_CLIENT_SECRET,
        mode: 'native_expiration_single_write',
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Beam Web Download Portal (Browser UI)
    if ((path === '/' || path === '/beam' || path === '/download') && request.method === 'GET') {
      const code = url.searchParams.get('code') || url.searchParams.get('pin') || '';
      return new Response(renderBeamWebPortal(code), {
        headers: { ...corsHeaders, 'Content-Type': 'text/html; charset=utf-8' },
      });
    }

    // -------------------------------------------------------------------------
    // OAuth2 Relay for Google Drive Device Authorization Grant (RFC 8628)
    // Securely exchanges device codes & refreshes tokens without exposing
    // client_secret to client apps or git repositories.
    // -------------------------------------------------------------------------

    // Poll Token endpoint: POST /api/oauth/gdrive/poll
    if (path === '/api/oauth/gdrive/poll' && request.method === 'POST') {
      if (!env.GDRIVE_CLIENT_SECRET) {
        return new Response(JSON.stringify({
          error: 'server_error',
          error_description: 'GDRIVE_CLIENT_SECRET is not configured in worker environment',
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      let payload = {};
      try {
        payload = await request.json();
      } catch (_) {}

      const deviceCode = payload.device_code || url.searchParams.get('device_code');
      if (!deviceCode) {
        return new Response(JSON.stringify({
          error: 'invalid_request',
          error_description: 'Missing device_code parameter',
        }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const clientId = env.GDRIVE_CLIENT_ID || '444320595925-2mlkslggov1f25qv45th2tq3dl466f9u.apps.googleusercontent.com';
      const form = new URLSearchParams();
      form.set('client_id', clientId);
      form.set('client_secret', env.GDRIVE_CLIENT_SECRET);
      form.set('device_code', deviceCode);
      form.set('grant_type', 'urn:ietf:params:oauth:grant-type:device_code');

      try {
        const gResp = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: form.toString(),
        });
        const gData = await gResp.text();
        return new Response(gData, {
          status: gResp.status,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      } catch (err) {
        return new Response(JSON.stringify({
          error: 'relay_error',
          error_description: 'Failed to contact Google OAuth: ' + (err.message || String(err)),
        }), {
          status: 502,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // Refresh Token endpoint: POST /api/oauth/gdrive/refresh
    if (path === '/api/oauth/gdrive/refresh' && request.method === 'POST') {
      if (!env.GDRIVE_CLIENT_SECRET) {
        return new Response(JSON.stringify({
          error: 'server_error',
          error_description: 'GDRIVE_CLIENT_SECRET is not configured in worker environment',
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      let payload = {};
      try {
        payload = await request.json();
      } catch (_) {}

      const refreshToken = payload.refresh_token || url.searchParams.get('refresh_token');
      if (!refreshToken) {
        return new Response(JSON.stringify({
          error: 'invalid_request',
          error_description: 'Missing refresh_token parameter',
        }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const clientId = env.GDRIVE_CLIENT_ID || '444320595925-2mlkslggov1f25qv45th2tq3dl466f9u.apps.googleusercontent.com';
      const form = new URLSearchParams();
      form.set('client_id', clientId);
      form.set('client_secret', env.GDRIVE_CLIENT_SECRET);
      form.set('refresh_token', refreshToken);
      form.set('grant_type', 'refresh_token');

      try {
        const gResp = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: form.toString(),
        });
        const gData = await gResp.text();
        return new Response(gData, {
          status: gResp.status,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      } catch (err) {
        return new Response(JSON.stringify({
          error: 'relay_error',
          error_description: 'Failed to contact Google OAuth: ' + (err.message || String(err)),
        }), {
          status: 502,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // -------------------------------------------------------------------------
    // OAuth2 Relay for Dropbox (Bridge for headless devices)
    // Converts Dropbox authorization code flow into a device-friendly PIN flow.
    // -------------------------------------------------------------------------

    // 1. Init: POST /api/oauth/dropbox/init
    if (path === '/api/oauth/dropbox/init' && (request.method === 'POST' || request.method === 'GET')) {
      if (!env.BEAM_KV) {
        return new Response(JSON.stringify({
          error: 'server_error',
          error_description: 'BEAM_KV is not configured in worker environment',
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const clientId = env.DROPBOX_CLIENT_ID || 'khboin1ohr74q7y';
      const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      let session = '';
      for (let i = 0; i < 8; i++) {
        session += chars.charAt(Math.floor(Math.random() * chars.length));
      }

      await env.BEAM_KV.put('oauth:dropbox:session:' + session, JSON.stringify({
        status: 'pending',
        created_at: Date.now(),
      }), { expirationTtl: 600 }); // 10 minutes

      const authUrl = `${url.origin}/link`;
      return new Response(JSON.stringify({
        device_code: session,
        user_code: session,
        verification_url: authUrl,
        expires_in: 600,
        interval: 5,
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Short verification page: GET /link or GET /dropbox
    if ((path === '/link' || path === '/dropbox') && request.method === 'GET') {
      const session = url.searchParams.get('session') || url.searchParams.get('code');
      if (session) {
        const clientId = env.DROPBOX_CLIENT_ID || 'khboin1ohr74q7y';
        const callbackUrl = `${url.origin}/api/oauth/dropbox/callback`;
        const scopes = 'account_info.read files.content.write files.content.read files.metadata.read files.metadata.write';
        const dbxAuthUrl = `https://www.dropbox.com/oauth2/authorize?client_id=${clientId}&response_type=code&token_access_type=offline&redirect_uri=${encodeURIComponent(callbackUrl)}&state=${encodeURIComponent(session.trim().toUpperCase())}&scope=${encodeURIComponent(scopes)}`;
        return Response.redirect(dbxAuthUrl, 302);
      }

      return new Response(`<!DOCTYPE html><html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Connect Dropbox to KOReader</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif; background: #f5f5f7; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }
          .card { background: #fff; padding: 36px 28px; border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); max-width: 380px; width: 100%; text-align: center; }
          h2 { margin: 0 0 10px; font-size: 22px; color: #1d1d1f; }
          p { color: #6e6e73; font-size: 14px; margin: 0 0 24px; line-height: 1.4; }
          input { width: 100%; box-sizing: border-box; font-size: 24px; font-weight: bold; letter-spacing: 3px; text-transform: uppercase; text-align: center; padding: 14px; border: 2px solid #d2d2d7; border-radius: 10px; outline: none; margin-bottom: 18px; }
          input:focus { border-color: #0061fe; }
          button { width: 100%; padding: 14px; font-size: 16px; font-weight: 600; color: #fff; background: #0061fe; border: none; border-radius: 10px; cursor: pointer; }
          button:hover { background: #0050d4; }
        </style>
      </head>
      <body>
        <div class="card">
          <h2>Connect Dropbox</h2>
          <p>Enter the 8-character code shown on your e-reader screen:</p>
          <form action="/link" method="GET">
            <input type="text" name="session" placeholder="XXXXXXXX" maxlength="12" autofocus required />
            <button type="submit">Authorize with Dropbox</button>
          </form>
        </div>
      </body>
      </html>`, {
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      });
    }

    // 2b. Direct Auth redirect: GET /api/oauth/dropbox/auth
    if (path === '/api/oauth/dropbox/auth' && request.method === 'GET') {
      const session = url.searchParams.get('session');
      if (!session) {
        return new Response('Missing session parameter', { status: 400 });
      }

      const clientId = env.DROPBOX_CLIENT_ID || 'khboin1ohr74q7y';
      const callbackUrl = `${url.origin}/api/oauth/dropbox/callback`;
      const scopes = 'account_info.read files.content.write files.content.read files.metadata.read files.metadata.write';
      const dbxAuthUrl = `https://www.dropbox.com/oauth2/authorize?client_id=${clientId}&response_type=code&token_access_type=offline&redirect_uri=${encodeURIComponent(callbackUrl)}&state=${encodeURIComponent(session.trim().toUpperCase())}&scope=${encodeURIComponent(scopes)}`;

      return Response.redirect(dbxAuthUrl, 302);
    }

    // 3. Callback from Dropbox: GET /api/oauth/dropbox/callback
    if (path === '/api/oauth/dropbox/callback' && request.method === 'GET') {
      const code = url.searchParams.get('code');
      const state = url.searchParams.get('state'); // session ID
      const error = url.searchParams.get('error');
      const errorDesc = url.searchParams.get('error_description');

      if (error) {
        return new Response(`<!DOCTYPE html><html><body style="font-family:sans-serif;text-align:center;padding:50px;">
          <h2>❌ Authorization Error</h2>
          <p>${errorDesc || error}</p>
          <p>Please return to KOReader and try again.</p>
        </body></html>`, {
          status: 400,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      }

      if (!code || !state || !env.BEAM_KV) {
        return new Response('Missing code or state parameter', { status: 400 });
      }

      const sessionDataStr = await env.BEAM_KV.get('oauth:dropbox:session:' + state);
      if (!sessionDataStr) {
        return new Response(`<!DOCTYPE html><html><body style="font-family:sans-serif;text-align:center;padding:50px;">
          <h2>❌ Session Expired</h2>
          <p>The authorization session has expired. Please restart the connection on your e-reader.</p>
        </body></html>`, {
          status: 400,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      }

      const clientId = env.DROPBOX_CLIENT_ID || 'khboin1ohr74q7y';
      const clientSecret = env.DROPBOX_CLIENT_SECRET;
      const callbackUrl = `${url.origin}/api/oauth/dropbox/callback`;

      const form = new URLSearchParams();
      form.set('code', code);
      form.set('grant_type', 'authorization_code');
      form.set('client_id', clientId);
      if (clientSecret) form.set('client_secret', clientSecret);
      form.set('redirect_uri', callbackUrl);

      try {
        const tokenResp = await fetch('https://api.dropboxapi.com/oauth2/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: form.toString(),
        });
        const tokenData = await tokenResp.json();

        if (tokenData.access_token) {
          await env.BEAM_KV.put('oauth:dropbox:session:' + state, JSON.stringify({
            status: 'authorized',
            tokens: tokenData,
          }), { expirationTtl: 300 }); // 5 minutes to poll

          return new Response(`<!DOCTYPE html><html><body style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;text-align:center;padding:60px 20px;background:#f9f9f9;">
            <div style="max-width:420px;margin:0 auto;background:#fff;padding:40px;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,0.08);">
              <div style="font-size:48px;margin-bottom:16px;">✅</div>
              <h2 style="margin:0 0 12px;color:#1e1e1e;">KOReader Connected!</h2>
              <p style="color:#555;font-size:16px;line-height:1.5;">Dropbox has been successfully authorized for KOReader Backup.</p>
              <p style="color:#888;font-size:14px;margin-top:24px;">You can now close this tab and return to your e-reader.</p>
            </div>
          </body></html>`, {
            headers: { 'Content-Type': 'text/html; charset=utf-8' },
          });
        } else {
          return new Response(`<!DOCTYPE html><html><body style="font-family:sans-serif;text-align:center;padding:50px;">
            <h2>❌ Token Exchange Failed</h2>
            <p>${tokenData.error_description || tokenData.error || 'Unknown error'}</p>
          </body></html>`, {
            status: 400,
            headers: { 'Content-Type': 'text/html; charset=utf-8' },
          });
        }
      } catch (err) {
        return new Response('Failed to contact Dropbox: ' + (err.message || String(err)), { status: 502 });
      }
    }

    // 4. Poll: POST /api/oauth/dropbox/poll
    if (path === '/api/oauth/dropbox/poll' && request.method === 'POST') {
      if (!env.BEAM_KV) {
        return new Response(JSON.stringify({ error: 'server_error', error_description: 'BEAM_KV not configured' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      let payload = {};
      try { payload = await request.json(); } catch (_) {}
      const deviceCode = payload.device_code || url.searchParams.get('device_code');

      if (!deviceCode) {
        return new Response(JSON.stringify({ error: 'invalid_request', error_description: 'Missing device_code' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const sessionStr = await env.BEAM_KV.get('oauth:dropbox:session:' + deviceCode);
      if (!sessionStr) {
        return new Response(JSON.stringify({ error: 'expired_token', error_description: 'Session expired or not found' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const sessionData = JSON.parse(sessionStr);
      if (sessionData.status === 'pending') {
        return new Response(JSON.stringify({ error: 'authorization_pending' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (sessionData.status === 'authorized' && sessionData.tokens) {
        await env.BEAM_KV.delete('oauth:dropbox:session:' + deviceCode);
        return new Response(JSON.stringify(sessionData.tokens), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ error: 'invalid_grant' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 5. Refresh: POST /api/oauth/dropbox/refresh
    if (path === '/api/oauth/dropbox/refresh' && request.method === 'POST') {
      let payload = {};
      try { payload = await request.json(); } catch (_) {}
      const refreshToken = payload.refresh_token || url.searchParams.get('refresh_token');

      if (!refreshToken) {
        return new Response(JSON.stringify({ error: 'invalid_request', error_description: 'Missing refresh_token' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const clientId = env.DROPBOX_CLIENT_ID || 'khboin1ohr74q7y';
      const clientSecret = env.DROPBOX_CLIENT_SECRET;

      const form = new URLSearchParams();
      form.set('grant_type', 'refresh_token');
      form.set('refresh_token', refreshToken);
      form.set('client_id', clientId);
      if (clientSecret) form.set('client_secret', clientSecret);

      try {
        const dbxResp = await fetch('https://api.dropboxapi.com/oauth2/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: form.toString(),
        });
        const dbxData = await dbxResp.text();
        return new Response(dbxData, {
          status: dbxResp.status,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      } catch (err) {
        return new Response(JSON.stringify({
          error: 'relay_error',
          error_description: 'Failed to contact Dropbox OAuth: ' + (err.message || String(err)),
        }), {
          status: 502,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // Helper to resolve beam token
    const extractToken = () => {
      const headerToken = request.headers.get('X-Beam-Token');
      const queryToken = url.searchParams.get('token');
      const parts = path.split('/');
      // e.g. /api/beam/download/:token, /api/beam/info/:token, or /api/beam/:token
      let pathToken = null;
      if (parts.length >= 4 && (parts[2] === 'beam' || parts[1] === 'beam')) {
        pathToken = parts[parts.length - 1];
        if (pathToken === 'download' || pathToken === 'upload' || pathToken === 'info') {
          pathToken = null;
        }
      }
      const token = pathToken || headerToken || queryToken;
      return (token && token.trim().length >= 6) ? token.trim() : null;
    };

    // Helper to get archive size without downloading entire payload
    const getArchiveSize = async (token) => {
      if (!env.BEAM_KV) return null;

      // 1. Check embedded key metadata on single-chunk archive (fastest, 0 extra writes)
      try {
        const item = await env.BEAM_KV.getWithMetadata(`beam:${token}`, { type: 'stream' });
        if (item && item.metadata && typeof item.metadata.size === 'number') {
          return item.metadata.size;
        }
      } catch (_) {}

      // 2. Check multi-chunk meta key (for archives > 20MB)
      try {
        const metaStr = await env.BEAM_KV.get(`beam:${token}:meta`);
        if (metaStr) {
          const meta = JSON.parse(metaStr);
          if (meta && typeof meta.size === 'number') return meta.size;
        }
      } catch (_) {}

      // 3. Fallback for backwards compatibility with previous info key
      try {
        const infoStr = await env.BEAM_KV.get(`beam:${token}:info`);
        if (infoStr) {
          const info = JSON.parse(infoStr);
          if (info && typeof info.size === 'number') return info.size;
        }
      } catch (_) {}

      return null;
    };

    // Helper to clean up all keys associated with a token (used for manual cancellation)
    const deleteArchive = async (token) => {
      if (!env.BEAM_KV) return;
      const metaStr = await env.BEAM_KV.get(`beam:${token}:meta`);
      if (metaStr) {
        try {
          const meta = JSON.parse(metaStr);
          for (let i = 0; i < meta.chunks; i++) {
            await env.BEAM_KV.delete(`beam:${token}:${i}`);
          }
          await env.BEAM_KV.delete(`beam:${token}:meta`);
        } catch (_) {}
      }
      await env.BEAM_KV.delete(`beam:${token}:info`);
      await env.BEAM_KV.delete(`beam:${token}`);
    };

    // Upload: POST /api/beam/upload
    if (request.method === 'POST' && (path === '/api/beam/upload' || path.startsWith('/api/beam/upload'))) {
      if (!env.BEAM_KV) {
        return new Response(JSON.stringify({
          error: 'BEAM_KV binding is missing. Distributed cross-device relay requires Cloudflare KV.',
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const token = request.headers.get('X-Beam-Token') || url.searchParams.get('token');
      if (!token || token.trim().length < 6) {
        return new Response(JSON.stringify({ error: 'Missing or invalid X-Beam-Token' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const cleanToken = token.trim();
      let body;
      try {
        body = await request.arrayBuffer();
      } catch (readErr) {
        return new Response(JSON.stringify({ error: 'Failed to read upload payload: ' + (readErr.message || String(readErr)) }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (!body || body.byteLength === 0) {
        return new Response(JSON.stringify({ error: 'Empty payload' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Max size limit: 100MB (Cloudflare Workers request limit)
      if (body.byteLength > 100 * 1024 * 1024) {
        return new Response(JSON.stringify({ error: 'Payload exceeds 100MB limit' }), {
          status: 413,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      try {
        if (body.byteLength <= MAX_KV_CHUNK_SIZE) {
          // Single chunk upload: store payload AND size metadata in 1 single KV write!
          await env.BEAM_KV.put(`beam:${cleanToken}`, body, {
            metadata: { size: body.byteLength },
            expirationTtl: EXPIRATION_TTL,
          });
        } else {
          // Multi-chunk upload for archives > 20MB
          const totalChunks = Math.ceil(body.byteLength / MAX_KV_CHUNK_SIZE);
          await env.BEAM_KV.put(`beam:${cleanToken}:meta`, JSON.stringify({
            chunks: totalChunks,
            size: body.byteLength,
          }), { expirationTtl: EXPIRATION_TTL });

          for (let i = 0; i < totalChunks; i++) {
            const start = i * MAX_KV_CHUNK_SIZE;
            const end = Math.min(start + MAX_KV_CHUNK_SIZE, body.byteLength);
            const chunk = body.slice(start, end);
            await env.BEAM_KV.put(`beam:${cleanToken}:${i}`, chunk, { expirationTtl: EXPIRATION_TTL });
          }
        }
      } catch (kvErr) {
        return new Response(JSON.stringify({ error: 'Failed to store archive in KV: ' + (kvErr.message || String(kvErr)) }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({
        ok: true,
        token: cleanToken,
        size: body.byteLength,
        expires_in: EXPIRATION_TTL,
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Info: GET /api/beam/info/:token or HEAD /api/beam/download/:token
    if ((request.method === 'GET' && path.startsWith('/api/beam/info')) ||
        (request.method === 'HEAD' && path.startsWith('/api/beam/download'))) {
      if (!env.BEAM_KV) {
        return new Response(JSON.stringify({
          error: 'BEAM_KV binding is missing.',
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const token = extractToken();
      if (!token) {
        return new Response(JSON.stringify({ error: 'Missing or invalid token' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const size = await getArchiveSize(token);
      if (size === null) {
        return new Response(JSON.stringify({ error: 'Beam code expired or not found' }), {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const headers = {
        ...corsHeaders,
        'Content-Type': 'application/json',
        'Content-Length': size.toString(),
        'X-Beam-Size': size.toString(),
      };

      if (request.method === 'HEAD') {
        return new Response(null, { headers });
      }

      return new Response(JSON.stringify({
        ok: true,
        token: token,
        size: size,
        expires_in: EXPIRATION_TTL,
      }), { headers });
    }

    // Download: GET /api/beam/download/:token or GET /api/beam/download?token=:token
    if (request.method === 'GET' && path.startsWith('/api/beam/download')) {
      if (!env.BEAM_KV) {
        return new Response(JSON.stringify({
          error: 'BEAM_KV binding is missing. Distributed cross-device relay requires Cloudflare KV.',
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const token = extractToken();
      if (!token) {
        return new Response(JSON.stringify({ error: 'Missing or invalid token' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      let data = null;

      // Check for multi-chunk archive first
      const metaStr = await env.BEAM_KV.get(`beam:${token}:meta`);
      if (metaStr) {
        try {
          const meta = JSON.parse(metaStr);
          const combined = new Uint8Array(meta.size);
          let offset = 0;
          for (let i = 0; i < meta.chunks; i++) {
            const chunkBuf = await env.BEAM_KV.get(`beam:${token}:${i}`, { type: 'arrayBuffer' });
            if (!chunkBuf) {
              return new Response(JSON.stringify({ error: 'Beam archive corrupted or incomplete' }), {
                status: 404,
                headers: { ...corsHeaders, 'Content-Type': 'application/json' },
              });
            }
            combined.set(new Uint8Array(chunkBuf), offset);
            offset += chunkBuf.byteLength;
          }
          data = combined.buffer;
        } catch (e) {
          return new Response(JSON.stringify({ error: 'Failed to reassemble chunks' }), {
            status: 500,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
      } else {
        // Standard single-chunk archive
        data = await env.BEAM_KV.get(`beam:${token}`, { type: 'arrayBuffer' });
      }

      if (!data) {
        return new Response(JSON.stringify({ error: 'Beam code expired or not found' }), {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // NOTE: We rely on native KV expiration (expirationTtl: 900) instead of deleting immediately.
      // Benefits:
      // 1. Zero delete quota consumed (saves 1,000 deletes/day).
      // 2. Retry resilience: if an e-reader drops Wi-Fi mid-download, the user can re-try without re-uploading.

      return new Response(data, {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/octet-stream',
          'Content-Length': data.byteLength.toString(),
          'Content-Disposition': `attachment; filename="beam_${token}.kobeam"`,
        },
      });
    }

    // Cancel: DELETE /api/beam/:token (explicit user cancel)
    if (request.method === 'DELETE' && (path.startsWith('/api/beam/') || path === '/api/beam')) {
      const token = extractToken();
      if (token && env.BEAM_KV) {
        await deleteArchive(token);
      }
      return new Response(JSON.stringify({ ok: true }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ error: 'Not found' }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
};

/**
 * Render the Beam Web Download Portal HTML application
 * Single-file responsive SPA with zero-knowledge in-browser decryption
 */
function renderBeamWebPortal(initialCode) {
  const safeCode = (initialCode || '').replace(/[^0-9a-zA-Z -]/g, '').slice(0, 10);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>KOReader Beam - Download Backup</title>
  <style>
    :root {
      --bg: #f5f5f7;
      --card-bg: #ffffff;
      --text: #1d1d1f;
      --text-muted: #6e6e73;
      --border: #d2d2d7;
      --primary: #0066cc;
      --primary-hover: #0055b3;
      --success: #34c759;
      --error: #ff3b30;
      --card-shadow: 0 4px 24px rgba(0, 0, 0, 0.08);
      --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #121212;
        --card-bg: #1e1e1e;
        --text: #f5f5f7;
        --text-muted: #a1a1a6;
        --border: #38383a;
        --primary: #2997ff;
        --primary-hover: #147ce5;
        --card-shadow: 0 4px 24px rgba(0, 0, 0, 0.35);
      }
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: var(--font);
      background-color: var(--bg);
      color: var(--text);
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      padding: 24px 16px;
      line-height: 1.5;
    }
    .container {
      width: 100%;
      max-width: 440px;
    }
    .card {
      background: var(--card-bg);
      border-radius: 20px;
      padding: 36px 28px;
      box-shadow: var(--card-shadow);
      border: 1px solid var(--border);
      text-align: center;
    }
    .logo {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 56px;
      height: 56px;
      background: var(--primary);
      color: #fff;
      border-radius: 16px;
      margin-bottom: 20px;
    }
    .logo svg { width: 30px; height: 30px; fill: currentColor; }
    h1 {
      font-size: 24px;
      font-weight: 700;
      letter-spacing: -0.5px;
      margin-bottom: 8px;
    }
    p.subtitle {
      color: var(--text-muted);
      font-size: 14px;
      margin-bottom: 28px;
    }
    .input-group {
      margin-bottom: 22px;
      text-align: left;
    }
    label {
      display: block;
      font-size: 13px;
      font-weight: 600;
      color: var(--text-muted);
      margin-bottom: 8px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .pin-input {
      width: 100%;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 32px;
      font-weight: 700;
      letter-spacing: 8px;
      text-align: center;
      padding: 14px 10px;
      border: 2px solid var(--border);
      border-radius: 12px;
      background: transparent;
      color: var(--text);
      outline: none;
      transition: border-color 0.2s, box-shadow 0.2s;
    }
    .pin-input:focus {
      border-color: var(--primary);
      box-shadow: 0 0 0 3px rgba(0, 102, 204, 0.2);
    }
    .btn {
      width: 100%;
      padding: 14px;
      font-size: 16px;
      font-weight: 600;
      border-radius: 12px;
      border: none;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      transition: background-color 0.2s, opacity 0.2s;
    }
    .btn-primary {
      background: var(--primary);
      color: #fff;
    }
    .btn-primary:hover:not(:disabled) {
      background: var(--primary-hover);
    }
    .btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .btn-danger {
      background: transparent;
      color: var(--error);
      border: 1px solid var(--error);
      margin-top: 12px;
      font-size: 13px;
      padding: 8px;
    }
    .btn-danger:hover {
      background: rgba(255, 59, 48, 0.1);
    }
    .status-box {
      margin-top: 24px;
      padding: 16px;
      border-radius: 12px;
      background: rgba(0, 102, 204, 0.06);
      text-align: left;
      font-size: 14px;
    }
    .status-row {
      display: flex;
      justify-content: space-between;
      margin-bottom: 6px;
    }
    .status-row:last-child { margin-bottom: 0; }
    .status-label { color: var(--text-muted); }
    .status-val { font-weight: 600; font-family: monospace; }
    .progress-bar {
      height: 8px;
      background: var(--border);
      border-radius: 4px;
      margin-top: 14px;
      overflow: hidden;
    }
    .progress-fill {
      height: 100%;
      background: var(--primary);
      width: 0%;
      transition: width 0.2s ease;
    }
    .alert {
      margin-top: 20px;
      padding: 12px 14px;
      border-radius: 10px;
      font-size: 14px;
      text-align: left;
      display: flex;
      align-items: flex-start;
      gap: 10px;
    }
    .alert-error {
      background: rgba(255, 59, 48, 0.12);
      color: var(--error);
      border: 1px solid rgba(255, 59, 48, 0.3);
    }
    .alert-success {
      background: rgba(52, 199, 89, 0.12);
      color: var(--success);
      border: 1px solid rgba(52, 199, 89, 0.3);
    }
    .footer-links {
      margin-top: 24px;
      font-size: 12px;
      color: var(--text-muted);
      text-align: center;
    }
    .footer-links a {
      color: var(--primary);
      text-decoration: none;
    }
    .footer-links a:hover { text-decoration: underline; }
    .hidden { display: none !important; }
    .spinner {
      width: 18px;
      height: 18px;
      border: 2px solid rgba(255, 255, 255, 0.3);
      border-radius: 50%;
      border-top-color: #fff;
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="card">
      <div class="logo">
        <svg viewBox="0 0 24 24">
          <path d="M19 1H5a2 2 0 0 0-2 2v18a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2zm-1 18H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1zM8 7h8v2H8zm0 4h8v2H8zm0 4h5v2H8z"/>
        </svg>
      </div>
      <h1>KOReader Beam</h1>
      <p class="subtitle">Download and decrypt your wireless backup</p>

      <form id="beam-form" onsubmit="event.preventDefault(); handleAction();">
        <div class="input-group">
          <label for="pin-input">6-Digit Beam Code</label>
          <input
            type="text"
            id="pin-input"
            class="pin-input"
            placeholder="000 000"
            maxlength="7"
            autocomplete="off"
            autofocus
            required
          />
        </div>

        <button type="submit" id="action-btn" class="btn btn-primary">
          <span id="btn-spinner" class="spinner hidden"></span>
          <span id="btn-text">Download Backup</span>
        </button>
      </form>

      <div id="status-card" class="status-box hidden">
        <div class="status-row">
          <span class="status-label">Archive:</span>
          <span id="stat-filename" class="status-val">Checking...</span>
        </div>
        <div class="status-row">
          <span class="status-label">Size:</span>
          <span id="stat-size" class="status-val">-</span>
        </div>
        <div class="status-row">
          <span class="status-label">Time Remaining:</span>
          <span id="stat-timer" class="status-val">15m</span>
        </div>
        <div id="progress-container" class="hidden">
          <div class="progress-bar">
            <div id="progress-fill" class="progress-fill"></div>
          </div>
          <div style="font-size: 11px; color: var(--text-muted); margin-top: 4px; text-align: right;" id="progress-text">0%</div>
        </div>
        <button id="del-btn" class="btn btn-danger hidden" onclick="handleDelete()">Delete from Relay Now</button>
      </div>

      <div id="alert-error" class="alert alert-error hidden">
        <span>⚠️</span>
        <div id="alert-error-msg">Error</div>
      </div>

      <div id="alert-success" class="alert alert-success hidden">
        <span>✅</span>
        <div id="alert-success-msg">Backup downloaded and decrypted successfully!</div>
      </div>

      <div class="footer-links">
        <p>🔒 End-to-end zero-knowledge encryption</p>
        <p style="margin-top: 4px;">Payload is decrypted entirely inside your browser.</p>
        <p style="margin-top: 6px;"><a href="#" id="raw-download-link" class="hidden" onclick="downloadRawPayload(event)">Download encrypted .kobeam file</a></p>
      </div>
    </div>
  </div>

  <script>
    function cleanPin(str) { return (str || '').replace(/\\D/g, ''); }

    function sha256Bytes(data) {
      if (typeof data === 'string') data = new TextEncoder().encode(data);
      const K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
      ];
      let H0 = 0x6a09e667, H1 = 0xbb67ae85, H2 = 0x3c6ef372, H3 = 0xa54ff53a;
      let H4 = 0x510e527f, H5 = 0x9b05688c, H6 = 0x1f83d9ab, H7 = 0x5be0cd19;
      const len = data.length, bitLen = len * 8;
      const padLen = ((len + 8 + 64) >>> 6) << 6;
      const buf = new Uint8Array(padLen);
      buf.set(data);
      buf[len] = 0x80;
      const view = new DataView(buf.buffer);
      view.setUint32(padLen - 4, bitLen >>> 0, false);
      view.setUint32(padLen - 8, Math.floor(bitLen / 0x100000000), false);
      const W = new Uint32Array(64);
      for (let offset = 0; offset < padLen; offset += 64) {
        for (let t = 0; t < 16; t++) W[t] = view.getUint32(offset + t * 4, false);
        for (let t = 16; t < 64; t++) {
          const s0 = ((W[t-15] >>> 7) | (W[t-15] << 25)) ^ ((W[t-15] >>> 18) | (W[t-15] << 14)) ^ (W[t-15] >>> 3);
          const s1 = ((W[t-2] >>> 17) | (W[t-2] << 15)) ^ ((W[t-2] >>> 19) | (W[t-2] << 13)) ^ (W[t-2] >>> 10);
          W[t] = (W[t-16] + s0 + W[t-7] + s1) >>> 0;
        }
        let a = H0, b = H1, c = H2, d = H3, e = H4, f = H5, g = H6, h = H7;
        for (let t = 0; t < 64; t++) {
          const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
          const ch = (e & f) ^ ((~e) & g);
          const temp1 = (h + S1 + ch + K[t] + W[t]) >>> 0;
          const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
          const maj = (a & b) ^ (a & c) ^ (b & c);
          const temp2 = (S0 + maj) >>> 0;
          h = g; g = f; f = e; e = (d + temp1) >>> 0; d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
        }
        H0 = (H0 + a) >>> 0; H1 = (H1 + b) >>> 0; H2 = (H2 + c) >>> 0; H3 = (H3 + d) >>> 0;
        H4 = (H4 + e) >>> 0; H5 = (H5 + f) >>> 0; H6 = (H6 + g) >>> 0; H7 = (H7 + h) >>> 0;
      }
      const res = new Uint8Array(32);
      const ov = new DataView(res.buffer);
      ov.setUint32(0, H0, false); ov.setUint32(4, H1, false); ov.setUint32(8, H2, false); ov.setUint32(12, H3, false);
      ov.setUint32(16, H4, false); ov.setUint32(20, H5, false); ov.setUint32(24, H6, false); ov.setUint32(28, H7, false);
      return res;
    }

    function bytesToHex(bytes) {
      let hex = '';
      for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
      return hex;
    }

    function sha256Hex(data) { return bytesToHex(sha256Bytes(data)); }

    function hmacSha256Hex(key, message) {
      const enc = new TextEncoder();
      const keyBytes = typeof key === 'string' ? enc.encode(key) : key;
      const msgBytes = typeof message === 'string' ? enc.encode(message) : message;
      const blockSize = 64;
      let k = new Uint8Array(blockSize);
      if (keyBytes.length > blockSize) k.set(sha256Bytes(keyBytes));
      else k.set(keyBytes);
      const oPad = new Uint8Array(blockSize + 32);
      const iPad = new Uint8Array(blockSize + msgBytes.length);
      for (let i = 0; i < blockSize; i++) {
        oPad[i] = k[i] ^ 0x5c;
        iPad[i] = k[i] ^ 0x36;
      }
      iPad.set(msgBytes, blockSize);
      oPad.set(sha256Bytes(iPad), blockSize);
      return bytesToHex(sha256Bytes(oPad));
    }

    function deriveBeamToken(pin) {
      const clean = cleanPin(pin);
      if (clean.length !== 6) return null;
      return sha256Hex('kobeam_token:' + clean).substring(0, 16);
    }

    function generateKeystreamMask(keyHex, requiredLen = 65536) {
      const maskBlocks = Math.ceil(requiredLen / 32);
      const mask = new Uint8Array(maskBlocks * 32);
      for (let i = 1; i <= maskBlocks; i++) {
        const hexCounter = i.toString(16).padStart(8, '0');
        mask.set(sha256Bytes(keyHex + hexCounter), (i - 1) * 32);
      }
      return mask.subarray(0, requiredLen);
    }

    function decryptBeamPayload(buffer, pin) {
      const clean = cleanPin(pin);
      const textDecoder = new TextDecoder();
      const magic = textDecoder.decode(buffer.subarray(0, 8));
      if (magic !== 'KOBEAM01') throw new Error('Invalid Beam archive format');
      let offset = 8;
      const salt = textDecoder.decode(buffer.subarray(offset, offset + 32)); offset += 32;
      const receivedTag = textDecoder.decode(buffer.subarray(offset, offset + 64)); offset += 64;
      const fnLenHex = textDecoder.decode(buffer.subarray(offset, offset + 4)); offset += 4;
      const fnLen = parseInt(fnLenHex, 16);
      if (isNaN(fnLen) || fnLen <= 0 || fnLen > 256) throw new Error('Invalid filename length');
      const filename = textDecoder.decode(buffer.subarray(offset, offset + fnLen)); offset += fnLen;
      const ciphertext = buffer.subarray(offset);
      const keyHex = sha256Hex('kobeam_key:' + clean + ':' + salt);
      const dataHash = sha256Hex(ciphertext);
      const expectedTag = hmacSha256Hex(keyHex, salt + filename + dataHash);
      if (receivedTag !== expectedTag) throw new Error('Invalid Beam code or corrupted data');

      const mask = generateKeystreamMask(keyHex, 65536);
      const plaintext = new Uint8Array(ciphertext.length);
      const words = Math.floor(ciphertext.length / 4);
      const src32 = new Uint32Array(ciphertext.buffer, ciphertext.byteOffset, words);
      const dst32 = new Uint32Array(plaintext.buffer, plaintext.byteOffset, words);
      const mask32 = new Uint32Array(mask.buffer, mask.byteOffset, 16384);
      for (let i = 0; i < words; i++) dst32[i] = src32[i] ^ mask32[i % 16384];
      const rem = words * 4;
      for (let i = rem; i < ciphertext.length; i++) plaintext[i] = ciphertext[i] ^ mask[i % 65536];
      return { filename, bytes: plaintext, size: plaintext.length };
    }

    function formatBytes(bytes) {
      if (!bytes || bytes === 0) return '0 B';
      const k = 1024, dm = 1;
      const sizes = ['B', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
    }

    const input = document.getElementById('pin-input');
    const btn = document.getElementById('action-btn');
    const btnSpinner = document.getElementById('btn-spinner');
    const btnText = document.getElementById('btn-text');
    const statusCard = document.getElementById('status-card');
    const statFilename = document.getElementById('stat-filename');
    const statSize = document.getElementById('stat-size');
    const statTimer = document.getElementById('stat-timer');
    const progressContainer = document.getElementById('progress-container');
    const progressFill = document.getElementById('progress-fill');
    const progressText = document.getElementById('progress-text');
    const alertError = document.getElementById('alert-error');
    const alertErrorMsg = document.getElementById('alert-error-msg');
    const alertSuccess = document.getElementById('alert-success');
    const alertSuccessMsg = document.getElementById('alert-success-msg');
    const delBtn = document.getElementById('del-btn');
    const rawLink = document.getElementById('raw-download-link');

    let currentToken = null;
    let rawPayloadBuffer = null;
    let timerInterval = null;

    function formatInputPin(val) {
      const clean = cleanPin(val).slice(0, 6);
      if (clean.length > 3) return clean.slice(0, 3) + ' ' + clean.slice(3);
      return clean;
    }

    input.addEventListener('input', () => {
      input.value = formatInputPin(input.value);
      hideAlerts();
    });

    function showError(msg) {
      alertErrorMsg.textContent = msg;
      alertError.classList.remove('hidden');
      alertSuccess.classList.add('hidden');
    }

    function showSuccess(msg) {
      alertSuccessMsg.textContent = msg;
      alertSuccess.classList.remove('hidden');
      alertError.classList.add('hidden');
    }

    function hideAlerts() {
      alertError.classList.add('hidden');
      alertSuccess.classList.add('hidden');
    }

    function setBusy(busy, text) {
      btn.disabled = busy;
      if (busy) {
        btnSpinner.classList.remove('hidden');
        btnText.textContent = text || 'Processing...';
      } else {
        btnSpinner.classList.add('hidden');
        btnText.textContent = text || 'Download Backup';
      }
    }

    function startCountdown(seconds) {
      if (timerInterval) clearInterval(timerInterval);
      let rem = seconds || 900;
      function tick() {
        if (rem <= 0) {
          statTimer.textContent = 'Expired';
          clearInterval(timerInterval);
          return;
        }
        const m = Math.floor(rem / 60);
        const s = rem % 60;
        statTimer.textContent = m + 'm ' + s + 's';
        rem--;
      }
      tick();
      timerInterval = setInterval(tick, 1000);
    }

    async function handleAction() {
      hideAlerts();
      const pin = cleanPin(input.value);
      if (pin.length !== 6) {
        showError('Please enter a valid 6-digit Beam code.');
        return;
      }
      const token = deriveBeamToken(pin);
      currentToken = token;

      setBusy(true, 'Finding Backup...');
      statusCard.classList.remove('hidden');
      statFilename.textContent = 'Connecting...';
      statSize.textContent = '-';

      try {
        const infoResp = await fetch('/api/beam/info/' + token);
        if (!infoResp.ok) {
          if (infoResp.status === 404) throw new Error('Beam code expired or not found. Check the code on your e-reader.');
          throw new Error('Server error checking Beam code: HTTP ' + infoResp.status);
        }
        const info = await infoResp.json();
        statSize.textContent = formatBytes(info.size);
        startCountdown(info.expires_in);
        rawLink.classList.remove('hidden');

        setBusy(true, 'Downloading...');
        progressContainer.classList.remove('hidden');
        progressFill.style.width = '0%';
        progressText.textContent = '0%';

        const dlResp = await fetch('/api/beam/download/' + token);
        if (!dlResp.ok) throw new Error('Failed to download archive: HTTP ' + dlResp.status);

        const totalBytes = info.size || parseInt(dlResp.headers.get('Content-Length') || '0', 10);
        const reader = dlResp.body.getReader();
        const chunks = [];
        let receivedBytes = 0;

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
          receivedBytes += value.length;
          if (totalBytes > 0) {
            const pct = Math.min(100, Math.floor((receivedBytes / totalBytes) * 100));
            progressFill.style.width = pct + '%';
            progressText.textContent = pct + '% (' + formatBytes(receivedBytes) + ')';
          }
        }

        const fullBuffer = new Uint8Array(receivedBytes);
        let offset = 0;
        for (const chunk of chunks) {
          fullBuffer.set(chunk, offset);
          offset += chunk.length;
        }
        rawPayloadBuffer = fullBuffer;

        setBusy(true, 'Decrypting in Browser...');
        progressText.textContent = 'Verifying integrity & decrypting...';

        await new Promise(r => setTimeout(r, 20));
        const result = decryptBeamPayload(fullBuffer, pin);

        statFilename.textContent = result.filename;
        statSize.textContent = formatBytes(result.size);
        progressFill.style.width = '100%';
        progressText.textContent = 'Decryption verified 100%';

        const blob = new Blob([result.bytes], { type: 'application/zip' });
        const blobUrl = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = blobUrl;
        a.download = result.filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(() => URL.revokeObjectURL(blobUrl), 60000);

        setBusy(false, 'Download Again');
        showSuccess('Decrypted "' + result.filename + '" and saved to Downloads!');
        delBtn.classList.remove('hidden');

      } catch (err) {
        setBusy(false, 'Download Backup');
        showError(err.message || String(err));
      }
    }

    async function handleDelete() {
      if (!currentToken) return;
      if (!confirm('Are you sure you want to delete this backup from the relay?')) return;
      try {
        await fetch('/api/beam/' + currentToken, { method: 'DELETE' });
        showSuccess('Backup removed from relay server.');
        delBtn.classList.add('hidden');
        if (timerInterval) clearInterval(timerInterval);
        statTimer.textContent = 'Deleted';
      } catch (e) {
        showError('Failed to delete: ' + (e.message || String(e)));
      }
    }

    function downloadRawPayload(e) {
      e.preventDefault();
      if (!rawPayloadBuffer || !currentToken) return;
      const blob = new Blob([rawPayloadBuffer], { type: 'application/octet-stream' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'beam_' + currentToken + '.kobeam';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
    }

    const urlParams = new URLSearchParams(window.location.search);
    const initialParam = ${JSON.stringify(safeCode)} || urlParams.get('code') || urlParams.get('pin');
    if (initialParam) {
      input.value = formatInputPin(initialParam);
      if (cleanPin(initialParam).length === 6) {
        handleAction();
      }
    }
  </script>
</body>
</html>`;
}
