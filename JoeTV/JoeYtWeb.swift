import SwiftUI

// MARK: - YouTube web surfaces (player + Gold sign-in door)
//
// The Swift half of the WebKit bridge (design plan §2/§3).
// JoeWebBridge (ObjC) is mechanics only; everything that
// decides WHAT happens — the watchmax payload (carried over
// VERBATIM from the Sony proof, §2.3), the AUTO surface chain
// (§2.4), the remote model (§2.5), the cookie mirror and the
// SAPISID presence rule (§3.3) — lives in this file.
//
// Secret-handling (design §3.4, hard rules): cookie VALUES
// are never written to the diagnostic log, never shown in
// UI, never sent anywhere except back into the app's own
// cookie store. The log records signedIn=true/false, counts
// and event names only.

// MARK: JS payloads

enum JoeYtJS {
    /// Desktop user agent (Sony PlayerActivity DESKTOP_UA,
    /// PROVEN-SONY — design §2.3, verbatim).
    static let desktopUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// The SIGN-IN DOOR's user agent — a desktop SAFARI UA,
    /// deliberately different from the player's (community
    /// research 2026-11-19, phonk-jazz measured against the
    /// live site): Google refuses sign-in inside a web view
    /// whose UA betrays it ("this browser or app may not be
    /// secure") — the default WKWebView UA carries the app
    /// name and lacks Version/, and a Chrome/Windows UA on a
    /// WebKit engine is exactly the mismatched identity the
    /// check is built to catch. WKWebView IS Safari's engine,
    /// so the Safari UA is the honest, accepted one. Cookies
    /// live in the shared data store, not the UA, so the
    /// door's session carries into the player untouched.
    /// applicationNameForUserAgent is never set anywhere.
    static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    /// The watchmax CSS injection (Sony PlayerActivity poll,
    /// style id tvbyt-max-css, PROVEN-SONY — design §2.3,
    /// verbatim). ⛔ #page-manager must NEVER enter the
    /// hide-list: it is an ANCESTOR of #movie_player and
    /// hiding it paints the player black while the state
    /// keeps playing (Sony v0.3 defect, caps v03-09/10).
    static let injectWatchmaxCSS = """
        (function(){
          if (document.getElementById('tvbyt-max-css')) { return 'already'; }
          var s = document.createElement('style');
          s.id = 'tvbyt-max-css';
          s.textContent = 'html,body{overflow:hidden!important;background:#000!important}'
            + '#movie_player{position:fixed!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;background:#000!important}'
            + '#masthead-container,#secondary,#below,#comments,#related,#footer{display:none!important}';
          document.head.appendChild(s);
          window.dispatchEvent(new Event('resize'));
          return 'injected';
        })()
        """

    /// State poll (design §2.3): one small JS read every 2 s.
    /// TRUST ORDER (community research 2026-11-19, phonk-jazz
    /// measured live): the #movie_player API is AUTHORITATIVE
    /// — the <video> element's readings can be indefinitely
    /// wrong in the MSE stall state (duration NaN, currentTime
    /// 0 while playback is fine). So state/position/duration
    /// come from getPlayerState()/getCurrentTime()/
    /// getDuration()/getVideoData() first; the element is the
    /// fallback and corroboration only. Also carried: the
    /// player pin check (the #movie_player rect against the
    /// viewport — the VEIL's release signal, Sony lesson 2),
    /// any .ytp-error text, and the page URL (the §2.5 wander
    /// check).
    static let poll = """
        (function(){
          var v = document.querySelector('video');
          var p = document.getElementById('movie_player');
          var err = '';
          var e = document.querySelector('.ytp-error');
          if (e) { err = (e.innerText || '').slice(0, 120); }
          var pin = 0;
          if (p) {
            var r = p.getBoundingClientRect();
            if (Math.abs(r.width - window.innerWidth) < 2
                && Math.abs(r.height - window.innerHeight) < 2) { pin = 1; }
          }
          var state = -99, vid = '', t = 0, d = 0, api = 0;
          try {
            if (p && p.getPlayerState) {
              api = 1;
              state = p.getPlayerState();
              if (p.getCurrentTime) { t = p.getCurrentTime() || 0; }
              if (p.getDuration) { d = p.getDuration() || 0; }
              if (p.getVideoData) {
                var vd = p.getVideoData();
                vid = (vd && (vd.video_id || vd.videoId)) || '';
              }
            }
          } catch (ex) { api = 0; state = -99; }
          if (v) {
            if (!(d > 0) && isFinite(v.duration)) { d = v.duration; }
            if (!t && isFinite(v.currentTime)) { t = v.currentTime; }
          }
          var playing, ended, paused;
          if (api) {
            playing = (state === 1);
            ended = (state === 0);
            paused = (state === 2);
          } else {
            playing = !!(v && !v.paused && !v.ended && v.readyState > 2);
            ended = !!(v && v.ended);
            paused = !!(v && v.paused);
          }
          return JSON.stringify({
            has: !!v, api: api, state: state, vid: vid,
            playing: playing, paused: paused, ended: ended,
            muted: !!(v && v.muted),
            t: t, d: d,
            pin: pin, err: err, url: location.href
          });
        })()
        """

    /// Play/pause toggle — through the PLAYER object first
    /// (research 2026-11-19: element state can lie during MSE
    /// playback); the element is the fallback.
    static let togglePlay = """
        (function(){
          var p = document.getElementById('movie_player');
          try {
            if (p && p.getPlayerState) {
              if (p.getPlayerState() === 1) { p.pauseVideo(); return 'pause'; }
              p.playVideo(); return 'play';
            }
          } catch (ex) {}
          var v = document.querySelector('video');
          if (!v) { return 'novideo'; }
          if (v.paused) { v.play(); return 'play'; }
          v.pause(); return 'pause';
        })()
        """

    /// Seek — used ONLY by the web-process-death recovery
    /// (research 2026-11-19): after a termination reload, the
    /// player seeks back to the poll-checkpointed position.
    /// Through seekTo: assigning video.currentTime can
    /// silently no-op in the MSE state. (User-facing seek
    /// stays out of scope by the owner's ruling.)
    static func seekTo(_ seconds: Double) -> String {
        """
        (function(){
          var p = document.getElementById('movie_player');
          try {
            if (p && p.seekTo) { p.seekTo(\(seconds), true); return 'api'; }
          } catch (ex) {}
          var v = document.querySelector('video');
          if (v) { v.currentTime = \(seconds); return 'element'; }
          return 'none';
        })()
        """
    }

    /// Startup nudge (Sony poll shape): unmute + play while a
    /// surface has not reached its first playing frame yet.
    /// NEVER evaluated after first play — after that, a pause
    /// is the owner's own and is respected.
    static let nudgePlay = """
        (function(){
          var v = document.querySelector('video');
          if (!v) { return 'novideo'; }
          if (v.muted) { v.muted = false; }
          if (v.paused) { v.play(); }
          return 'nudged';
        })()
        """

    // MARK: Door payloads (design §3.2 + research 2026-11-19)
    //
    // A bridged tvOS web view has NO native text entry (the
    // flagship's hand-built keyboard exists for exactly this
    // reason). The door's mechanism instead: the owner types
    // into NATIVE SwiftUI fields (the tvOS system keyboard),
    // and these payloads type the values into Google's page
    // fields — the prototype value setter plus dispatched
    // input/change events, the shape the page's own framework
    // observes. The values travel inside the evaluated script
    // only; they are never logged (no evaluate payload is).

