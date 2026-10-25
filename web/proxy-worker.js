// Vox proxy — Cloudflare Worker (free plan is enough).
// Forwards https://<worker>/<api-host>/<path> → https://<api-host>/<path> and adds CORS headers,
// so Gemini / OpenAI / Claude work from countries they block. WebSockets (Deepgram live) are passed through.
//
// Only the AI hosts below are allowed, so the worker cannot be used as an open proxy.
// To add a service, put its host name into the list.

const ALLOWED = [
  'generativelanguage.googleapis.com',
  'api.openai.com',
  'api.anthropic.com',
  'api.deepgram.com',
  'api.groq.com',
  'openrouter.ai',
  'api.deepseek.com',
  'api.mistral.ai',
  'api.x.ai',
  'api.together.xyz',
  'api.fireworks.ai',
  'api.cerebras.ai',
  'api.perplexity.ai',
  'api.moonshot.ai',
  'dashscope-intl.aliyuncs.com',
];

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Expose-Headers': '*',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request) {
    if (request.method === 'OPTIONS') {
      // "*" does not cover the Authorization header, so echo the requested headers back.
      const asked = request.headers.get('Access-Control-Request-Headers');
      return new Response(null, { status: 204, headers: { ...CORS, ...(asked ? { 'Access-Control-Allow-Headers': asked } : {}) } });
    }

    const url = new URL(request.url);
    const [, host, ...rest] = url.pathname.split('/');
    if (!host) return new Response('Vox proxy is running', { headers: CORS });
    if (!ALLOWED.includes(host)) return new Response(`Host not allowed: ${host}`, { status: 403, headers: CORS });

    const target = `https://${host}/${rest.join('/')}${url.search}`;

    // WebSocket upgrade (Deepgram live): hand the request over as is.
    if (request.headers.get('Upgrade') === 'websocket') {
      return fetch(target, request);
    }

    const headers = new Headers(request.headers);
    for (const h of ['origin', 'referer', 'cf-connecting-ip', 'x-forwarded-for', 'x-real-ip']) headers.delete(h);

    const upstream = await fetch(target, {
      method: request.method,
      headers,
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'follow',
    });

    const out = new Headers(upstream.headers);
    for (const [k, v] of Object.entries(CORS)) out.set(k, v);
    return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
  },
};
