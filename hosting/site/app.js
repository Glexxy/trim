/* Copy-to-clipboard for the install command.
 *
 * A separate file rather than an inline <script> so the Content-Security-Policy
 * can be script-src 'self' with no 'unsafe-inline'. On a page whose entire
 * argument is "you should be suspicious of what you run", shipping a policy
 * that permits arbitrary inline script would be the wrong look and the wrong
 * behaviour.
 */
(function () {
  'use strict';

  function flash(button, text) {
    var original = button.textContent;
    button.textContent = text;
    button.classList.add('done');
    setTimeout(function () {
      button.textContent = original;
      button.classList.remove('done');
    }, 1400);
  }

  // Fallback for insecure contexts and older browsers, where
  // navigator.clipboard is undefined rather than merely failing.
  function legacyCopy(value) {
    var ta = document.createElement('textarea');
    ta.value = value;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  // Last resort. If neither clipboard route worked, telling someone to press
  // ctrl+c is only useful if there is something selected for them to copy, so
  // select the command itself rather than leaving them to drag across it.
  function selectText(node) {
    try {
      var range = document.createRange();
      range.selectNodeContents(node);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (e) { /* nothing sensible left to try */ }
  }

  document.querySelectorAll('.copy').forEach(function (button) {
    button.addEventListener('click', function () {
      var row = button.closest('.run-cmd');
      var code = row && row.querySelector('.cmd-text');
      if (!code) { return; }
      var value = code.textContent.trim();

      function fallback() {
        if (legacyCopy(value)) { flash(button, 'copied'); return; }
        selectText(code);
        flash(button, 'ctrl+c');
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(
          function () { flash(button, 'copied'); },
          fallback
        );
      } else {
        fallback();
      }
    });
  });
})();
