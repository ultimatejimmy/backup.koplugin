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

    // Health check
    if (path === '/' || path === '/health') {
      return new Response(JSON.stringify({
        status: 'ok',
        service: 'koreader-beam-relay',
        version: '2.3',
        kv_bound: !!env.BEAM_KV,
        mode: 'native_expiration_single_write',
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
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
      const body = await request.arrayBuffer();
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
