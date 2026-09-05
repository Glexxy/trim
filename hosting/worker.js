/**
 * trimbloat.com
 *
 * Serves the one-liner, the script, its fingerprint, and the site.
 *
 * Four things this exists to get right that a plain static host does not:
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
 *      published hash that disagreed with the published script would be worse
 *      than publishing no hash at all.
 *
 *   4. Every asset is streamed through byte for byte. Two earlier versions got
 *      this wrong in different ways: one read images with .text() and destroyed
 *      them, and the fix for that still decoded the *script* as text - which
 *      quietly ate its UTF-8 BOM. Three bytes, and they matter twice over. The
 *      published SHA256 stopped matching the file being served, which is the
 *      exact signal the site tells people means "do not run this"; and Windows
 *      PowerShell reads a BOM-less file as ANSI, so anyone saving it to disk
 *      got a corrupted script.
 */

const CANONICAL = 'https://trimbloat.com';

/**
 * The complete set of paths this Worker will serve, and how. Anything absent
 * redirects to the front page, so a typo cannot expose an asset that was never
 * meant to be a URL.
 *
 *   file   - the asset to read
 *   type   - the Content-Type to send, chosen here rather than sniffed
 *   cache  - max-age in seconds
 */
const ROUTES = {
  // The one-liner target and the script itself. text/plain on purpose: this is
  // what makes "read it in your browser first" possible.
  // Short cache: a fix to something that runs as administrator should not sit
  // in an edge cache for a day.
  '/go':                        { file: '/trim.ps1',        type: 'text/plain; charset=utf-8',       cache: 300 },
  '/trim.ps1':                  { file: '/trim.ps1',        type: 'text/plain; charset=utf-8',       cache: 300 },
  '/sha256':                    { file: '/trim.ps1.sha256', type: 'text/plain; charset=utf-8',       cache: 300 },
  '/trim.ps1.sha256':           { file: '/trim.ps1.sha256', type: 'text/plain; charset=utf-8',       cache: 300 },
  '/config/winutil-tweaks.json':{ file: '/config/winutil-tweaks.json', type: 'application/json; charset=utf-8', cache: 300 },

  // The site.
  '/styles.css':  { file: '/styles.css',  type: 'text/css; charset=utf-8',        cache: 300 },
  '/app.js':      { file: '/app.js',      type: 'text/javascript; charset=utf-8', cache: 300 },
  '/favicon.svg': { file: '/favicon.svg', type: 'image/svg+xml',                  cache: 86400 },

  // Crawlers.
  '/robots.txt':  { file: '/robots.txt',  type: 'text/plain; charset=utf-8', cache: 3600 },
  '/sitemap.xml': { file: '/sitemap.xml', type: 'application/xml; charset=utf-8', cache: 3600 },
  '/llms.txt':    { file: '/llms.txt',    type: 'text/plain; charset=utf-8', cache: 3600 },

  // Images. The long cache comes from the ?v= on the URL, not from here; these
  // values are the floor for anyone who requests the bare path.
  '/img/og.png':          { file: '/img/og.png',          type: 'image/png',  cache: 86400 },
  '/img/icon-180.png':    { file: '/img/icon-180.png',    type: 'image/png',  cache: 604800 },
  '/img/overview.webp':   { file: '/img/overview.webp',   type: 'image/webp', cache: 604800 },
  '/img/overview@2x.webp':{ file: '/img/overview@2x.webp',type: 'image/webp', cache: 604800 },
  '/img/changes.webp':    { file: '/img/changes.webp',    type: 'image/webp', cache: 604800 },
  '/img/changes@2x.webp': { file: '/img/changes@2x.webp', type: 'image/webp', cache: 604800 },
  '/img/cleanup.webp':    { file: '/img/cleanup.webp',    type: 'image/webp', cache: 604800 },
  '/img/cleanup@2x.webp': { file: '/img/cleanup@2x.webp', type: 'image/webp', cache: 604800 },
  '/img/startup.webp':    { file: '/img/startup.webp',    type: 'image/webp', cache: 604800 },
  '/img/startup@2x.webp': { file: '/img/startup@2x.webp', type: 'image/webp', cache: 604800 },
  '/img/uninstall.webp':  { file: '/img/uninstall.webp',  type: 'image/webp', cache: 604800 },
  '/img/uninstall@2x.webp':{ file: '/img/uninstall@2x.webp',type: 'image/webp', cache: 604800 },
};

/**
 * Applied to every response.
 *
 * The CSP is deliberately tight for a page whose whole argument is that you
 * should be suspicious of code you did not write: no inline script, no inline
 * event handlers, nothing executable from anywhere but this origin. Styles need
 * 'unsafe-inline' only because Google Fonts serves an @import-able stylesheet
 * and a few elements carry animation-delay custom properties.
 */
