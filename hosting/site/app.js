/* trimbloat.com
 *
 * A separate file rather than an inline <script> so the Content-Security-Policy
 * can be script-src 'self' with no 'unsafe-inline'. On a page whose whole
 * argument is "be suspicious of code you did not write", shipping a policy that
 * permits arbitrary inline script would be the wrong look and the wrong
 * behaviour.
 *
 * Everything here is progressive: with JavaScript off you still get the full
 * page, all four screenshots (the tab panels are only hidden by script), the
 * FAQ (native <details>), and a command you can select and copy by hand.
 */
(function () {
  'use strict';

  var reduced = window.matchMedia &&
                window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---- copy the install command ----------------------------------------- */

  function flash(button, text) {
    var original = button.getAttribute('data-label') || button.textContent;
    button.setAttribute('data-label', original);
    button.textContent = text;
    button.classList.add('done');
    window.setTimeout(function () {
      button.textContent = original;
      button.classList.remove('done');
    }, 1500);
  }

  // navigator.clipboard is undefined outside a secure context, so this is a
  // fallback rather than an error path.
  function legacyCopy(value) {
    var ta = document.createElement('textarea');
    ta.value = value;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  // If neither route works, select the command so that telling somebody to
  // press ctrl+c is actually actionable.
  function selectText(node) {
    try {
      var range = document.createRange();
      range.selectNodeContents(node);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (e) { /* nothing sensible left to try */ }
  }

  Array.prototype.forEach.call(document.querySelectorAll('.cmd-copy'), function (button) {
    button.addEventListener('click', function () {
      var row = button.closest('.cmd');
      var code = row && row.querySelector('.cmd-text');
      if (!code) { return; }
      var value = code.textContent.trim();

      function fallback() {
        if (legacyCopy(value)) { flash(button, 'Copied'); return; }
        selectText(code);
        flash(button, 'Ctrl+C');
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(function () {
          flash(button, 'Copied');
        }, fallback);
      } else {
        fallback();
      }
    });
  });

  /* ---- screenshot tabs --------------------------------------------------- */

  var tablist = document.querySelector('[role="tablist"]');
  if (tablist) {
    var tabs = Array.prototype.slice.call(tablist.querySelectorAll('[role="tab"]'));

    function panelFor(tab) {
      return document.getElementById(tab.getAttribute('aria-controls'));
    }

    function select(tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute('aria-selected', on ? 'true' : 'false');
        // Roving tabindex: the strip is one tab stop, arrows move within it.
        t.setAttribute('tabindex', on ? '0' : '-1');
        var panel = panelFor(t);
        if (panel) { panel.hidden = !on; }
      });
      if (focus) { tab.focus(); }
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener('click', function () { select(tab); });

      tab.addEventListener('keydown', function (e) {
        var next = null;
        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { next = tabs[(i + 1) % tabs.length]; }
        else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { next = tabs[(i - 1 + tabs.length) % tabs.length]; }
        else if (e.key === 'Home') { next = tabs[0]; }
        else if (e.key === 'End') { next = tabs[tabs.length - 1]; }
        if (next) { e.preventDefault(); select(next, true); }
      });
    });

    // The markup already marks three panels hidden, so the page never paints
    // four full-width screenshots and then collapses to one. This re-asserts it
    // from the selected tab rather than assuming the first one. The no-JS case
    // is handled by a <noscript> style block that reveals them all.
    tabs.forEach(function (t, i) {
      var panel = panelFor(t);
      if (panel) { panel.hidden = i !== 0; }
    });

    // Warm the screenshots the tabs will need.
    //
    // Those images are loading="lazy" inside panels this script has just set to
    // hidden, and a browser will not fetch an image in a display:none subtree.
    // Without this, clicking a tab shows an empty frame while the image is
    // fetched for the first time. Fetching them once the page is otherwise idle
    // keeps the initial load light and makes every switch instant.
    var warm = function () {
      tabs.slice(1).forEach(function (t) {
        var panel = panelFor(t);
        var img = panel && panel.querySelector('img');
        if (!img || img.dataset.warmed) { return; }
        img.dataset.warmed = '1';
        var pre = new Image();
        if (img.getAttribute('sizes')) { pre.sizes = img.getAttribute('sizes'); }
        if (img.getAttribute('srcset')) { pre.srcset = img.getAttribute('srcset'); }
        pre.src = img.getAttribute('src');
      });
    };

    if ('requestIdleCallback' in window) {
      window.requestIdleCallback(warm, { timeout: 2500 });
    } else {
      window.setTimeout(warm, 1200);
    }

    // Whatever happens, a tab the pointer is heading for gets its image early.
    tablist.addEventListener('pointerenter', warm, { once: true });
    tablist.addEventListener('focusin', warm, { once: true });
  }

  /* ---- scroll reveals ---------------------------------------------------- */

  if (!reduced && 'IntersectionObserver' in window) {
    var targets = document.querySelectorAll(
      '.band-head, .job, .tourbox, .stepgrid li, .check, .never, .undo-grid > *, .faqlist, .closer > *'
    );

    Array.prototype.forEach.call(targets, function (el) { el.classList.add('reveal'); });

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) { return; }
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    // Stagger within a group so a row of cards arrives in sequence rather than
    // as one block. Capped so a long list never introduces a visible wait.
    var groups = document.querySelectorAll('.jobs, .stepgrid, .checks, .undo-grid');
    Array.prototype.forEach.call(groups, function (group) {
      Array.prototype.forEach.call(group.children, function (child, i) {
        if (child.classList.contains('reveal')) {
          child.style.setProperty('--d', Math.min(i, 4) * 70 + 'ms');
        }
      });
    });

    Array.prototype.forEach.call(targets, function (el) { io.observe(el); });
  }

  /* ---- sticky bar hairline ----------------------------------------------- */

  var bar = document.querySelector('.topbar');
  if (bar) {
    var ticking = false;
    var onScroll = function () {
      if (ticking) { return; }
      ticking = true;
      window.requestAnimationFrame(function () {
        bar.classList.toggle('stuck', window.scrollY > 8);
        ticking = false;
      });
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }
})();