    /// Which step the door page is on: 'email' |
    /// 'password' | 'challenge' | 'none'. v2.0.42: the
    /// 'challenge' step (Probe 4's D-2, device-proven) —
    /// a visible "Try another way" control with no
    /// credential field up IS the passkey / verification
    /// challenge shape.
    static let doorProbe = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var pw = document.querySelector('input[name="Passwd"], input[type="password"]');
          if (vis(pw)) { return 'password'; }
          var idn = document.querySelector('input[name="identifier"], input[type="email"]');
          if (vis(idn)) { return 'email'; }
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if ((t === 'try another way' || t === 'thử cách khác') && vis(cands[i])) {
              return 'challenge';
            }
          }
          return 'none';
        })()
        """

    /// Capability masking (Probe 4, device-proven 3×):
    /// installed at document start in the DOOR's web view
    /// only, so Google feature-detects NO WebAuthn
    /// support and stays on the password path — the
    /// re-signed build cannot hold the Associated Domains
    /// entitlement a passkey ceremony needs (FL-031).
    /// Removes the WebAuthn globals; everything else on
    /// the page is untouched.
    static let doorMasking = """
        (function(){
          try { delete window.PublicKeyCredential; } catch (e) {}
          try {
            Object.defineProperty(window, 'PublicKeyCredential',
              { value: undefined, configurable: true });
          } catch (e) {}
          if (navigator.credentials) {
            try {
              var reject = function() {
                return Promise.reject(new DOMException('masked', 'NotAllowedError'));
              };
              Object.defineProperty(navigator, 'credentials', {
                value: { get: reject, create: reject },
                configurable: true
              });
            } catch (e) {}
          }
          window.__joeMasked = true;
        })()
        """

    /// JS-click the page's "Try another way" control
    /// (Probe 4's D-3 — the steer around the passkey
    /// wall; the click does not depend on page focus,
    /// FL-067). Returns 'clicked' or 'notfound'.
    static let clickTryAnotherWay = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if ((t === 'try another way' || t === 'thử cách khác') && vis(cands[i])) {
              cands[i].click();
              return 'clicked';
            }
          }
          return 'notfound';
        })()
        """

    /// After "Try another way", Google lists sign-in
    /// methods; click the password one so the door lands
    /// back on the password step. Text-matched, fail-soft.
    /// (Probe 4's legacy leg — silenced once a chooser
    /// inventory has been captured.)
    static let clickPasswordMethod = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var wanted = ['use your password', 'enter your password',
                        'dùng mật khẩu', 'sử dụng mật khẩu', 'nhập mật khẩu'];
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"], li, div');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if (t.length > 60) { continue; }
            for (var j = 0; j < wanted.length; j++) {
              if (t === wanted[j] && vis(cands[i])) {
                cands[i].click();
                return 'clicked';
              }
            }
          }
          return 'notfound';
        })()
        """

    /// The challenge page's candidate-control inventory —
    /// VALUES-FREE by construction: input TYPES and the
    /// visible label text of clickable controls only
    /// (never an input's value). Logged when the
    /// challenge step appears, so a future page-shape
    /// change is diagnosable from one log (Probe 4's
    /// audit requirement).
    static let doorDomInventory = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var out = [];
          var inputs = document.querySelectorAll('input');
          for (var i = 0; i < inputs.length && out.length < 40; i++) {
            if (vis(inputs[i])) {
              out.push('input[type=' + (inputs[i].type || '?')
                + ',name=' + (inputs[i].name || '?') + ']');
            }
          }
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"], li');
          for (var j = 0; j < cands.length && out.length < 40; j++) {
            var t = (cands[j].innerText || cands[j].textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 60);
            if (t && vis(cands[j])) {
              out.push(cands[j].tagName.toLowerCase() + ':' + t);
            }
          }
          return JSON.stringify(out);
        })()
        """

    // MARK: 2SV chooser payloads (Probe 4, click v2)
    //
    // After 'Try another way', the account's chooser has
    // NO password row (device-proven 2026-11-20) — it
    // lists Tap Yes / authenticator / SMS. These payloads
    // inventory the rows, click one by visible text,
    // classify the follow-up step, and fill a
    // verification code. Page VALUES are never returned:
    // the code goes in one-way, and only its length is
    // logged (Swift side).
    //
    // Click v2: a bare .click() lands on the shortest
    // text-matching element — the text shell, not the
    // node Google's handler listens on (the 0.1.3 device
    // run logged 'clicked' on every row yet the page
    // never moved). V2 walks UP from the match to the
    // first ancestor carrying jsaction / role link|button
    // / a data-challengeid|data-method|data-value
    // attribute (an A or BUTTON qualifies too), then
    // fires a full press sequence (pointerdown → mousedown
    // → pointerup → mouseup → click) at the target's
    // centre. The payload reports the chosen target
    // values-free (tag, role, jsaction presence,
    // qualifier) as JSON.

    /// FRESH inventory of the clickable rows only: visible
    /// text, whitespace-collapsed, deduplicated, capped.
    /// No values — labels are public page UI.
    static let chooserRows = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var out = [];
          var seen = {};
          var cands = document.querySelectorAll('a, button, [role="button"], [role="link"], [role="listitem"], li');
          for (var i = 0; i < cands.length && out.length < 30; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (t && t.length <= 120 && vis(cands[i]) && !seen[t]) {
              seen[t] = 1;
              out.push(t);
            }
          }
          return JSON.stringify(out);
        })()
        """

    /// Click v2 (see the section note). Returns a
    /// values-free JSON report:
    /// {"outcome":"clicked","tag":…,"role":…,
    ///  "jsaction":…,"qual":…} / {"outcome":"notfound"}.
    static func clickChooserRow(needle: String, avoid: String) -> String {
        """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var needle = \(jsLiteral(needle)).toLowerCase();
          var avoid = \(jsLiteral(avoid)).toLowerCase();
          var cands = document.querySelectorAll('a, button, [role="button"], [role="link"], [role="listitem"], li, div');
          var best = null;
          var bestLen = 100000;
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (!t || t.length > 300) { continue; }
            var low = t.toLowerCase();
            if (low.indexOf(needle) < 0) { continue; }
            if (avoid && low.indexOf(avoid) >= 0) { continue; }
            if (!vis(cands[i])) { continue; }
            if (t.length < bestLen) { best = cands[i]; bestLen = t.length; }
          }
          if (!best) { return JSON.stringify({outcome: 'notfound'}); }
          function qualifier(el) {
            if (el.hasAttribute && el.hasAttribute('jsaction')) { return 'jsaction'; }
            var role = el.getAttribute ? (el.getAttribute('role') || '') : '';
            if (role === 'link' || role === 'button') { return 'role'; }
            if (el.hasAttribute && (el.hasAttribute('data-challengeid')
                || el.hasAttribute('data-method')
                || el.hasAttribute('data-value'))) { return 'data'; }
            if (el.tagName === 'A' || el.tagName === 'BUTTON') { return 'tag'; }
            return '';
          }
          var target = null;
          var qual = '';
          var el = best;
          for (var level = 0; el && level <= 6; level++) {
            var q = qualifier(el);
            if (q) { target = el; qual = q; break; }
            el = el.parentElement;
          }
          if (!target) { target = best; qual = 'self'; }
          target.scrollIntoView({block: 'center'});
          var rect = target.getBoundingClientRect();
          var cx = rect.left + rect.width / 2;
          var cy = rect.top + rect.height / 2;
          function fire(type) {
            var Ctor = (type.indexOf('pointer') === 0 && window.PointerEvent)
              ? window.PointerEvent : window.MouseEvent;
            target.dispatchEvent(new Ctor(type,
              {bubbles: true, cancelable: true, clientX: cx, clientY: cy}));
          }
          fire('pointerdown');
          fire('mousedown');
          fire('pointerup');
          fire('mouseup');
          fire('click');
          var role = target.getAttribute ? (target.getAttribute('role') || '-') : '-';
          return JSON.stringify({outcome: 'clicked',
            tag: target.tagName || '?', role: role,
            jsaction: !!(target.hasAttribute && target.hasAttribute('jsaction')),
            qual: qual});
        })()
        """
    }

    /// Retry leg for click v2: re-locate the row (same
    /// matching), then fire the same full press sequence
    /// on the row's FIRST interactive descendant.
    /// Outcomes: 'clicked' / 'nodesc' / 'norow'.
    static func clickChooserRowRetry(needle: String, avoid: String) -> String {
        """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var needle = \(jsLiteral(needle)).toLowerCase();
          var avoid = \(jsLiteral(avoid)).toLowerCase();
          var cands = document.querySelectorAll('a, button, [role="button"], [role="link"], [role="listitem"], li, div');
          var best = null;
          var bestLen = 100000;
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (!t || t.length > 300) { continue; }
            var low = t.toLowerCase();
            if (low.indexOf(needle) < 0) { continue; }
            if (avoid && low.indexOf(avoid) >= 0) { continue; }
            if (!vis(cands[i])) { continue; }
            if (t.length < bestLen) { best = cands[i]; bestLen = t.length; }
          }
          if (!best) { return JSON.stringify({outcome: 'norow'}); }
          var desc = best.querySelectorAll('a, button, [role="link"], [role="button"]');
          if (!desc.length) { return JSON.stringify({outcome: 'nodesc'}); }
          var target = desc[0];
          target.scrollIntoView({block: 'center'});
          var rect = target.getBoundingClientRect();
          var cx = rect.left + rect.width / 2;
          var cy = rect.top + rect.height / 2;
          function fire(type) {
            var Ctor = (type.indexOf('pointer') === 0 && window.PointerEvent)
              ? window.PointerEvent : window.MouseEvent;
            target.dispatchEvent(new Ctor(type,
              {bubbles: true, cancelable: true, clientX: cx, clientY: cy}));
          }
          fire('pointerdown');
          fire('mousedown');
          fire('pointerup');
          fire('mouseup');
          fire('click');
          var role = target.getAttribute ? (target.getAttribute('role') || '-') : '-';
          return JSON.stringify({outcome: 'clicked',
            tag: target.tagName || '?', role: role,
            jsaction: !!(target.hasAttribute && target.hasAttribute('jsaction')),
            qual: 'descendant'});
        })()
        """
    }

    /// The post-click step classifier for the chooser
    /// watch: 'signed-in' (the page left
    /// accounts.google.com) / 'error:<ui text>' /
    /// 'code-input' / 'prompt' (the Tap Yes phone prompt)
    /// / 'other'. Error text is public UI text, never a
    /// field value.
    static let chooserStep = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          if (location.href.indexOf('accounts.google.com') < 0) { return 'signed-in'; }
          var alerts = document.querySelectorAll('[role="alert"], .o6cuMc');
          for (var i = 0; i < alerts.length; i++) {
            var at = (alerts[i].innerText || alerts[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (at && vis(alerts[i])) { return 'error:' + at.slice(0, 80); }
          }
          var code = document.querySelector('input[type="tel"], input[autocomplete="one-time-code"], input[name="idvPin"], input[name="code"], input[inputmode="numeric"]');
          if (vis(code)) { return 'code-input'; }
          var txt = ((document.body && document.body.innerText) || '').toLowerCase();
          if (txt.indexOf('check your phone') >= 0
              || txt.indexOf('kiểm tra điện thoại') >= 0) { return 'prompt'; }
          return 'other';
        })()
        """

    /// Fill the 2SV code input (native value setter +
    /// input/change events, the fillField pattern). The
    /// code is interpolated one-way; the payload returns
    /// only 'filled' / 'nofield'.
    static func fillCodeValue(_ code: String) -> String {
        fillFieldValue(selector: "input[type=\"tel\"], input[autocomplete=\"one-time-code\"], input[name=\"idvPin\"], input[name=\"code\"], input[inputmode=\"numeric\"]",
                       value: code)
    }

    /// Click the code page's Next/Verify button, matched
    /// by visible text first (the matched label rides back
    /// in the result), then the known 2SV Next container
    /// ids. Returns 'clicked:<label>' / 'clicked:#idvNext'
    /// / 'notfound'.
    static let clickNextVerify = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var wanted = ['next', 'verify', 'continue', 'tiếp theo', 'xác minh', 'tiếp tục'];
          var cands = document.querySelectorAll('button, [role="button"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ').toLowerCase();
            if (wanted.indexOf(t) >= 0 && vis(cands[i])) {
              cands[i].click();
              return 'clicked:' + t;
            }
          }
          var box = document.querySelector('#idvPrnNext button, #idvNext button, #idvPrnNext, #idvNext');
          if (box && vis(box)) { box.click(); return 'clicked:#idvNext'; }
          return 'notfound';
        })()
        """

    /// fillField without the follow-up Next click (the
    /// code page's button is clicked separately, by text,
    /// via clickNextVerify — the probe's shape).
    private static func fillFieldValue(selector: String, value: String) -> String {
        """
        (function(){
          var el = document.querySelector(\(jsLiteral(selector)));
          if (!el) { return 'nofield'; }
          el.focus();
          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, \(jsLiteral(value)));
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return 'filled';
        })()
        """
    }

    private static func jsLiteral(_ value: String) -> String {
        var out = "'"
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "'"
    }

    private static func fillField(selector: String, value: String,
                                  nextSelector: String) -> String {
        """
        (function(){
          var el = document.querySelector(\(jsLiteral(selector)));
          if (!el) { return 'nofield'; }
          el.focus();
          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, \(jsLiteral(value)));
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          setTimeout(function(){
            var next = document.querySelector(\(jsLiteral(nextSelector)));
            if (next) { next.click(); }
          }, 350);
          return 'filled';
        })()
        """
    }

    static func fillIdentifier(_ email: String) -> String {
        fillField(selector: "input[name=\"identifier\"], input[type=\"email\"]",
                  value: email,
                  nextSelector: "#identifierNext button, #identifierNext")
    }

    static func fillPassword(_ password: String) -> String {
        fillField(selector: "input[name=\"Passwd\"], input[type=\"password\"]",
                  value: password,
                  nextSelector: "#passwordNext button, #passwordNext")
    }
}

// MARK: - Gold session (design §3)

/// The Gold session: SAPISID-presence state + the cookie
/// mirror that makes the one-time sign-in persist on a
/// platform whose web store may drop it between launches
/// (design §3.1/§3.3). Persistence is engineered here, not
/// assumed: persistent store + mirror in UserDefaults
/// (FIX-214 — see mirrorDefaultsKey) +
/// restore-before-load.
@MainActor
final class JoeYtSession: ObservableObject {
    static let shared = JoeYtSession()

    @Published private(set) var signedIn = false
    let bridgeAvailable = JoeWebBridge.webKitAvailable()

    private init() {}

    private struct CookieRecord: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expires: Date?
    }

    /// FIX-214 (Fault 10 / FL-421, leader decision
    /// 2026-11-22): the mirror lives in UserDefaults,
    /// NOT in a file. The old Application Support file
    /// could never be created by the tvOS sandbox, so
    /// the mirror had NEVER persisted; and the Caches
    /// home the other two writers moved to is
    /// system-purgeable — a cache purge must never sign
    /// the owner out. UserDefaults is the app's own
    /// non-purgeable store, and the payload is the same
    /// JSON cookie-record array the file carried. Only
    /// the cookie COUNT reaches the diagnostic log —
    /// never a value (§3.4).
    private static let mirrorDefaultsKey = "joetv.yt.sessionMirror.v1"

    /// Presence-only re-read of the live store. A fresh
    /// getAllCookies round-trip IS the re-check — the Sony
    /// door's stale-read fault (its check only saw the
    /// session after an exit-time flush) is designed against
    /// by re-reading WHILE the door is open (Sony lesson 1).
    func refresh() async {
        signedIn = await Self.fetchPresence()
    }

    /// Restore-before-load (design §3.3 item 3): check; if
    /// the store has lost the session, write the mirror back
    /// and check again. Called when the player or the door
    /// opens, before any page loads.
    func ensureSession() async {
        await refresh()
        if !signedIn {
            await restoreFromMirror()
            await refresh()
        }
    }

    /// Copies the live YouTube/Google cookies into the app's
    /// own UserDefaults mirror (design §3.3 item 2; FIX-214:
    /// was a file in Application Support — see
    /// mirrorDefaultsKey). Called when the
    /// door closes signed-in and when a members-tier play
    /// first reaches picture. Only the cookie COUNT reaches
    /// the diagnostic log — never a value (§3.4).
    func mirrorNow() async {
        let cookies = await Self.fetchAllCookies()
        let records = cookies
            .map { Self.record(from: $0) }
            .filter {
                $0.domain.contains("youtube.com")
                    || $0.domain.contains("google.com")
            }
        guard records.contains(where: { $0.name == "SAPISID" }) else { return }
        if let data = try? JSONEncoder().encode(records) {
            // FIX-214 (Fault 10): the mirror is a
            // UserDefaults value now (see
            // mirrorDefaultsKey) — the file write it
            // replaces targeted a directory the tvOS
            // sandbox refuses to create, so it silently
            // never landed and restoreFromMirror never
            // had anything to restore.
            UserDefaults.standard.set(data, forKey: Self.mirrorDefaultsKey)
            DiagLog.write("YT", "session mirror saved cookies=\(records.count) store=userdefaults")
        }
    }

    private func restoreFromMirror() async {
        guard let data = UserDefaults.standard.data(forKey: Self.mirrorDefaultsKey),
              let records = try? JSONDecoder().decode([CookieRecord].self,
                                                      from: data),
              !records.isEmpty else { return }
        let dicts = records.map { Self.dictionary(from: $0) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            JoeWebBridge.restoreCookies(dicts) { cont.resume() }
        }
        DiagLog.write("YT", "session mirror restored cookies=\(records.count) store=userdefaults")
    }

    // MARK: Bridge wrappers

    /// Sendable snapshot of one cookie — the ONLY shape
    /// that crosses the fetch continuation. The bridge
    /// delivers [String: Any] dictionaries; a dictionary
    /// array (like [HTTPCookie]) is not Sendable, and a
    /// continuation's resume argument is a `sending`
    /// parameter, so resuming with the dictionaries is a
    /// Swift 6 error from ANY isolation domain: CI run #16
    /// rejected it from the bridge completion's own region,
    /// and run #17 rejected the same statement hopped into
    /// the MainActor. No hop fixes a non-Sendable value.
    /// This struct is Sendable BY CONSTRUCTION — every
    /// stored property is a value type (String / Bool /
    /// Date?) — and the mapping happens INSIDE the bridge
    /// completion, so the dictionaries never cross.
    ///
    /// The field set is the exact union the consumers
    /// read, verified against the old dictionary code:
    /// fetchPresence reads name + domain; mirrorNow (via
    /// record(from:)) reads name, value, domain, path,
    /// secure, expires. It is also exactly the key set the
    /// bridge emits (JoeWebBridge.m fetch) and consumes
    /// (restore), so the persisted mirror payload is
    /// unchanged field for field. NSHTTPCookie's HTTPOnly
    /// flag is deliberately NOT carried: the bridge never
    /// exports it, no consumer reads it, and it cannot be
    /// set at rebuild time (no HTTPOnly key exists in the
    /// public cookie-properties API), so it can never
    /// participate in mirror fidelity.
    private struct CookieSnapshot: Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expires: Date?
    }

    private static func fetchAllCookies() async -> [CookieSnapshot] {
        await withCheckedContinuation {
            (cont: CheckedContinuation<[CookieSnapshot], Never>) in
            JoeWebBridge.fetchAllCookies { entries in
                // Map HERE, inside the completion: only the
                // Sendable snapshots cross the continuation.
                cont.resume(returning: entries.compactMap(Self.snapshot(from:)))
            }
        }
    }

    /// Dictionary → snapshot, with the old record(from:)
    /// extraction rules verbatim: an entry missing a
    /// String name, value or domain is dropped; path
    /// defaults to "/"; secure reads NSNumber's boolValue
    /// (default false); expires is the optional Date.
    /// Dropping malformed entries here (rather than in
    /// mirrorNow's old compactMap) yields the identical
    /// record set downstream — both mappings are
    /// order-preserving filters over the same entries.
    /// nonisolated: it runs inside the bridge's
    /// nonisolated completion and touches only its
    /// argument.
    nonisolated private static func snapshot(from entry: [String: Any]) -> CookieSnapshot? {
        guard let name = entry["name"] as? String,
              let value = entry["value"] as? String,
              let domain = entry["domain"] as? String else { return nil }
        return CookieSnapshot(
            name: name,
            value: value,
            domain: domain,
            path: (entry["path"] as? String) ?? "/",
            secure: (entry["secure"] as? NSNumber)?.boolValue ?? false,
            expires: entry["expires"] as? Date)
    }

    private static func fetchPresence() async -> Bool {
        let cookies = await fetchAllCookies()
        return cookies.contains {
            $0.name == "SAPISID" && $0.domain.contains("youtube.com")
        }
    }

    /// Snapshot → persisted record: a total conversion —
    /// every snapshot already carries a name, value and
    /// domain (snapshot(from:) enforced them), which is
    /// why mirrorNow's map is no longer a compactMap.
    private static func record(from snapshot: CookieSnapshot) -> CookieRecord {
        CookieRecord(
            name: snapshot.name,
            value: snapshot.value,
            domain: snapshot.domain,
            path: snapshot.path,
            secure: snapshot.secure,
            expires: snapshot.expires)
    }

    private static func dictionary(from record: CookieRecord) -> [String: Any] {
        var entry: [String: Any] = [
            "name": record.name,
            "value": record.value,
            "domain": record.domain,
            "path": record.path,
            "secure": NSNumber(value: record.secure),
        ]
        if let expires = record.expires { entry["expires"] = expires }
        return entry
    }
}

// MARK: - Bridge controller

/// The NSObject delegate between JoeWebHostView (ObjC) and
/// the Swift models. Plain NSObject, the JoePlayerView
/// Coordinator idiom: WebKit delivers every callback on the
/// main queue, and each one hops formally into the model's
/// @MainActor closures. The class itself stays nonisolated
/// (the ObjC delegate requirements must), but every wrapper
/// that touches the host view is @MainActor — JoeWebHostView
/// is a UIView, so its methods and properties are
/// main-actor-isolated, and every caller of these wrappers
/// is one of the two @MainActor models (CI run #16 warned
/// on each of these call sites).
final class JoeWebController: NSObject, JoeWebHostDelegate {
    weak var host: JoeWebHostView?

    var onPoll: (@MainActor (String?) -> Void)?
    var onFinishLoad: (@MainActor () -> Void)?
    var onFailLoad: (@MainActor (String) -> Void)?
    var onTerminated: (@MainActor () -> Void)?
    var onExitURL: (@MainActor (String) -> Void)?

    @MainActor
    func load(url: String, userAgent: String?, lockedURL: String?) {
        host?.lockedURLString = lockedURL
        host?.loadURLString(url, userAgent: userAgent)
    }

    /// Re-aims the PlayerLockdown at a new watch URL WITHOUT
    /// loading it — used when the page advanced ITSELF to the
    /// next episode (playlist context) and the player model
    /// adopted the landed episode: the lock must follow the
    /// model's current episode or the next self-advance would
    /// read as a wander and exit.
    @MainActor
    func relock(url: String) {
        host?.lockedURLString = url
    }

    @MainActor
    func evaluate(_ js: String) {
        host?.evaluateJavaScript(js, completion: nil)
    }

    @MainActor
    func evaluateForResult(_ js: String,
                           completion: @escaping @MainActor (String?) -> Void) {
        // The completion MUST fire on every path (review
        // round 1, BLOCKER 2): with a nil host the old
        // optional-chain simply dropped it, and any
        // caller waiting on it — the door chooser's
        // continuation in evaluateAsync — hung forever.
        guard let host else {
            completion(nil)
            return
        }
        // The completion closure captures the host
        // STRONGLY (review round 2, MINOR): the controller
        // holds it weakly, and a host deallocated mid-
        // evaluation could take the completion with it —
        // the capture keeps the host (and its web view)
        // alive until the handler has fired.
        host.evaluateJavaScript(js) { result in
            _ = host
            Task { @MainActor in completion(result) }
        }
    }

    /// v2.0.42: document-start scripts (the door's
    /// capability masking). Sticky by design: the script
    /// is remembered and applied to the current host AND
    /// to any host created later, so the install lands
    /// before the first navigation regardless of the
    /// exact order the view and the model start in.
    private var startScripts: [String] = []

    @MainActor
    func installDocumentStartScript(_ js: String) {
        startScripts.append(js)
        host?.addDocumentStartScript(js)
    }

    /// Called by the representable when a host is born.
    @MainActor
    func applyStartScripts(to newHost: JoeWebHostView) {
        for js in startScripts {
            newHost.addDocumentStartScript(js)
        }
    }

    @MainActor
    func startPoll() {
        host?.startPolling(withInterval: 2.0, javaScript: JoeYtJS.poll)
    }

    @MainActor
    func stopPoll() {
        host?.stopPolling()
    }

    // MARK: JoeWebHostDelegate

    func joeHost(_ host: JoeWebHostView, didPollResult result: String?) {
        let callback = onPoll
        Task { @MainActor in callback?(result) }
    }

    func joeHostDidFinishLoad(_ host: JoeWebHostView) {
        let callback = onFinishLoad
        Task { @MainActor in callback?() }
    }

    func joeHost(_ host: JoeWebHostView, didFailLoadWithMessage message: String) {
        let callback = onFailLoad
        Task { @MainActor in callback?(message) }
    }

    func joeHostDidTerminateWebContent(_ host: JoeWebHostView) {
        let callback = onTerminated
        Task { @MainActor in callback?() }
    }

    func joeHost(_ host: JoeWebHostView, didRequestExitForURL url: String) {
        let callback = onExitURL
        Task { @MainActor in callback?(url) }
    }
}

// MARK: - SwiftUI host

struct JoeWebView: UIViewRepresentable {
    let controller: JoeWebController
    let navigationMode: JoeWebNavigationMode
    let playbackPresses: Bool

    func makeUIView(context: Context) -> JoeWebHostView {
        let host = JoeWebHostView(frame: .zero)
        host.navigationMode = navigationMode
        host.playbackPressesEnabled = playbackPresses
        host.delegate = controller
        controller.host = host
        controller.applyStartScripts(to: host)
        return host
    }

    func updateUIView(_ uiView: JoeWebHostView, context: Context) {}

    static func dismantleUIView(_ uiView: JoeWebHostView, coordinator: ()) {
        uiView.stopPolling()
        uiView.delegate = nil
    }
}

// MARK: - Offscreen host (PO-token minter)
//
// claude/po-minter-core: the third bridge surface. A
// JoeWebHostView created OFFSCREEN — never added to a window
// or a SwiftUI hierarchy — in the MinterLockdown navigation
// mode, kept alive by its owner (JoeYtPoMinter) for as long
// as the minter needs the page. The two existing surfaces
// (JoeWebView for the player and the door) are untouched:
// this type only reuses JoeWebController's delegate plumbing.
@MainActor
final class JoeWebOffscreenHost {
    let controller = JoeWebController()
    private(set) var host: JoeWebHostView?

    init() {
        // A real, non-zero frame: WebKit lays the page out
        // against it even though no window ever shows it.
        let host = JoeWebHostView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        host.navigationMode = .minterLockdown
        host.playbackPressesEnabled = false
        host.delegate = controller
        controller.host = host
        self.host = host
    }

    /// Loads a local page (no network) as `baseURL`, with
    /// `userAgent` as navigator.userAgent. Outcome arrives on
    /// the controller's onFinishLoad / onFailLoad callbacks.
    func loadLocalPage(html: String, baseURL: String, userAgent: String) {
        host?.loadHTMLString(html, baseURLString: baseURL, userAgent: userAgent)
    }

    /// Drops the web view. Idempotent.
    func teardown() {
        host?.stopPolling()
        host?.delegate = nil
        controller.host = nil
        host = nil
    }
}

// MARK: - Player

/// One poll read, decoded from JoeYtJS.poll's JSON.
private struct JoeYtPollState: Decodable {
    let has: Bool
    /// 1 when the #movie_player API answered (authoritative);
    /// state is then its getPlayerState() (1 playing,
    /// 3 buffering, 2 paused, 0 ended, -1 unstarted).
    let api: Int
    let state: Int
    /// The page's current video id per getVideoData().
    let vid: String
    let playing: Bool
    let paused: Bool
    let ended: Bool
    let muted: Bool
    let t: Double
    let d: Double
    let pin: Int
    let err: String
    let url: String
}

/// The YouTube player surface's state machine (design
/// §2.4/§2.5 + the Sony lessons):
/// - AUTO chain watchmax → watch → mobile, stepping down on
///   a page error or ~18 s (9 polls) without playing.
/// - The VEIL covers the surface from load until the
///   watchmax pin is VERIFIED in-page (Sony lesson 2: no
///   visible web background, ever); fallback surfaces lift
///   it on first playing; a pin that never verifies lifts it
///   after 9 playing polls so the veil can never trap.
/// - The owner's acceptance points (2026-11-19) are the
///   contract: (1) full-screen immediately — the veil above;
///   (2) a next-episode BUTTON in the player — the SwiftUI
///   control bar the view renders from `controlsUp`, with
///   the Down press as its shortcut; (3) auto-advance at
///   the end — `ended` is an observable poll field and
///   scheduleAutoNext rides it. Seek is out of scope by his
///   ruling (playback runs on YouTube's page).
/// - Auto (and only Auto) falls through to the chain when
///   every YouTube surface fails and a chain match exists —
///   the app substitutes a working source itself (the house
///   "always ready" standard, design §1.6). A manual YouTube
///   pick is never overridden.
@MainActor
final class JoeYtPlayerModel: ObservableObject {
    @Published var veilUp = true
    @Published var statusLine: String?
    /// The control bar (episode label + the next-episode
    /// button) is up at open and after every press, and
    /// auto-hides ~4 s later so the film owns the screen.
    @Published var controlsUp = true
    @Published var endSlate = false
    @Published var failureText: String?
    @Published private(set) var bridgeMissing = false
    @Published private(set) var currentIndex: Int

    let controller = JoeWebController()
    private let request: JoeYtPlayRequest
    private var surface = 0
    private var started = false
    private var pollsWithoutPlay = 0
    private var playingPolls = 0
    private var firstPlaying = false
    private var cssInjected = false
    private var endedHandled = false
    private var terminal = false
    private var mirroredThisPlay = false
    /// True from loadSurface until the load commits (the
    /// bridge's finish callback, or a poll whose URL already
    /// carries the current episode's id). While it is set,
    /// the wander check below MUST NOT fire: the poll can
    /// still be reading the PREVIOUS episode's page, whose
    /// video id legitimately differs from the just-advanced
    /// currentIndex (review MAJOR, 2026-11-19 — without the
    /// gate, next-episode and auto-next could exit the
    /// player instead of advancing).
    private var loadInFlight = false
    /// Process-death recovery (research 2026-11-19): the
    /// last position the poll vouched for, and the seek-back
    /// owed after a termination reload. tvOS kills the web
    /// content process under memory pressure with no warning;
    /// the bridge reports it, the model reloads the same
    /// episode and seeks back to the checkpoint.
    private var checkpoint: Double = 0
    private var pendingSeek: Double?
    private var statusTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?

    var onFallThrough: ((MovieRoute) -> Void)?
    /// The unified-detail hand-back: the player was launched
    /// from inside JoeMovieDetail in Auto mode and every
    /// YouTube surface failed — the episode returns to that
    /// detail, which plays it via the chain.
    var onDetailFallThrough: ((JoeYtChainPlay) -> Void)?
    var onExitRequest: (() -> Void)?

    init(request: JoeYtPlayRequest) {
        self.request = request
        self.currentIndex = request.startIndex
    }

    var episodeLabel: String {
        "Tập \(currentIndex + 1) / \(request.videoIds.count)"
    }

    var hasNextEpisode: Bool {
        currentIndex + 1 < request.videoIds.count
    }

    /// Every press (and every episode change) raises the
    /// control bar; it lowers itself ~4 s after the last
    /// one. When it lowers, the view hands first responder
    /// back to the web host (see JoeYtPlayerView).
    func notePressActivity() {
        controlsUp = true
        controlsTask?.cancel()
        controlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.controlsUp = false
        }
    }

    private var isMembersTier: Bool {
        request.tier == "gold" || request.tier == "vip"
            || request.tier == "members"
    }

    func start() {
        guard !started else { return }
        started = true
        guard JoeWebBridge.webKitAvailable() else {
            bridgeMissing = true
            DiagLog.write("YT", "bridge unavailable — player explanation shown")
            return
        }
        controller.onPoll = { [weak self] result in
            self?.handlePollResult(result)
        }
        controller.onFinishLoad = { [weak self] in
            // The current episode's page has committed; the
            // wander check may trust poll URLs again.
            self?.loadInFlight = false
        }
        controller.onFailLoad = { [weak self] _ in
            // A late failure for a superseded load can step
            // the chain one extra notch; the chain is bounded
            // (3 surfaces, terminal at the end) and the
            // no-play timeout reaches the same end state, so
            // the simplification is safe.
            self?.stepDown(reason: "load failed")
        }
        controller.onTerminated = { [weak self] in
            self?.handleTermination()
        }
        controller.onExitURL = { [weak self] _ in
            guard let self, !self.terminal else { return }
            self.terminal = true
            DiagLog.write("YT", "navigation lockdown exit — back to detail")
            self.onExitRequest?()
        }
        Task { [weak self] in
            // Restore-before-load (design §3.3): a dropped
            // store session is repaired from the mirror
            // before the watch page ever loads. If the view
            // was dismissed while the restore was in flight
            // (stop() ran), the load must NOT start on the
            // torn-down surface (review MINOR, 2026-11-19).
            await JoeYtSession.shared.ensureSession()
            guard let self, !self.terminal else { return }
            self.loadSurface(0)
            self.controller.startPoll()
        }
        notePressActivity()
    }

    func stop() {
        terminal = true
        JoeWebBridge.setRemotePressConsumer(nil)
        statusTask?.cancel()
        nextTask?.cancel()
        controlsTask?.cancel()
        controller.stopPoll()
    }

    // MARK: Remote presses (window-level routing)
    //
    // The presses are decided at the UIWindow level by the
    // bridge (research 2026-11-19): WebKit's content view is
    // first responder over the playing page and takes them
    // itself, so they never reach a hosting view. The model
    // registers ONE consumer while the player is on screen:
    // - PlayPause always toggles (it has no focus meaning).
    // - Select / Down act only while the control bar is DOWN
    //   (the page owns the screen): Select toggles, Down is
    //   the next-episode button's shortcut. While the bar is
    //   UP they belong to the focus engine and the focused
    //   button, so the consumer declines them.
    // - Menu is never offered by the bridge — it always
    //   reaches .onExitCommand.
    // Terminal slates (failure / end) decline everything:
    // their SwiftUI buttons own the remote.
    func registerPressConsumer() {
        JoeWebBridge.setRemotePressConsumer { [weak self] pressType in
            // sendEvent arrives on the main thread (UIKit's
            // own contract), so the main-actor body is sound.
            MainActor.assumeIsolated {
                guard let self, !self.terminal,
                      self.failureText == nil, !self.endSlate
                else { return false }
                if pressType == UIPress.PressType.playPause.rawValue {
                    self.togglePlay()
                    return true
                }
                guard !self.controlsUp else { return false }
                if pressType == UIPress.PressType.select.rawValue {
                    self.togglePlay()
                    return true
                }
                if pressType == UIPress.PressType.downArrow.rawValue {
                    self.advance()
                    return true
                }
                return false
            }
        }
    }

    func togglePlay() {
        controller.evaluate(JoeYtJS.togglePlay)
        notePressActivity()
    }

    // MARK: Web-process death

    /// The bridge reports the web content process died or
    /// hung. Recovery: reload the CURRENT surface for the
    /// current episode and, once it plays again, seek back
    /// to the checkpoint. If the reload never plays, the
    /// ordinary no-play timeout steps the chain down as
    /// usual — the recovery adds no new trap.
    private func handleTermination() {
        guard !terminal, started, !bridgeMissing else { return }
        DiagLog.write("YT", "web content process terminated/unresponsive — reloading ep=\(currentIndex + 1) at checkpoint \(Int(checkpoint))s")
        pendingSeek = checkpoint > 2 ? checkpoint : nil
        loadSurface(surface)
    }

    func retry() {
        guard !bridgeMissing else { return }
        failureText = nil
        terminal = false
        pendingSeek = nil
        loadSurface(0)
        controller.startPoll()
    }

    // MARK: Surfaces

    private func loadSurface(_ s: Int) {
        surface = s
        pollsWithoutPlay = 0
        playingPolls = 0
        firstPlaying = false
        cssInjected = false
        endedHandled = false
        mirroredThisPlay = false
        checkpoint = 0
        // Every load is a fresh playback attempt: the end
        // slate belongs only to the genuinely-ended moment
        // (scheduleAutoNext sets it WITHOUT a load). Leaving
        // it up across a termination reload or a post-end
        // retry would play the film behind a control-less
        // slate with all presses declined (review MINOR,
        // 2026-11-19).
        endSlate = false
        loadInFlight = true
        veilUp = true
        let vid = request.videoIds[currentIndex]
        // The playlist context rides the watch URL (research
        // 2026-11-19): with &list= the page's OWN up-next
        // follows playlist order instead of recommendations,
        // and if the page advances itself the poll's video id
        // lets the model adopt the landed episode (see the
        // wander check). The app-side load stays the primary
        // advance mechanism.
        let watch = "https://www.youtube.com/watch?v=\(vid)&list=\(request.pid)&autoplay=1"
        switch s {
        case 0, 1:
            controller.load(url: watch, userAgent: JoeYtJS.desktopUA,
                            lockedURL: watch)
        default:
            // The lockdown compares host + path + video id,
            // so each surface locks to its OWN host — the
            // mobile surface locks to m.youtube.com, never to
            // the desktop URL it conceptually mirrors.
            let mobile = "https://m.youtube.com/watch?v=\(vid)&list=\(request.pid)&autoplay=1"
            controller.load(url: mobile, userAgent: nil,
                            lockedURL: mobile)
        }
        DiagLog.write("YT", "surface load s=\(s) ep=\(currentIndex + 1)")
    }

    private func stepDown(reason: String) {
        guard !terminal else { return }
        DiagLog.write("YT", "surface \(surface) down (\(reason))")
        if surface >= 2 {
            terminal = true
            controller.stopPoll()
            if let chainPlay = request.chainPlay {
                DiagLog.write("YT", "Auto: all YouTube surfaces failed — handing the episode back to the chain detail")
                onDetailFallThrough?(chainPlay)
            } else if request.mode == .auto, let route = request.chainRoute {
                DiagLog.write("YT", "Auto: all YouTube surfaces failed — falling through to chain")
                onFallThrough?(route)
            } else {
                failureText = "Không phát được qua YouTube. Anh bấm Thử lại, hoặc quay lại rồi chọn nguồn khác."
                veilUp = false
            }
            return
        }
        loadSurface(surface + 1)
    }

    // MARK: Poll

    private func handlePollResult(_ result: String?) {
        guard !terminal else { return }
        guard let result,
              let data = result.data(using: .utf8),
              let state = try? JSONDecoder().decode(JoeYtPollState.self,
                                                    from: data)
        else { return }

        // The §2.5 wander check: if the page ever leaves the
        // locked video, leave the player instead of stranding
        // the owner on a web page. Gated on loadInFlight: a
        // poll taken while the current episode's page is
        // still loading can legitimately report the PREVIOUS
        // episode's URL — that is a load in progress, not a
        // wander (review MAJOR, 2026-11-19). A poll whose id
        // already matches the current episode also clears
        // the gate, in case a load shape never delivers the
        // finish callback.
        if state.has,
           let v = Self.videoId(fromWatchURL: state.url) {
            if v == request.videoIds[currentIndex] {
                loadInFlight = false
            } else if !loadInFlight,
                      currentIndex + 1 < request.videoIds.count,
                      v == request.videoIds[currentIndex + 1] {
                // The page advanced ITSELF to the next
                // episode (playlist context on the watch
                // URL): adopt the landed episode instead of
                // reading it as a wander — sync the index,
                // re-aim the lockdown, and let the poll loop
                // re-pin the watchmax styling on the new page.
                adoptSelfAdvance()
                return
            } else if !loadInFlight {
                terminal = true
                DiagLog.write("YT", "page left the locked video — exiting player")
                onExitRequest?()
                return
            }
        }

        // While the load is in flight, this poll still
        // describes the OUTGOING page (review MAJOR,
        // 2026-11-19): its err / ended / playing must NOT
        // act on the new surface — a stale `ended` would
        // schedule a second advance and skip an episode, a
        // stale `playing` would set firstPlaying and disarm
        // the no-play timeout for the new page, a stale
        // error would step the new surface down. Only the
        // timeout accounting runs, so a load that neither
        // finishes nor fails still steps down on schedule.
        if loadInFlight {
            pollsWithoutPlay += 1
            if pollsWithoutPlay >= 9 {
                stepDown(reason: "load timeout")
            }
            return
        }

        if !state.err.isEmpty {
            stepDown(reason: "page error")
            return
        }

        if state.ended {
            if !endedHandled {
                endedHandled = true
                scheduleAutoNext()
            }
            return
        }

        // Muted autoplay (the page started the film without
        // sound): nudge it unmuted before first picture
        // counts, the Sony poll shape — after first playing
        // a mute state is the page's/owner's own business.
        if state.has && state.muted && !firstPlaying {
            controller.evaluate(JoeYtJS.nudgePlay)
        }

        if state.playing {
            pollsWithoutPlay = 0
            playingPolls += 1
            // The process-death checkpoint: the last position
            // the page itself vouched for while playing.
            if state.t > 1 && state.d > 0 {
                checkpoint = state.t
            }
            if !firstPlaying {
                firstPlaying = true
                DiagLog.write("YT", "playing surface=\(surface) ep=\(currentIndex + 1)")
                if let seek = pendingSeek {
                    pendingSeek = nil
                    controller.evaluate(JoeYtJS.seekTo(seek))
                    DiagLog.write("YT", "recovery seek to \(Int(seek))s")
                }
                if isMembersTier && !mirroredThisPlay {
                    mirroredThisPlay = true
                    Task { await JoeYtSession.shared.mirrorNow() }
                }
            }
            if surface == 0 {
                if !cssInjected {
                    cssInjected = true
                    controller.evaluate(JoeYtJS.injectWatchmaxCSS)
                } else if state.pin == 1 {
                    if veilUp {
                        veilUp = false
                        DiagLog.write("YT", "watchmax pin verified — veil lifted")
                    }
                } else if playingPolls >= 9 && veilUp {
                    // No-trap fallback: the film is playing
                    // but the pin never verified (a page
                    // shape the CSS did not fit) — show the
                    // page as-is rather than veiling a
                    // playing film forever.
                    veilUp = false
                    DiagLog.write("YT", "pin unverified after 9 playing polls — veil lifted (fallback)")
                }
            } else if veilUp {
                veilUp = false
            }
        } else {
            playingPolls = 0
            if !firstPlaying {
                pollsWithoutPlay += 1
                if state.has && (state.paused || state.muted) {
                    controller.evaluate(JoeYtJS.nudgePlay)
                }
                if pollsWithoutPlay >= 9 {
                    stepDown(reason: "no-play timeout")
                }
            }
        }
    }

    // MARK: Episode flow

    private func scheduleAutoNext() {
        nextTask?.cancel()
        guard currentIndex + 1 < request.videoIds.count else {
            endSlate = true
            veilUp = false
            DiagLog.write("YT", "last episode ended — end slate")
            return
        }
        flashStatus("Hết tập — đang chuyển tập \(currentIndex + 2)…")
        nextTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Manual next (Down press, the control-bar button) and
    /// auto-next share this. With no next episode a MANUAL
    /// call is a plain no-op — the end slate belongs to the
    /// genuinely-ended flow (scheduleAutoNext sets it when
    /// `ended` fires on the last episode); raising it from a
    /// stray Down press would trap a still-playing film
    /// behind a slate with no controls (review MAJOR,
    /// 2026-11-19).
    func advance() {
        nextTask?.cancel()
        guard !terminal else { return }
        guard currentIndex + 1 < request.videoIds.count else {
            return
        }
        currentIndex += 1
        endSlate = false
        pendingSeek = nil
        loadSurface(0)
        flashStatus("Tập \(currentIndex + 1)")
        notePressActivity()
    }

    /// The page advanced itself into the next episode (the
    /// wander check caught the landed id): sync to it WITHOUT
    /// a load — the film is already there. Per-episode state
    /// resets as for a load; the watchmax CSS must re-inject
    /// on the new page (cssInjected=false) and the veil
    /// re-covers until the pin re-verifies, so the owner
    /// never sits on an unstyled watch page.
    private func adoptSelfAdvance() {
        currentIndex += 1
        endSlate = false
        pollsWithoutPlay = 0
        playingPolls = 0
        firstPlaying = false
        cssInjected = false
        endedHandled = false
        checkpoint = 0
        veilUp = true
        let vid = request.videoIds[currentIndex]
        // The relock must keep the CURRENT surface's host
        // (the lockdown compares hosts): desktop surfaces
        // relock to www.youtube.com, the mobile surface to
        // m.youtube.com.
        let base = surface == 2
            ? "https://m.youtube.com/watch"
            : "https://www.youtube.com/watch"
        controller.relock(
            url: "\(base)?v=\(vid)&list=\(request.pid)&autoplay=1")
        flashStatus("Tập \(currentIndex + 1)")
        DiagLog.write("YT", "page self-advanced — adopted ep=\(currentIndex + 1)")
    }

    private func flashStatus(_ text: String) {
        statusLine = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.statusLine = nil
        }
    }

    private static func videoId(fromWatchURL string: String) -> String? {
        guard let components = URLComponents(string: string),
              components.path == "/watch" else { return nil }
        return components.queryItems?
            .first(where: { $0.name == "v" })?.value
    }
}

struct JoeYtPlayerView: View {
    let request: JoeYtPlayRequest
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @StateObject private var model: JoeYtPlayerModel
    @FocusState private var retryFocused: Bool
    @FocusState private var nextFocused: Bool
    /// FL-353 sweep (2.0.45 gate round 6, B6-2): the
    /// bridge-missing explanation's back button focus.
    @FocusState private var explanationFocused: Bool

    init(request: JoeYtPlayRequest) {
        self.request = request
        _model = StateObject(wrappedValue: JoeYtPlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.bridgeMissing {
                explanation
            } else {
                JoeWebView(controller: model.controller,
                           navigationMode: .playerLockdown,
                           playbackPresses: true)
                if model.veilUp {
                    veil
                }
                if let line = model.statusLine {
                    statusPill(line)
                }
                if model.controlsUp && model.hasNextEpisode
                    && model.failureText == nil {
                    controlBar
                }
                if model.endSlate {
                    endSlate
                }
                if let failure = model.failureText {
                    failureSlate(failure)
                }
            }
        }
        // Menu closes THIS player back to the detail (the
        // house own-root construction): the bridge never
        // consumes Menu, so the press lands here.
        .onExitCommand {
            if model.bridgeMissing {
                // Family logging parity (2.0.45): the
                // explanation branch's Menu exit is named
                // too; its button carries the nút line.
                DiagLog.write("YT", "slate explanation — về detail (trigger=menu)")
            }
            nav.ytPlayer = nil
        }
        .onAppear {
            model.registerPressConsumer()
            model.onFallThrough = { route in
                nav.ytPlayer = nil
                nav.ytDetail = nil
                nav.movie = route
            }
            model.onDetailFallThrough = { token in
                nav.ytPlayer = nil
                nav.ytChainPlay = token
            }
            model.onExitRequest = { nav.ytPlayer = nil }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        // When the control bar lowers itself, hand first
        // responder back to the web host so the playback
        // presses keep landing on it.
        .onChange(of: model.controlsUp) { _, up in
            if !up { model.controller.host?.focusContent() }
        }
    }

    /// The control bar — acceptance point 2: a real
    /// next-episode BUTTON inside the player. It rides above
    /// the veil at open (so the button is discoverable the
    /// moment the player opens), re-appears on every press,
    /// and auto-hides with the model's controls timer. The
    /// Down press is its shortcut (the window-level press
    /// routing asks the model for the same advance()).
    private var controlBar: some View {
        VStack {
            Spacer()
            HStack {
                Text(model.episodeLabel)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                Spacer()
                Button {
                    model.advance()
                } label: {
                    JoeSecondaryLabel(title: "Tập tiếp ⏭")
                }
                .joeCardButton()
                .focused($nextFocused)
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
    }

    /// Sony lesson 2: the surface stays covered until the
    /// watchmax styling is verified in-page — the owner
    /// never sees a web page, only this slate, then film.
    private var veil: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                ProgressView()
                    .tint(.white)
                Text("Đang mở phim…")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(request.seriesTitle) · \(model.episodeLabel)")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
    }

    private func statusPill(_ line: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Text(line)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                Spacer()
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
    }

    private var endSlate: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 14) {
                Text("Đã hết tập cuối của bộ này.")
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Bấm Menu để quay lại danh sách tập.")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .ignoresSafeArea()
    }

    private func failureSlate(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 22) {
                Text(text)
                    .font(.system(size: 27))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                Button {
                    model.retry()
                } label: {
                    JoeSecondaryLabel(title: "Thử lại")
                }
                .joeCardButton()
                .focused($retryFocused)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($retryFocused, true)
    }

    private var explanation: some View {
        VStack(spacing: 16) {
            Text("Tính năng YouTube không khả dụng trên bản tvOS này.")
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Phần TVB còn lại — Tủ Phim · KKPhim · VSMOV · Film4K — vẫn dùng bình thường.")
                .font(.system(size: 25))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            // FL-353 same-family sweep (gate round 6,
            // B6-2): this branch replaces the WHOLE tree —
            // the web host leaves with it — so unlike the
            // end/failure slates (which overlay the live
            // host whose content view anchors focus), this
            // notice held NO focusable element and the
            // view's root Menu handler could never fire
            // (the §8.1 mechanism): Menu exited the app.
            // One focusable button, the family
            // construction, makes the exit real.
            Button {
                DiagLog.write("YT", "slate explanation — về detail (trigger=nút)")
                nav.ytPlayer = nil
            } label: {
                JoeSecondaryLabel(title: "Quay lại")
            }
            .joeCardButton()
            .focused($explanationFocused)
        }
        .padding(.horizontal, 80)
        .defaultFocus($explanationFocused, true)
    }
}

// MARK: - Sign-in door (design §3.2)

/// Door-side loader: restores the mirror session first
/// (restore-before-load), then lands on the channel page
/// with the SAFARI user agent (research 2026-11-19: the
/// door's UA is the identity Google's sign-in check reads;
/// the player's Chrome UA stays on the player only). Every
/// finished page load re-reads the session state. The model
/// also probes which credential field the page is showing
/// and fills it from the door's native form on request.
@MainActor
private final class JoeYtDoorModel: ObservableObject {
    let controller = JoeWebController()
    @Published var fieldKind = "none"
    private var started = false
    /// Set by stop() when the door closes; the start
    /// load below checks it after its await (review
    /// round 5, MINOR — the same post-restore guard the
    /// player model carries).
    private var stopped = false

    func start() {
        guard !started else { return }
        started = true
        stopped = false
        controller.onFinishLoad = {
            Task { await JoeYtSession.shared.refresh() }
        }
        // v2.0.42: capability masking BEFORE the first
        // load (Probe 4's mechanism, device-proven): with
        // no WebAuthn surface, Google stays off the
        // passkey ceremony the re-signed build cannot
        // complete, and the 2SV chooser below becomes the
        // only detour.
        controller.installDocumentStartScript(JoeYtJS.doorMasking)
        DiagLog.write("YT", "door: masking cài trước lần tải đầu")
        Task { [weak self] in
            await JoeYtSession.shared.ensureSession()
            // The door may have closed during the
            // session restore — never fire the sign-in
            // load into a dismantled host (review round
            // 5, MINOR).
            guard let self, !self.stopped else { return }
            // Land DIRECTLY on Google's sign-in page, not on
            // the channel page (a deliberate difference from
            // the Sony door): reaching the form must not
            // depend on clicking around a web page with the
            // remote — in-page navigation on a bridged tvOS
            // web view is unproven, while the form-first flow
            // needs no in-page click at all. After sign-in,
            // Google's own continue redirect lands on the
            // channel page, inside DoorRoam either way.
            controller.load(
                url: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com%2F%40TVB_Vietnam",
                userAgent: JoeYtJS.safariUA, lockedURL: nil)
        }
    }

    /// One probe of the page's credential field; the door's
    /// 2 s loop calls it alongside the presence refresh so
    /// the native form's buttons enable for the step the
    /// page is actually on. v2.0.42: entering the
    /// 'challenge' step also snapshots the page's
    /// candidate-control inventory (values-free) so a
    /// future page-shape change is diagnosable from one
    /// log line.
    func probeField() {
        controller.evaluateForResult(JoeYtJS.doorProbe) { [weak self] result in
            guard let self, let result, result != self.fieldKind else { return }
            self.fieldKind = result
            if result == "challenge" {
                self.inventoryChallengePage()
            }
        }
    }

    // MARK: 2SV chooser (v2.0.42 — Probe 4 port)
    //
    // Ported from the probe's device-proven door (three
    // passes on 2026-11-20: SMS + click v2; Google prompt
    // ×2). The flow: the passkey step offers 'Try another
    // way' → the chooser lists the account's methods
    // (prompt / authenticator / SMS — no password row on
    // this account) → a row click (v2: qualified ancestor
    // + full press sequence; ONE 3 s descendant retry)
    // → a step watch classifies what follows: signed-in,
    // a code input (owner types the code natively), the
    // phone prompt, or an error (logged, surfaced in the
    // note). Page VALUES are never read back; the code
    // travels one-way and only its length is logged.

    @Published var chooserRows: [String] = []
    @Published var chooserBusy = false
    @Published var chooserNote: String?
    @Published var awaitingCode = false
    private var stepWatchGeneration = 0

    /// Snapshot the challenge page's control inventory
    /// (values-free) into the log.
    private func inventoryChallengePage() {
        controller.evaluateForResult(JoeYtJS.doorDomInventory) { result in
            guard let result else { return }
            DiagLog.write("YT", "door: challenge DOM (chỉ nhãn, không giá trị): \(result)")
        }
    }

    /// Refresh the visible chooser rows (labels only).
    private func refreshChooserRows() {
        controller.evaluateForResult(JoeYtJS.chooserRows) { [weak self] result in
            guard let self, let result,
                  let data = result.data(using: .utf8),
                  let rows = try? JSONDecoder().decode([String].self, from: data)
            else { return }
            if rows != self.chooserRows {
                self.chooserRows = rows
                DiagLog.write("YT", "door: chooser rows=\(rows.count) — \(rows.joined(separator: " | "))")
            }
        }
    }

    /// 'Try another way' — the steer around the passkey
    /// wall. After the click, capture the chooser
    /// inventory; if no inventory exists, ALSO chase the
    /// legacy password row (older accounts list one).
    func tryAnotherWay() {
        guard !chooserBusy else { return }
        chooserBusy = true
        chooserNote = nil
        DiagLog.write("YT", "door: bấm Try another way")
        controller.evaluateForResult(JoeYtJS.clickTryAnotherWay) { [weak self] result in
            guard let self else { return }
            DiagLog.write("YT", "door: Try another way → \(result ?? "nil")")
            self.chooserBusy = false
            self.refreshChooserRows()
            // The legacy chase is tied to the same
            // generation stop() bumps (review round 3,
            // MINOR): after the door closes it must not
            // fire even one more evaluation.
            let generation = self.stepWatchGeneration
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.stepWatchGeneration == generation,
                      self.chooserRows.isEmpty
                else { return }
                self.controller.evaluateForResult(JoeYtJS.clickPasswordMethod) { r2 in
                    DiagLog.write("YT", "door: dò hàng mật khẩu (legacy) → \(r2 ?? "nil")")
                }
            }
        }
    }

    /// One chooser row tap: click v2, and if the step has
    /// not changed in 3 s, ONE retry on the row's first
    /// interactive descendant; then the step watch.
    func chooseRow(_ row: String) {
        guard !chooserBusy else { return }
        cancelStepWatch()
        chooserBusy = true
        chooserNote = nil
        DiagLog.write("YT", "door: chọn dòng chooser — \(row)")
        let needle = Self.rowNeedle(row)
        controller.evaluateForResult(
            JoeYtJS.clickChooserRow(needle: needle, avoid: "passkey")
        ) { [weak self] result in
            guard let self else { return }
            DiagLog.write("YT", "door: click v2 → \(result ?? "nil")")
            self.chooserBusy = false
            self.watchChooserStep(needle: needle, retried: false)
        }
    }

    /// The code field's submit: fill one-way, click the
    /// page's Next/Verify, then the same step watch.
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !chooserBusy else { return }
        cancelStepWatch()
        chooserBusy = true
        chooserNote = nil
        DiagLog.write("YT", "door: điền mã 2SV (dài \(trimmed.count) ký tự — giá trị không log)")
        controller.evaluateForResult(JoeYtJS.fillCodeValue(trimmed)) { [weak self] result in
            guard let self else { return }
            DiagLog.write("YT", "door: điền mã → \(result ?? "nil")")
            self.controller.evaluateForResult(JoeYtJS.clickNextVerify) { [weak self] r2 in
                guard let self else { return }
                DiagLog.write("YT", "door: bấm Next/Verify → \(r2 ?? "nil")")
                self.chooserBusy = false
                self.watchChooserStep(needle: nil, retried: true)
            }
        }
    }

    private func cancelStepWatch() {
        stepWatchGeneration += 1
    }

    /// The door closed (review round 2, MINOR): stop the
    /// chooser step watch from polling an orphaned model
    /// for the rest of its 120 s window. Also bars the
    /// start load if it is still restoring the session
    /// (review round 5, MINOR).
    func stop() {
        stopped = true
        cancelStepWatch()
        chooserBusy = false
    }

    /// Poll the step classifier for up to 120 s after a
    /// chooser action. The retry leg fires once at ~3 s
    /// when a needle is armed AND the step has not moved
    /// at all (review round 1, MINOR: without the
    /// progress check the retry could re-click a row on
    /// an intermediate page the owner already acted on).
    private func watchChooserStep(needle: String?, retried: Bool) {
        stepWatchGeneration += 1
        let generation = stepWatchGeneration
        let deadline = Date().addingTimeInterval(120)
        Task { [weak self] in
            // The retry/progress state lives INSIDE the
            // task (review round 3, BLOCKER): a captured
            // var mutated from a Task closure is a Swift 6
            // compile error — the probe's door kept this
            // state in properties for the same reason.
            // These two are read/written nowhere else.
            var didRetry = retried
            var stepMoved = false
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.stepWatchGeneration == generation
                else { return }
                if let step = await self.readChooserStep() {
                    if step == "code-input" || step == "prompt" {
                        stepMoved = true
                    }
                    let done = self.applyChooserStep(step)
                    if done { return }
                }
                if !didRetry, !stepMoved, let needle,
                   Date() > deadline.addingTimeInterval(-117) {
                    didRetry = true
                    let result = await self.evaluateAsync(
                        JoeYtJS.clickChooserRowRetry(needle: needle, avoid: "passkey"))
                    DiagLog.write("YT", "door: click retry (descendant) → \(result ?? "nil")")
                }
            }
            guard let self, self.stepWatchGeneration == generation else { return }
            DiagLog.write("YT", "door: watch bước chooser — hết 120s chưa đổi bước")
            if self.chooserNote == nil {
                self.chooserNote = "Trang chưa chuyển bước — anh thử lại, hoặc chọn cách xác thực khác."
            }
        }
    }

    private func evaluateAsync(_ js: String) async -> String? {
        await withCheckedContinuation { continuation in
            controller.evaluateForResult(js) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func readChooserStep() async -> String? {
        await evaluateAsync(JoeYtJS.chooserStep)
    }

    /// Returns true when the watch should stop.
    private func applyChooserStep(_ step: String) -> Bool {
        if step == "signed-in" {
            DiagLog.write("YT", "door: chooser watch — ĐÃ ĐĂNG NHẬP")
            awaitingCode = false
            chooserRows = []
            chooserNote = nil
            Task { await JoeYtSession.shared.refresh() }
            return true
        }
        if step.hasPrefix("error:") {
            let text = String(step.dropFirst("error:".count))
            DiagLog.write("YT", "door: chooser watch — trang báo lỗi: \(text)")
            chooserNote = "Google báo: \(text)"
            return true
        }
        if step == "code-input" {
            if !awaitingCode {
                DiagLog.write("YT", "door: chooser watch — trang hỏi mã xác thực")
                awaitingCode = true
                chooserNote = "Google đang hỏi mã xác thực — anh nhập mã vào ô bên dưới rồi bấm Nhập mã."
            }
            return false
        }
        if step == "prompt" {
            if chooserNote == nil || awaitingCode {
                DiagLog.write("YT", "door: chooser watch — chờ duyệt trên điện thoại (Tap Yes)")
                awaitingCode = false
                chooserNote = "Anh mở điện thoại và bấm Yes / Đồng ý để duyệt đăng nhập."
            }
            return false
        }
        return false
    }

    /// The needle a row is clicked by: its text before
    /// any " - " descriptor tail, trimmed and capped —
    /// the shortest unique fragment of the label.
    private static func rowNeedle(_ row: String) -> String {
        var text = row
        if let dash = text.range(of: " - ") {
            text = String(text[..<dash.lowerBound])
        }
        return String(text.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    func fillEmail(_ email: String) {
        controller.evaluate(JoeYtJS.fillIdentifier(email))
        DiagLog.write("YT", "door: identifier filled from native form")
    }

    func fillPassword(_ password: String) {
        controller.evaluate(JoeYtJS.fillPassword(password))
        DiagLog.write("YT", "door: password filled from native form")
    }
}

/// The Gold sign-in door. The owner signs in himself on
/// YouTube/Google's official pages; the app never sees,
/// types or stores a password.
///
/// Sony lesson 1 is built in: the session is re-checked
/// WHILE the door is open (a 2 s loop plus every page
/// finish), and the moment it flips, the door shows its
/// signed-in state with the forward action "Vào xem phim
/// Gold" — the owner is never left hunting for a way back
/// (he got lost twice on the Sony door tonight).
struct JoeYtSignInView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @ObservedObject private var session = JoeYtSession.shared
    @StateObject private var doorModel = JoeYtDoorModel()
    @FocusState private var closeFocused: Bool
    @FocusState private var goldFocused: Bool
    /// The native credential form's fields. The password
    /// lives ONLY in this state while the door is open and
    /// is cleared the moment it has been filled into the
    /// page; neither value is ever logged or stored.
    @State private var emailText = ""
    @State private var passwordText = ""
    /// The 2SV code field (v2.0.42) — same discipline as
    /// the password: view state only, cleared on submit,
    /// never logged or stored.
    @State private var codeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Đăng nhập TVB Gold")
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(theme.text)
            Text("Đăng nhập YouTube bằng tài khoản Gold của anh ngay trên trang chính thức của YouTube/Google. Joe TV không thấy và không lưu mật khẩu của anh — đăng nhập một lần là xem được phim Gold trong app.")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1400, alignment: .leading)
            HStack(spacing: 14) {
                if session.signedIn {
                    Button {
                        nav.ytSignInOpen = false
                    } label: {
                        JoeChipLabel(
                            title: "✓ Đã đăng nhập — Vào xem phim Gold",
                            selected: true)
                    }
                    .joeCardButton()
                    .focused($goldFocused)
                } else {
                    Text("○ Chưa đăng nhập")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
                Button {
                    nav.ytSignInOpen = false
                } label: {
                    JoeSecondaryLabel(title: "Đóng")
                }
                .joeCardButton()
                .focused($closeFocused)
            }
            if !session.signedIn && session.bridgeAvailable {
                nativeForm
            }
            if !session.signedIn && session.bridgeAvailable
                && (doorModel.fieldKind == "challenge"
                    || !doorModel.chooserRows.isEmpty
                    || doorModel.awaitingCode
                    || doorModel.chooserNote != nil) {
                challengeControls
            }
            if session.bridgeAvailable {
                JoeWebView(controller: doorModel.controller,
                           navigationMode: .doorRoam,
                           playbackPresses: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Tính năng YouTube không khả dụng trên bản tvOS này.")
                    .font(.system(size: 27))
                    .foregroundStyle(theme.text)
                    .padding(.top, 30)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        // Menu closes the door back to the screen that
        // opened it (own-root handler, the house rule).
        .onExitCommand { nav.ytSignInOpen = false }
        .defaultFocus($closeFocused, true)
        // Sony lesson 1, completed: the moment the session
        // flips WHILE the door is open, focus lands on the
        // forward action — "Vào xem phim Gold" is where the
        // owner's eyes and remote already are.
        .onChange(of: session.signedIn) { _, now in
            if now { goldFocused = true }
        }
        .task {
            doorModel.start()
            while !Task.isCancelled {
                await session.refresh()
                doorModel.probeField()
                if session.signedIn {
                    DiagLog.write("YT", "door: signed-in detected while open")
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onDisappear {
            doorModel.stop()
            if session.signedIn {
                Task { await JoeYtSession.shared.mirrorNow() }
            }
        }
    }

    /// The text-entry mechanism (research 2026-11-19): a
    /// bridged web view on tvOS has no native typing, so the
    /// owner types here — native fields, the tvOS system
    /// keyboard — and the app types the values into Google's
    /// page fields for him. Each button enables when the
    /// door probe sees the page on that step. The password
    /// field clears itself the moment its value has been
    /// filled into the page.
    private var nativeForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trang Google trên TV không gõ trực tiếp được — anh gõ email và mật khẩu ở hai ô này (bàn phím TV hiện ra), app sẽ điền vào trang đăng nhập giúp anh.")
                .font(.system(size: 23))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1400, alignment: .leading)
            HStack(spacing: 14) {
                TextField("Email Google", text: $emailText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 560)
                Button {
                    doorModel.fillEmail(emailText)
                } label: {
                    JoeSecondaryLabel(title: "Điền email & Tiếp tục")
                }
                .joeCardButton()
                .disabled(emailText.isEmpty
                    || doorModel.fieldKind != "email")
            }
            HStack(spacing: 14) {
                SecureField("Mật khẩu", text: $passwordText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 560)
                Button {
                    let value = passwordText
                    passwordText = ""
                    doorModel.fillPassword(value)
                } label: {
                    JoeSecondaryLabel(title: "Điền mật khẩu & Đăng nhập")
                }
                .joeCardButton()
                .disabled(passwordText.isEmpty
                    || doorModel.fieldKind != "password")
            }
        }
    }

    /// The 2SV challenge controls (v2.0.42 — the Probe 4
    /// port): when Google lands on the passkey /
    /// verification step, the door steers around it —
    /// 'Thử cách khác' opens the account's method list,
    /// each method is a native button, and a code method
    /// gets its own native field. The web page below stays
    /// visible throughout, so the owner watches Google's
    /// own screen react.
    private var challengeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Google đang dừng ở bước xác thực (passkey / xác minh 2 bước). Bấm \"Thử cách khác\" để mở danh sách cách đăng nhập khác của tài khoản, rồi chọn một cách — app bấm giúp anh ngay trên trang.")
                .font(.system(size: 23))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1400, alignment: .leading)
            HStack(spacing: 14) {
                Button {
                    doorModel.tryAnotherWay()
                } label: {
                    JoeSecondaryLabel(title: "Thử cách khác")
                }
                .joeCardButton()
                .disabled(doorModel.chooserBusy)
                if doorModel.chooserBusy {
                    ProgressView()
                        .tint(theme.text)
                }
            }
            if !doorModel.chooserRows.isEmpty {
                ForEach(doorModel.chooserRows, id: \.self) { row in
                    Button {
                        doorModel.chooseRow(row)
                    } label: {
                        JoeSecondaryLabel(title: row)
                    }
                    .joeCardButton()
                    .disabled(doorModel.chooserBusy)
                }
            }
            if doorModel.awaitingCode {
                HStack(spacing: 14) {
                    TextField("Mã xác thực", text: $codeText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 25))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: 560)
                    Button {
                        let value = codeText
                        codeText = ""
                        doorModel.submitCode(value)
                    } label: {
                        JoeSecondaryLabel(title: "Nhập mã")
                    }
                    .joeCardButton()
                    .disabled(codeText.isEmpty || doorModel.chooserBusy)
                }
            }
            if let note = doorModel.chooserNote {
                Text(note)
                    .font(.system(size: 23))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 1400, alignment: .leading)
            }
        }
    }
}
