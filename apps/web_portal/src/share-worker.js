const assets = new Map([
  ['/share/', '/index.html'],
  ['/share/share.js', '/share.js'],
  ['/share/share.css', '/share.css'],
]);

export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response(null, { status: 405, headers: { allow: 'GET, HEAD' } });
    }
    const url = new URL(request.url);
    const asset = assets.get(url.pathname);
    if (!asset) return new Response('Not found', { status: 404 });
    url.pathname = asset;
    url.search = '';
    const response = await env.ASSETS.fetch(new Request(url, request));
    const headers = new Headers(response.headers);
    headers.set('referrer-policy', 'no-referrer');
    headers.set('cache-control', 'no-store');
    headers.set('x-content-type-options', 'nosniff');
    headers.set('content-security-policy', "default-src 'self'; base-uri 'none'; frame-ancestors 'none'");
    return new Response(request.method === 'HEAD' ? null : response.body, {
      status: response.status,
      headers,
    });
  },
};