function harden(headers = {}) {
  return {
    'strict-transport-security': 'max-age=31536000; includeSubDomains; preload',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'strict-origin-when-cross-origin',
    'x-frame-options': 'DENY',
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-resource-policy': 'same-origin',
    // Nothing here needs a camera, a location or a payment sheet. Saying so
    // costs one header and removes the question.
    'permissions-policy':
      'accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=(), interest-cohort=()',
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
      "object-src 'none'",
      "upgrade-insecure-requests",
    ].join('; '),
    ...headers,
  };
}

function fetchAsset(env, path) {
  return env.ASSETS.fetch(new Request(`${CANONICAL}${path}`));
}

async function readText(env, path) {
  const res = await fetchAsset(env, path);
  return res.ok ? res.text() : null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Plaintext is refused before anything else happens.
    //
    // `irm trimbloat.com/go | iex` with no scheme is fetched over http, and the
    // thing being fetched is a script the user is about to run as
    // administrator. Served in the clear, anyone on the path - café wifi, a
    // compromised router, an ISP - can replace it with their own and it will be
    // executed with full rights.
    //
    // HSTS does not cover this: it only protects the *second* visit, and the
    // first one is the one that matters. This used to rely on the zone's
    // "Always Use HTTPS" setting, which was never switched on - so it lived in
    // a comment rather than in the code. Now it is enforced here, where it is
    // in version control and can be tested.
    if (url.protocol !== 'https:') {
      url.protocol = 'https:';
      return Response.redirect(url.toString(), 301);
    }

    // www and any other hostname collapse to one canonical origin, so there is
    // exactly one address to trust and to publish.
    if (url.hostname !== 'trimbloat.com') {
      return Response.redirect(CANONICAL + url.pathname, 301);
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', {
        status: 405,
        headers: harden({ 'allow': 'GET, HEAD' }),
      });
    }

    if (url.pathname === '/') {
      return new Response(await landing(env), {
        headers: harden({
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'public, max-age=300',
        }),
      });
    }

    const route = ROUTES[url.pathname];
    if (!route) { return Response.redirect(CANONICAL, 302); }

    const res = await fetchAsset(env, route.file);
    if (!res.ok) {
      return new Response('Not built', { status: 503, headers: harden() });
    }

    // Streamed, never decoded. Reading an asset as text and re-encoding it is
    // not a no-op: it strips a byte order mark and re-encodes anything the
    // decoder normalises. The only thing that gets read as text here is the
    // landing page, which has to be, because a token is substituted into it.
    const body = res.body;

    // A request carrying ?v= is for one specific build of that asset, so it can
    // be cached forever. Without the version it has to stay revalidatable - the
    // filename alone does not tell a browser whether its copy is still current,
    // and serving a stale stylesheet against fresh HTML is a broken page.
    const versioned = url.searchParams.has('v');
    const cacheControl = versioned
      ? 'public, max-age=31536000, immutable'
      : `public, max-age=${route.cache}`;

    return new Response(body, {
      headers: harden({
        'content-type': route.type,
        'cache-control': cacheControl,
      }),
    });
  },
};

/**
 * The page is a static asset with one substitution: the fingerprint, taken from
 * the sidecar of the script this deployment is serving. Authoring it as a real
 * .html file rather than a template literal is what lets it be opened, styled
 * and checked like any other page.
 */
async function landing(env) {
  const html = await readText(env, '/index.html');
  if (html === null) {
    return '<!doctype html><meta charset="utf-8"><title>Trim</title>'
         + '<body style="background:#080B0C;color:#ECF2F0;font-family:monospace;padding:3rem">'
         + '<h1>Trim</h1><p>The site is not built. The script is still at '
         + '<a style="color:#4FE0B0" href="/go">/go</a>.</p>';
  }

  let hash = 'not published yet';
  try {
    const raw = await readText(env, '/trim.ps1.sha256');
    if (raw) hash = raw.trim().split(/\s+/)[0];
  } catch { /* the page is still useful without it */ }

  // The hash is 64 hex characters from our own build. Escaped anyway: a
  // substitution into HTML that is merely "known safe" is how the exceptions
  // start.
  const safe = hash.replace(/[&<>"']/g, (ch) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]
  ));

  // {{V}} - the asset cache-busting version - is substituted at publish time
  // from a hash of the asset bytes, not here: the Worker cannot see whether the
  // stylesheet changed, and a version derived from anything else goes stale
  // exactly when it matters. This fallback only fires when the page is served
  // straight from source, which is local development.
  return html
    .split('{{SHA256}}').join(safe)
    .split('{{V}}').join('dev');
}
