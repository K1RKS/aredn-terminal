(function () {
  "use strict";

  const statusEl = document.getElementById("status");
  const disconnectBtn = document.getElementById("btn-disconnect");
  const roleBtn = document.getElementById("btn-role");
  const targetSelect = document.getElementById("target-select");
  const term = new Terminal({
    cursorBlink: true,
    // PTY (socat) already emits CRLF; do not convert again.
    convertEol: false,
    fontSize: 14,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    theme: {
      background: "#0d1117",
      foreground: "#e6edf3",
      cursor: "#58a6ff",
      selectionBackground: "#264f78"
    }
  });
  const fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById("terminal"));
  fitAddon.fit();

  let cid = null;
  let role = null;
  let pollTimer = null;
  let pingTimer = null;
  let starting = false;
  let currentTarget = "local";
  let ignoreTargetChange = false;

  function setStatus(text) {
    if (statusEl) {
      statusEl.textContent = text;
    }
  }

  function b64encode(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }

  function b64decode(str) {
    try {
      return decodeURIComponent(escape(atob(str)));
    } catch (e) {
      try {
        return atob(str);
      } catch (e2) {
        return "";
      }
    }
  }

  function selectedTarget() {
    if (!targetSelect) {
      return "local";
    }
    return targetSelect.value || "local";
  }

  async function api(op, opts) {
    opts = opts || {};
    const params = new URLSearchParams();
    params.set("op", op);
    if (opts.cid) {
      params.set("cid", opts.cid);
    }
    if (opts.target) {
      params.set("target", opts.target);
    }
    if (opts.dataB64) {
      params.set("data", opts.dataB64);
    }
    const url = "/cgi-bin/terminal-api?" + params.toString();
    const init = {
      method: opts.method || (opts.dataB64 ? "POST" : "GET"),
      credentials: "same-origin",
      cache: "no-store"
    };
    if (opts.body != null) {
      init.method = "POST";
      init.headers = { "Content-Type": "application/x-www-form-urlencoded; charset=utf-8" };
      init.body = opts.body;
    }
    const res = await fetch(url, init);
    const text = await res.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch (e) {
      const err = new Error("bad_json HTTP " + res.status);
      err.status = res.status;
      err.payload = { error: "bad_json", body: text.slice(0, 120) };
      throw err;
    }
    if (!res.ok) {
      const err = new Error((json && json.message) || (json && json.error) || ("HTTP " + res.status));
      err.status = res.status;
      err.payload = json;
      throw err;
    }
    return json;
  }

  function stopPolling() {
    if (pollTimer) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
  }

  function applyRole(nextRole) {
    role = nextRole || role;
    const isPrimary = role === "primary";
    term.options.disableStdin = !isPrimary;
    term.options.cursorBlink = isPrimary;
    if (roleBtn) {
      roleBtn.disabled = !cid;
      roleBtn.textContent = isPrimary ? "Primary" : "Viewer";
      roleBtn.classList.toggle("role-primary", isPrimary);
      roleBtn.classList.toggle("role-viewer", !isPrimary);
      roleBtn.title = isPrimary
        ? "You control keyboard input"
        : "Read-only — click to take control";
    }
    if (cid) {
      setStatus((isPrimary ? "primary" : "viewer") + " (" + cid + ")");
    }
  }

  function setConnectedUi(connected) {
    if (disconnectBtn) {
      disconnectBtn.disabled = !connected;
    }
    if (roleBtn && !connected) {
      roleBtn.disabled = true;
      roleBtn.textContent = "Viewer";
      roleBtn.classList.remove("role-primary");
      roleBtn.classList.add("role-viewer");
    }
  }

  function populateTargets(payload) {
    if (!targetSelect) {
      return;
    }
    const nodename = (payload && payload.nodename) || "local";
    const neighbors = (payload && payload.neighbors) || [];
    const keep = selectedTarget();

    ignoreTargetChange = true;
    targetSelect.innerHTML = "";

    const localOpt = document.createElement("option");
    localOpt.value = "local";
    localOpt.textContent = nodename + " localnode";
    targetSelect.appendChild(localOpt);

    const sep = document.createElement("option");
    sep.disabled = true;
    sep.value = "";
    sep.textContent = "-----------";
    targetSelect.appendChild(sep);

    for (let i = 0; i < neighbors.length; i++) {
      const n = neighbors[i];
      if (!n || !n.mac) {
        continue;
      }
      const opt = document.createElement("option");
      opt.value = "mac:" + n.mac;
      opt.textContent = n.mac + " telnet";
      if (n.ipv6) {
        opt.title = n.ipv6 + "%br-dtdlink";
      }
      targetSelect.appendChild(opt);
    }

    if (keep && Array.prototype.some.call(targetSelect.options, function (o) {
      return o.value === keep && !o.disabled;
    })) {
      targetSelect.value = keep;
    } else {
      targetSelect.value = "local";
    }
    ignoreTargetChange = false;
  }

  async function loadNeighbors() {
    try {
      const r = await api("neighbors");
      populateTargets(r);
    } catch (e) {
      populateTargets({ nodename: "local", neighbors: [] });
      setStatus("neighbors unavailable");
    }
  }

  async function pollOnce() {
    if (!cid) {
      return;
    }
    try {
      const r = await api("read", { cid: cid });
      if (r.role && r.role !== role) {
        applyRole(r.role);
      }
      if (r.data) {
        term.write(b64decode(r.data));
      }
      pollTimer = setTimeout(pollOnce, 120);
    } catch (e) {
      if (e.status === 410) {
        cid = null;
        role = null;
        stopPolling();
        setConnectedUi(false);
        term.options.disableStdin = true;
        setStatus("session ended");
      } else {
        setStatus("read error: " + e.message);
        pollTimer = setTimeout(pollOnce, 1000);
      }
    }
  }

  async function disconnectSession() {
    stopPolling();
    const old = cid;
    cid = null;
    role = null;
    setConnectedUi(false);
    setStatus("disconnecting…");
    if (old) {
      try {
        await api("leave", { cid: old, method: "POST" });
      } catch (e) { /* ignore */ }
    }
    location.replace("/a/status");
  }

  async function joinSession(target) {
    if (starting) {
      return;
    }
    starting = true;
    stopPolling();
    target = target || selectedTarget() || "local";
    currentTarget = target;
    setStatus("joining…");
    try {
      if (cid) {
        try {
          await api("leave", { cid: cid, method: "POST" });
        } catch (e) { /* ignore */ }
        cid = null;
        role = null;
      }
      term.reset();
      const r = await api("join", { method: "POST", target: target });
      cid = r.cid;
      if (r.target) {
        currentTarget = r.target;
        if (targetSelect && targetSelect.value !== r.target) {
          ignoreTargetChange = true;
          if (Array.prototype.some.call(targetSelect.options, function (o) {
            return o.value === r.target && !o.disabled;
          })) {
            targetSelect.value = r.target;
          }
          ignoreTargetChange = false;
        }
      }
      applyRole(r.role || "viewer");
      setConnectedUi(true);
      pollOnce();
      pingTimer = setInterval(function () {
        if (!cid) {
          return;
        }
        api("ping", { cid: cid, method: "POST" })
          .then(function (p) {
            if (p.role && p.role !== role) {
              applyRole(p.role);
            }
          })
          .catch(function () {});
      }, 15000);
    } catch (e) {
      cid = null;
      role = null;
      setConnectedUi(false);
      term.options.disableStdin = true;
      setStatus("failed: " + e.message);
    } finally {
      starting = false;
    }
  }

  async function onTargetChange() {
    if (ignoreTargetChange || starting) {
      return;
    }
    const next = selectedTarget();
    if (!next || next === currentTarget) {
      return;
    }
    await joinSession(next);
  }

  async function takeControl() {
    if (!cid || role === "primary") {
      return;
    }
    try {
      const r = await api("takeover", { cid: cid, method: "POST" });
      applyRole(r.role || "primary");
    } catch (e) {
      setStatus("takeover failed: " + e.message);
    }
  }

  term.onData(function (data) {
    if (!cid || role !== "primary") {
      return;
    }
    // Keep CR from xterm (PTY line discipline); only normalize CRLF pairs.
    const normalized = data.replace(/\r\n/g, "\r");
    api("write", { cid: cid, method: "POST", dataB64: b64encode(normalized) }).catch(function (e) {
      if (e.status === 403) {
        applyRole("viewer");
        setStatus("viewer (control taken)");
      } else {
        setStatus("write error: " + e.message);
      }
    });
  });

  window.addEventListener("resize", function () {
    fitAddon.fit();
  });

  window.addEventListener("beforeunload", function () {
    if (!cid) {
      return;
    }
    const url = "/cgi-bin/terminal-api?op=leave&cid=" + encodeURIComponent(cid);
    if (navigator.sendBeacon) {
      navigator.sendBeacon(url);
    }
  });

  if (disconnectBtn) {
    disconnectBtn.addEventListener("click", disconnectSession);
  }
  if (roleBtn) {
    roleBtn.addEventListener("click", takeControl);
  }
  if (targetSelect) {
    targetSelect.addEventListener("change", onTargetChange);
  }

  setConnectedUi(false);
  term.options.disableStdin = true;
  loadNeighbors().then(function () {
    joinSession(selectedTarget());
  });
})();
