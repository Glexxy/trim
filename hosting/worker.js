/**
 * trimbloat.com
 *
 * Serves the one-liner, the script, its fingerprint, and the landing page.
 *
 * Three things this exists to get right that a plain static host does not:
 *
 *   1. The script is served as text/plain, so a browser DISPLAYS it. Anyone
 *      about to pipe it into an elevated shell should be able to read it first
 *      by pasting the same URL into a browser, without a download prompt.
 *
 *   2. Strict transport security, because `irm trimbloat.com/go` without a
 *      scheme is fetched over plaintext HTTP by PowerShell. Cloudflare's
 *      Always Use HTTPS handles the redirect; HSTS stops the second visit
 *      making the request at all.
 *
 *   3. The landing page's fingerprint is read from the artefact that is
 *      actually being served, not pasted into the HTML at authoring time. A
 *      published hash that disagrees with the published script would be worse
 *      than publishing no hash at all.
 */

const CANONICAL = 'https://trimbloat.com';

/**
 * Applied to every response.
 *
 * The CSP is deliberately tight for a page whose whole argument is that you
 * should be suspicious of code you did not write: no inline script, no inline
 * event handlers, nothing executable from anywhere but this origin. Styles need
 * 'unsafe-inline' only because Google Fonts serves an @import-able stylesheet
 * and the markup carries a handful of animation-delay custom properties.
 */
function harden(headers = {}) {
  return {
    'strict-transport-security': 'max-age=31536000; includeSubDomains; preload',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'x-frame-options': 'DENY',
    'content-security-policy': [
      "default-src 'none'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      "font-src https://fonts.gstatic.com",
      "img-src 'self' data:",
      "connect-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
    ].join('; '),
    ...headers,
  };
}

async function readAsset(env, path) {
  const res = await env.ASSETS.fetch(new Request(`${CANONICAL}${path}`));
  return res.ok ? res.text() : null;
}

async function asset(env, path, contentType, cacheSeconds) {
  const body = await readAsset(env, path);
  if (body === null) return null;
  return new Response(body, {
    headers: harden({
      'content-type': contentType,
      'cache-control': `public, max-age=${cacheSeconds}`,
    }),
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // www and any other hostname collapse to one canonical origin, so there is
    // exactly one address to trust and to publish.
    if (url.hostname !== 'trimbloat.com') {
      return Response.redirect(CANONICAL + url.pathname, 301);
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: harden() });
    }

    switch (url.pathname) {
      // The one-liner target. text/plain on purpose: readable in a browser.
      case '/go':
      case '/trim.ps1': {
        // Short cache. A fix to something that runs as administrator should
        // not sit in an edge cache for a day.
        const r = await asset(env, '/trim.ps1', 'text/plain; charset=utf-8', 300);
        return r ?? new Response('Not built', { status: 503, headers: harden() });
      }

      case '/sha256':
      case '/trim.ps1.sha256': {
        const r = await asset(env, '/trim.ps1.sha256', 'text/plain; charset=utf-8', 300);
        return r ?? new Response('Not built', { status: 503, headers: harden() });
      }

      case '/config/winutil-tweaks.json': {
        const r = await asset(env, '/config/winutil-tweaks.json', 'application/json; charset=utf-8', 300);
        return r ?? new Response('Not built', { status: 503, headers: harden() });
      }

      case '/styles.css': {
        const r = await asset(env, '/styles.css', 'text/css; charset=utf-8', 3600);
        return r ?? new Response('', { status: 404, headers: harden() });
      }

      case '/app.js': {
        const r = await asset(env, '/app.js', 'text/javascript; charset=utf-8', 3600);
        return r ?? new Response('', { status: 404, headers: harden() });
      }

      case '/favicon.svg': {
        const r = await asset(env, '/favicon.svg', 'image/svg+xml', 86400);
        return r ?? new Response('', { status: 404, headers: harden() });
      }

      case '/':
        return new Response(await landing(env), {
          headers: harden({
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'public, max-age=300',
          }),
        });

      default:
        return Response.redirect(CANONICAL, 302);
    }
  },
};

/**
 * The page is a static asset with one substitution: the fingerprint, taken from
 * the sidecar of the script this deployment is serving. Authoring it as a real
 * .html file rather than a template literal is what lets it be opened, styled
 * and checked like any other page.
 */
async function landing(env) {
  const html = await readAsset(env, '/index.html');
  if (html === null) {
    return '<!doctype html><meta charset="utf-8"><title>Trim</title>'
         + '<body style="background:#070A09;color:#E9F1EE;font-family:monospace;padding:3rem">'
         + '<h1>Trim</h1><p>The site is not built. The script is still at '
         + '<a style="color:#5BE9B9" href="/go">/go</a>.</p>';
  }

  let hash = 'not published yet';
  try {
    const raw = await readAsset(env, '/trim.ps1.sha256');
    if (raw) hash = raw.trim().split(/\s+/)[0];
  } catch { /* the page is still useful without it */ }

  // The hash is 64 hex characters from our own build. Escaped anyway: a
  // substitution into HTML that is merely "known safe" is how the exceptions
  // start.
  const safe = hash.replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));

  return html.split('{{SHA256}}').join(safe);
}
