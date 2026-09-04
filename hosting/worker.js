/**
 * trimbloat.com
 *
 * Serves the one-liner, the script, and its fingerprint.
 *
 * Two things this exists to get right that a plain static host does not:
 *
 *   1. The script is served as text/plain, so a browser DISPLAYS it. Anyone
 *      about to pipe it into an elevated shell should be able to read it first
 *      by pasting the same URL into a browser, without a download prompt.
 *
 *   2. Strict transport security, because `irm trimbloat.com/go` without a
 *      scheme is fetched over plaintext HTTP by PowerShell. Cloudflare's
 *      Always Use HTTPS handles the redirect; HSTS stops the second visit
 *      making the request at all.
 */

const CANONICAL = 'https://trimbloat.com';

/** Applied to every response. */
function harden(headers = {}) {
  return {
    'strict-transport-security': 'max-age=31536000; includeSubDomains; preload',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'x-frame-options': 'DENY',
    ...headers,
  };
}

async function asset(env, path, contentType, cacheSeconds) {
  const res = await env.ASSETS.fetch(new Request(`${CANONICAL}${path}`));
  if (!res.ok) return null;
  const body = await res.text();
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

      case '/':
        return new Response(await landing(env), {
          headers: harden({ 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=300' }),
        });

      default:
        return Response.redirect(CANONICAL, 302);
    }
  },
};

async function landing(env) {
  let hash = 'not published yet';
  try {
    const r = await env.ASSETS.fetch(new Request(`${CANONICAL}/trim.ps1.sha256`));
    if (r.ok) hash = (await r.text()).trim().split(/\s+/)[0];
  } catch { /* the page still works without it */ }

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Trim</title>
<meta name="description" content="Reversible Windows tuning. Removes advertising, telemetry and preinstalled clutter, and tunes what is left for games.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700;800&display=swap">
<style>
  :root{
    --bg:#0E1312; --panel:#151B1A; --raise:#1E2524; --rule:#262F2D;
    --ink:#E4EBE9; --soft:#A8B5B2; --faint:#798683; --accent:#46C6B0;
    color-scheme:dark;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
    font-family:Archivo,system-ui,-apple-system,sans-serif;line-height:1.6;
    -webkit-font-smoothing:antialiased}
  .wrap{max-width:760px;margin:0 auto;padding:clamp(2.5rem,8vw,5rem) 1.25rem 5rem}
  header{display:flex;align-items:center;gap:.9rem;margin-bottom:2.5rem}
  .mark{width:34px;height:34px;flex:none}
  h1{font-size:clamp(2.1rem,6vw,2.9rem);font-weight:800;letter-spacing:-.035em;margin:0;line-height:1}
  .tag{color:var(--soft);font-size:1.05rem;margin:.9rem 0 0;max-width:52ch}
  h2{font-size:1rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;
    color:var(--faint);margin:3rem 0 .9rem}
  p{color:var(--soft);max-width:62ch}
  code,pre{font-family:"Cascadia Mono",Consolas,ui-monospace,monospace}
  pre{background:var(--panel);border:1px solid var(--rule);border-radius:6px;
    padding:1rem 1.15rem;overflow-x:auto;font-size:.92rem;color:var(--ink);margin:0}
  .cmd{border-left:3px solid var(--accent)}
  .note{color:var(--faint);font-size:.86rem;margin-top:.6rem}
  .hash{background:var(--panel);border:1px solid var(--rule);border-radius:6px;
    padding:.85rem 1.05rem;font-family:"Cascadia Mono",Consolas,monospace;
    font-size:.78rem;word-break:break-all;color:var(--soft)}
  ul{color:var(--soft);max-width:62ch;padding-left:1.15rem}
  li{margin-bottom:.45rem}
  li::marker{color:var(--accent)}
  a{color:var(--accent)}
  footer{margin-top:4rem;padding-top:1.5rem;border-top:1px solid var(--rule);
    color:var(--faint);font-size:.82rem}
  strong{color:var(--ink);font-weight:600}
</style>
</head><body><div class="wrap">

<header>
  <svg class="mark" viewBox="0 0 26 26" aria-hidden="true">
    <rect x="1" y="3" width="24" height="4.5" rx="2.25" fill="#46C6B0"/>
    <rect x="1" y="10.5" width="16" height="4.5" rx="2.25" fill="#46C6B0" opacity=".72"/>
    <rect x="1" y="18" width="9" height="4.5" rx="2.25" fill="#46C6B0" opacity=".45"/>
  </svg>
  <h1>Trim</h1>
</header>

<p class="tag">Removes advertising, telemetry and preinstalled clutter from Windows,
and tunes what is left for games. Every change is written down first and can be undone.</p>

<h2>Run it</h2>
<pre class="cmd">irm https://trimbloat.com/go | iex</pre>
<p class="note">Windows 10 and 11. It will ask for administrator rights, because it needs them.
Nothing is changed until you press Apply.</p>

<h2>Read it first</h2>
<p>You are about to pipe a script into an elevated shell. That deserves scepticism, including
of this page. <a href="/go">Open the script in your browser</a> &mdash; it is served as plain
text so you can read every line before running it.</p>

<h2>Verify it</h2>
<pre>irm https://trimbloat.com/go -OutFile trim.ps1
Get-FileHash .\trim.ps1 -Algorithm SHA256
.\trim.ps1 -Version</pre>
<p class="note">The published fingerprint of the current build:</p>
<div class="hash">${hash}</div>
<p class="note">Also at <a href="/sha256">trimbloat.com/sha256</a>.
If what you downloaded does not match, do not run it.</p>

<h2>What it does</h2>
<ul>
  <li><strong>Shows you everything first.</strong> Every row names the setting, what it is now,
      and what it would become.</li>
  <li><strong>Takes a restore point</strong> before it touches anything, and writes down every
      change so it can hand you a script that puts them all back.</li>
  <li><strong>Labels every change</strong> Safe, Caution or Risky. Only Safe is ticked by default.</li>
  <li><strong>Skips what does not apply.</strong> Laptop, desktop, NVIDIA, AMD, Intel, SSD or
      hard disk &mdash; it checks before it writes.</li>
  <li><strong>Cleans up and uninstalls properly</strong>, in their own screens, never as part of
      a preset.</li>
</ul>

<h2>The honest part</h2>
<p><code>irm | iex</code> runs whatever this host returns, as administrator. If this host were
compromised you would run the attacker's code. That is true of every tool distributed this way.
It is why the fingerprint above exists, and why the script is readable in your browser.</p>

<footer>
  Debloat and tweak engine: <a href="https://christitus.com/win">WinUtil by Chris Titus Tech</a>.
  Trim orchestrates it, it does not replace it.
</footer>

</div></body></html>`;
}
