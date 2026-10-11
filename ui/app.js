// Immich's tabs on the chassis window: Photo libraries, Machine learning, Users, Phones — and what Updates says about the pinned Immich.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var QUEUES = { library: "Reading photo folders", metadataExtraction: "Reading dates, places and camera details", thumbnailGeneration: "Making thumbnails", videoConversion: "Converting videos for playback", sidecar: "Reading sidecar files" };
  var ML_QUEUES = { smartSearch: "Smart search", faceDetection: "Finding faces", facialRecognition: "Recognising people", duplicateDetection: "Finding duplicates", ocr: "Reading text in photos" };
  function imUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function n(v) { return v == null ? "–" : Number(v).toLocaleString(); }
  function vcmp(x, y) { x = x.replace(/^v/, "").split(".").map(Number); y = y.replace(/^v/, "").split(".").map(Number); for (var i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0); } return 0; }
  function iso(s) { var t = s ? Date.parse(s) / 1000 : 0; return t > 0 ? t : 0; }
  function sig(el, value) { var s = JSON.stringify(value) + "|" + P.busy + "|" + P.role; if (el.dataset.sig === s) return false; el.dataset.sig = s; return true; }
  function emptyRow(tb, text, cols) { var tr = P.el("tr"), td = P.cell(text, "empty"); td.colSpan = cols; tr.appendChild(td); tb.appendChild(tr); }
  function queues(tb, q, names, idle) {
    if (!sig(tb, q)) return; P.clear(tb); var any = false;
    Object.keys(names).forEach(function (k) {
      var s = (q || {})[k]; if (!s) return; var left = (s.active || 0) + (s.waiting || 0) + (s.delayed || 0);
      if (!left && !s.failed) return; any = true;
      P.kv(tb, names[k], (left ? n(left) + " to go" : "") + (s.failed ? (left ? ", " : "") + n(s.failed) + " failed" : "") + (s.paused ? " (paused in Immich)" : ""), true);
    });
    if (!any) emptyRow(tb, q ? idle : "Immich's queues can't be read right now.", 2);
  }

  // ---------------------------------------------------------------- Photo libraries
  var owners = "";
  P.register("libraries", {
    show: function () {
      P.api("action=folders").then(function (r) { var dl = $("lb-folders"); P.clear(dl); (r.folders || []).forEach(function (f) { var o = P.el("option"); o.value = f; dl.appendChild(o); }); }).catch(function () { /* suggestions only */ });
    },
    render: function (st) {
      var a = st.app || {}, s = a.stats || {}, libs = a.libraries || [], t = $("lb-tiles"), users = a.users || [];
      document.querySelectorAll(".im-link").forEach(function (x) { x.href = imUrl(st) || "#"; });
      P.clear(t); P.tile(t, n(s.photos), "photos"); P.tile(t, n(s.videos), "videos"); P.tile(t, s.usage != null ? P.bytes(s.usage) : "–", "of photos and videos"); P.tile(t, String(libs.length), libs.length === 1 ? "photo folder" : "photo folders");
      var tb = $("lb-list");
      if (sig(tb, libs)) {
        P.clear(tb);
        if (!libs.length) emptyRow(tb, "No photo folders yet — add one below.", 6);
        libs.forEach(function (l) {
          var who = P.el("div"), acts = P.el("span", null, "row");
          who.appendChild(P.el("b", l.name)); (l.paths || []).forEach(function (p) { who.appendChild(P.el("div", p, "path")); });
          if (l.missing) who.appendChild(P.chip("folder missing — its photos show as offline", "bad"));
          else if (l.slot == null) who.appendChild(P.el("div", "made in Immich itself", "muted small"));
          acts.appendChild(P.btn("Scan now", "", function () { P.act("libscan", { id: l.id }); }));
          acts.appendChild(P.btn("Remove", "danger", function () { P.act("libdel", { id: l.id }, "Remove the library " + l.name + " from Immich?\n\nIts photos leave the timeline, albums and search. The folder itself isn't touched — Immich only ever read it."); }));
          var tr = P.row(tb, [P.cell(who), l.owner, P.cell(n(l.photos), "n"), P.cell(n(l.videos), "n"), iso(l.refreshed) ? P.ago(iso(l.refreshed)) : "not yet", P.cell(acts, "n")]);
          if (l.missing) tr.className = "muted-row";
        });
      }
      var os = JSON.stringify(users.map(function (u) { return [u.id, u.name, u.email]; }));
      if (os !== owners) { owners = os; var sel = $("lb-owner"), keep = sel.value; P.clear(sel);
        users.forEach(function (u) { var o = P.el("option", (u.name || u.email) + (u.email === a.me ? " (you)" : "")); o.value = u.id; sel.appendChild(o); });
        if (keep) sel.value = keep; else { var me = users.filter(function (u) { return u.email === a.me; })[0]; if (me) sel.value = me.id; } }
      $("lb-add").disabled = $("lb-add").disabled || a.free_slots === 0;
      var up = (st.storage || {}).app || {}, ut = $("lb-upload");
      if (sig(ut, up)) { P.clear(ut);
        [["Originals from phones and the web", "upload"], ["Sorted by the storage template", "library"], ["Thumbnails", "thumbs"], ["Videos converted for playback", "encoded-video"], ["Profile pictures", "profile"], ["Immich's own database dumps", "backups"]]
          .forEach(function (p) { if (up[p[1]] != null && (up[p[1]] || p[1] !== "library")) P.kv(ut, p[0], P.mb(up[p[1]]), true); });
        if (!ut.firstChild) emptyRow(ut, "Sizes come in a moment.", 2); }
      queues($("lb-queues"), a.queues, QUEUES, "Nothing waiting — everything is read and has its thumbnails.");
    }
  });
  $("lb-add").onclick = function () { var d = $("lb-dir").value.trim(); P.act("libadd", { dir: d, owner: $("lb-owner").value }, "Show the photos in " + d + " in Immich? It reads the folder now; it never changes it.").then(function () { $("lb-dir").value = ""; }); };
  $("lb-scan-all").onclick = function () { P.act("libscan", {}); };

  // ---------------------------------------------------------------- Machine learning
  P.register("ml", {
    render: function (st) {
      var a = st.app || {}, m = a.ml || {}, mem = a.memory || {}, c = mem.containers || {};
      var chip = $("ml-chip"); P.clear(chip);
      chip.appendChild(m.on ? (m.state === "running" ? P.chip("on", "ok") : P.chip("on — " + (m.state || "starting"), "warn")) : P.chip("off", ""));
      $("ml-state").textContent = m.on
        ? "On. Immich analyses each new photo for smart search and faces" + (c["machine-learning"] != null ? "; the container uses " + c["machine-learning"] + " MB right now (models load while it works and leave memory after five idle minutes)." : ".")
        : "Off. Its container isn't running; smart search and face recognition are off. Search still finds photos by date, place, camera and file name.";
      var b = $("ml-btn"); P.clear(b);
      b.appendChild(m.on ? P.btn("Turn off", "", function () { P.act("ml", { on: 0 }, "Turn machine learning off?\n\nSmart search and face recognition stop; what they've found so far stays. Its memory is freed at once."); })
                         : P.btn("Turn on", "primary", function () { P.act("ml", { on: 1 }, "Turn machine learning on?\n\nThe first time downloads its image and models (about 2 GB), then Immich analyses the photos it already has — on a big library that takes hours, and uses 1–2 GB of memory while it works."); }));
      var ft = $("ml-features");
      if (sig(ft, m)) { P.clear(ft);
        [["Smart search — by what's in a photo", m.smart_search], ["Face recognition and people", m.faces], ["Duplicate detection", m.duplicates], ["Text in photos (OCR)", m.ocr]]
          .forEach(function (f) { P.kv(ft, f[0], f[1] ? P.chip("on", "ok") : P.chip("off", "")); }); }
      var mt = $("ml-mem");
      if (sig(mt, mem)) { P.clear(mt); var used = 0;
        [["Immich server", "server"], ["Machine learning", "machine-learning"], ["Database (Postgres)", "database"], ["Cache (Valkey)", "redis"]].forEach(function (p) {
          if (c[p[1]] == null) { if (p[1] === "machine-learning") P.kv(mt, p[0], "not running", true); return; } used += c[p[1]]; P.kv(mt, p[0], c[p[1]] + " MB", true); });
        if (mem.total_mb) { var bar = P.el("div", null, "bar-mem"), fill = P.el("i"); fill.style.width = Math.min(100, Math.round(100 * (mem.total_mb - (mem.available_mb || 0)) / mem.total_mb)) + "%"; bar.appendChild(fill);
          P.row(mt, [P.cell("This Synology", "k"), P.cell(bar)]); P.kv(mt, "", P.mb(mem.available_mb) + " free of " + P.mb(mem.total_mb), true); }
        $("ml-mem-note").textContent = "Immich uses " + used + " MB in all right now. Immich suggests 6 GB of memory for the whole Synology with machine learning on; with 4 GB, run it without."; }
      queues($("ml-queues"), a.queues, ML_QUEUES, m.on ? "Nothing waiting — every photo has been analysed." : "Nothing to analyse while machine learning is off.");
    }
  });

  // ---------------------------------------------------------------- Users
  P.register("users", {
    render: function (st) {
      var a = st.app || {}, users = a.users || [], tb = $("users");
      $("us-api").hidden = a.api_ok !== false;
      if (!sig(tb, users)) return; P.clear(tb);
      if (!users.length) emptyRow(tb, a.api_ok === false ? "Can't read Immich's users right now." : "No users yet.", 5);
      users.forEach(function (u) {
        var who = P.el("div"); who.appendChild(P.el("b", u.name || u.email)); who.appendChild(P.el("div", u.email + (u.email === a.me ? " · you" : ""), "muted small"));
        if (u.change) who.appendChild(P.el("div", "chooses a new password at the next sign-in", "muted small"));
        if (u.status && u.status !== "active") who.appendChild(P.chip(u.status, "warn"));
        P.row(tb, [P.cell(who), u.admin ? P.chip("administrator", "ok") : "user", P.cell(n(u.photos), "n"), P.cell(n(u.videos), "n"), P.cell(P.bytes(u.usage || 0), "n")]);
      });
    }
  });
  P.register("secretNote", function (s) { return "Use it to sign in to Immich — on the web and in the phone app — then keep it in a password manager."; });
  $("nu-add").onclick = function () { P.act("useradd", { email: $("nu-email").value.trim(), name: $("nu-name").value.trim(), role: $("nu-role").value }).then(function () { $("nu-email").value = ""; $("nu-name").value = ""; }); };
  $("us-reset").onclick = function () { P.act("adminpw", {}, "Reset the password of Immich's administrator? Everyone signed in as the administrator is signed out; the new password is shown once."); };

  // ---------------------------------------------------------------- Phones
  P.register("phones", {
    render: function (st) {
      var a = st.app || {};
      if (a.qr && $("ph-qr").dataset.qr !== a.qr) { $("ph-qr").src = "data:image/png;base64," + a.qr; $("ph-qr").dataset.qr = a.qr; }
      $("ph-url").textContent = a.url || "";
      $("ph-reach").textContent = /^https?:\/\/(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|[^/]*\.local\b)/.test(a.url || "")
        ? "An address on your own network: phones back up while they're at home. To back up from anywhere, give Immich an address reachable from outside on the Site address tab — the QR code and this address follow it."
        : "Phones can reach this from anywhere it resolves.";
    }
  });

  // ---------------------------------------------------------------- Overview, Updates, Storage
  P.register("overview", { tiles: function (t, st) { var s = (st.app || {}).stats || {}; P.tile(t, n(s.photos), "photos"); P.tile(t, n(s.videos), "videos"); } });
  P.register("updates", {
    render: function (st) {
      var a = st.app || {}, box = $("upd-app"), pin = a.pin || "", latest = a.latest || "";
      P.clear(box);
      box.appendChild(P.el("p", "Installed: Immich " + (st.version ? "v" + st.version : pin) + " — the release this package pins."));
      var newer = latest && pin && vcmp(latest, pin) > 0;
      if (newer) { var p1 = P.el("p", "Immich " + latest + " is out. ", "small"), l = P.el("a", "What's new"); l.href = "https://github.com/immich-app/immich/releases/tag/" + latest; l.target = "_blank"; l.rel = "noopener"; p1.appendChild(l); box.appendChild(p1); }
      box.appendChild(P.el("p", "Immich moves fast, and some releases change the database. So this package runs one release it has been tried with, and moves to a newer Immich only with a package update (below) — which backs up the database first, before the new version touches it." + (latest && !newer ? " This is the newest Immich." : ""), "muted small"));
      if (a.moved_from) box.appendChild(P.el("p", "Moved here from Immich " + a.moved_from + "; the database as it was is in the backup marked preupdate.", "muted small"));
    }
  });
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "The photos folder (immich shared folder)")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Originals (upload)", "upload"], ["Originals, sorted by the storage template (library)", "library"], ["Thumbnails", "thumbs"], ["Converted videos", "encoded-video"], ["Profile pictures", "profile"], ["Immich's own database dumps", "backups"]].forEach(function (p) { if (app[p[1]] != null) P.kv(tb, p[0], P.mb(app[p[1]]), true); });
    c.appendChild(P.el("p", "The volumes above hold the database (db) and machine learning's models (models). Photo folders you added stay where they are.", "muted small")).style.padding = "0 16px"; box.appendChild(c);
  } });
})(window.Panel);
