/*
 * AREDN terminal session helpers: authV1, ash session I/O, apps-bar badges.
 * One shell, multiple browser clients (one primary writer + readonly viewers).
 */

import * as fs from "fs";
import * as configuration from "aredn.configuration";

export const SESSION_ROOT = "/tmp/aredn-terminal";
export const SHELL_DIR = "/tmp/aredn-terminal/active";
export const CLIENTS_DIR = "/tmp/aredn-terminal/active/clients";
export const BADGE_DIR = "/tmp/apps/terminal";
export const IDLE_SECS = 60;
export const AUTH_AGE = 315360000; // 10 years (match stock UI)
export const VIEWER_CATCHUP = 32768; // bytes of history for new viewers

const DAYS = [ "", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" ];
const MONTHS = [ "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" ];

let shadowKey = null;

export function initKey()
{
    if (!shadowKey) {
        const f = fs.open("/etc/shadow");
        if (f) {
            for (let l = f.read("line"); length(l); l = f.read("line")) {
                if (index(l, "root:") === 0) {
                    shadowKey = trim(l);
                    break;
                }
            }
            f.close();
        }
    }
    return shadowKey;
};

export function getCookieHeader()
{
    initKey();
    if (!shadowKey) {
        return null;
    }
    const time = clock();
    const gm = gmtime(time[0] + AUTH_AGE);
    const tm = `${DAYS[gm.wday]}, ${gm.mday} ${MONTHS[gm.mon]} ${gm.year} 00:00:00 GMT`;
    return `authV1=${b64enc(shadowKey)}; Path=/; Expires=${tm}; SameSite=Lax`;
};

export function clearCookieHeader()
{
    return `authV1=; Path=/; Max-Age=0;`;
};

export function cookieValue(env)
{
    const cookieheader = env.HTTP_COOKIE || "";
    if (!cookieheader) {
        return null;
    }
    const ca = split(cookieheader, ";");
    for (let i = 0; i < length(ca); i++) {
        const cookie = trim(ca[i]);
        if (index(cookie, "authV1=") === 0) {
            return substr(cookie, 7);
        }
    }
    return null;
};

export function isAuthenticated(env)
{
    initKey();
    if (!shadowKey) {
        return false;
    }
    const v = cookieValue(env);
    if (!v) {
        return false;
    }
    return shadowKey == b64dec(v);
};

export function authenticatePassword(password)
{
    initKey();
    if (!shadowKey) {
        return false;
    }
    const s = split(shadowKey, /[:$]/);
    const f = fs.popen(`exec /usr/bin/mkpasswd -m md5 -S '${s[3]}' ${configuration.shellEscape(replace(password, /[#'"]/g, ""))}`);
    if (!f) {
        return false;
    }
    const pwd = rtrim(f.read("all"));
    f.close();
    return index(shadowKey, `root:${pwd}:`) === 0;
};

export function ensureDir(path)
{
    if (!fs.stat(path)) {
        system(`mkdir -p '${path}'`);
    }
};

export function setBadge(busy)
{
    ensureDir(BADGE_DIR);
    if (busy) {
        fs.writefile(`${BADGE_DIR}/badge`, "BUSY");
        fs.writefile(`${BADGE_DIR}/badge-color`, "#c44c44");
    }
    else {
        system(`rm -f '${BADGE_DIR}/badge' '${BADGE_DIR}/badge-color'`);
    }
};

export function clearBadge()
{
    setBadge(false);
};

function shellAlive()
{
    const pid = trim(fs.readfile(`${SHELL_DIR}/pid`) || "");
    if (!pid || !match(pid, /^[0-9]+$/)) {
        return false;
    }
    return system(`kill -0 ${pid} 2>/dev/null`) === 0;
};

function newId()
{
    const t = clock();
    return sprintf("%08x%04x", t[0] & 0xffffffff, t[1] & 0xffff);
};

function clientDir(cid)
{
    return `${CLIENTS_DIR}/${cid}`;
};

function validId(id)
{
    return id && !match(id, /[^0-9a-f]/);
};

function readRole(cid)
{
    return trim(fs.readfile(`${clientDir(cid)}/role`) || "");
};

function writeRole(cid, role)
{
    fs.writefile(`${clientDir(cid)}/role`, role);
};

function touchClient(cid)
{
    fs.writefile(`${clientDir(cid)}/heartbeat`, `${clock()[0]}`);
};

function listClientIds()
{
    const out = [];
    const entries = fs.lsdir(CLIENTS_DIR);
    if (!entries) {
        return out;
    }
    for (let i = 0; i < length(entries); i++) {
        const name = entries[i];
        if (substr(name, 0, 1) !== "." && match(name, /^[0-9a-f]+$/)) {
            push(out, name);
        }
    }
    return out;
};

function clientOrder(cid)
{
    return int(trim(fs.readfile(`${clientDir(cid)}/order`) || "0"));
};

function sortedClients()
{
    const ids = listClientIds();
    // Insertion sort by order (small N).
    for (let i = 1; i < length(ids); i++) {
        const key = ids[i];
        const ko = clientOrder(key);
        let j = i - 1;
        while (j >= 0 && clientOrder(ids[j]) > ko) {
            ids[j + 1] = ids[j];
            j--;
        }
        ids[j + 1] = key;
    }
    return ids;
};

function nextOrder()
{
    const n = int(trim(fs.readfile(`${SHELL_DIR}/next_order`) || "0")) + 1;
    fs.writefile(`${SHELL_DIR}/next_order`, `${n}`);
    return n;
};

function removeClientFiles(cid)
{
    if (validId(cid)) {
        system(`rm -rf '${clientDir(cid)}'`);
    }
};

export function promotePrimary()
{
    const ids = sortedClients();
    if (length(ids) == 0) {
        return null;
    }
    let primary = null;
    for (let i = 0; i < length(ids); i++) {
        if (primary == null) {
            primary = ids[i];
            writeRole(ids[i], "primary");
        }
        else {
            writeRole(ids[i], "viewer");
        }
    }
    return primary;
};

function killShell()
{
    // Hard-kill every helper / leftover process from this package.
    system("ps w 2>/dev/null | grep aredn-terminal-session | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep '/bin/ash -l' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep 'telnet .*br-dtdlink' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep 'tail -f /tmp/aredn-terminal' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep 'socat PTY,link=/tmp/aredn-terminal' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    system("ps w 2>/dev/null | grep '/tmp/aredn-terminal/active/tty' | grep -v grep | while read pid rest; do kill -9 \"$pid\" 2>/dev/null; done");
    if (fs.stat(SHELL_DIR)) {
        const keys = [ "pid", "socat", "catpid", "tailpid", "wrapper" ];
        for (let i = 0; i < length(keys); i++) {
            const p = trim(fs.readfile(`${SHELL_DIR}/${keys[i]}`) || "");
            if (p && match(p, /^[0-9]+$/)) {
                system(`kill -9 ${p} 2>/dev/null`);
            }
        }
    }
    system(`rm -rf '${SESSION_ROOT}'`);
    clearBadge();
};

function normalizeMac(mac)
{
    return lc(trim(mac || ""));
};

function validMac(mac)
{
    return mac && match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/);
};

function validIpv6(ip)
{
    return ip && match(ip, /^[0-9a-fA-F:]+$/) && index(ip, ":") >= 0;
};

function isLinkLocal(ip)
{
    return index(lc(ip || ""), "fe80:") === 0;
};

/**
 * Parse br-dtdlink IPv6 neighbors into sorted [{ mac, ipv6 }, ...].
 * Prefer fe80:: when a MAC has multiple addresses.
 */
export function listDtdNeighbors()
{
    const byMac = {};
    const f = fs.popen("ip -6 neigh show dev br-dtdlink 2>/dev/null");
    if (f) {
        const text = f.read("all") || "";
        f.close();
        const lines = split(text, /\n/);
        for (let i = 0; i < length(lines); i++) {
            const line = trim(lines[i]);
            if (!line) {
                continue;
            }
            const m = match(line, /^([0-9a-fA-F:]+)\s+.*lladdr\s+([0-9a-fA-F:]+)/);
            if (!m) {
                continue;
            }
            const ipv6 = m[1];
            const mac = normalizeMac(m[2]);
            if (!validMac(mac) || !validIpv6(ipv6)) {
                continue;
            }
            const prev = byMac[mac];
            if (!prev || (!isLinkLocal(prev) && isLinkLocal(ipv6))) {
                byMac[mac] = ipv6;
            }
        }
    }

    const macs = [];
    for (let mac in byMac) {
        push(macs, mac);
    }
    // Insertion sort ascending by MAC.
    for (let i = 1; i < length(macs); i++) {
        const key = macs[i];
        let j = i - 1;
        while (j >= 0 && macs[j] > key) {
            macs[j + 1] = macs[j];
            j--;
        }
        macs[j + 1] = key;
    }

    const out = [];
    for (let i = 0; i < length(macs); i++) {
        push(out, { mac: macs[i], ipv6: byMac[macs[i]] });
    }
    return out;
};

export function getNodeName()
{
    let name = trim(configuration.getName() || "");
    return name !== "" ? name : "local";
};

export function neighborsPayload()
{
    return {
        ok: true,
        nodename: getNodeName(),
        neighbors: listDtdNeighbors()
    };
};

function currentTargetKey()
{
    return trim(fs.readfile(`${SHELL_DIR}/target`) || "local") || "local";
};

/**
 * Resolve UI target string to spawn args.
 * target: "local" | "mac:aa:bb:cc:dd:ee:ff"
 */
function resolveTarget(target)
{
    target = trim(target || "local");
    if (target === "" || target == "local") {
        return { mode: "local", key: "local" };
    }
    const m = match(target, /^mac:(.+)$/);
    if (!m) {
        return { error: "bad_target", message: "target must be local or mac:<addr>" };
    }
    const mac = normalizeMac(m[1]);
    if (!validMac(mac)) {
        return { error: "bad_target", message: "invalid MAC address" };
    }
    const neighbors = listDtdNeighbors();
    let ipv6 = null;
    for (let i = 0; i < length(neighbors); i++) {
        if (neighbors[i].mac == mac) {
            ipv6 = neighbors[i].ipv6;
            break;
        }
    }
    if (!ipv6 || !validIpv6(ipv6)) {
        return { error: "unknown_mac", message: "MAC not found on br-dtdlink" };
    }
    return { mode: "telnet", key: `mac:${mac}`, mac: mac, ipv6: ipv6 };
};

export function refreshBadge()
{
    if (shellAlive() && length(listClientIds()) > 0) {
        setBadge(true);
    }
    else {
        clearBadge();
    }
};

function spawnShell(resolved)
{
    // Always start from a clean process table / tmp tree.
    killShell();
    system("sleep 1");
    ensureDir(SESSION_ROOT);
    ensureDir(SHELL_DIR);
    ensureDir(CLIENTS_DIR);
    fs.writefile(`${SHELL_DIR}/next_order`, "0");
    fs.writefile(`${SHELL_DIR}/target`, resolved.key);
    if (resolved.mode == "telnet") {
        system(`setsid /usr/libexec/aredn-terminal-session '${SHELL_DIR}' telnet '${resolved.ipv6}' >/dev/null 2>&1 &`);
    }
    else {
        system(`setsid /usr/libexec/aredn-terminal-session '${SHELL_DIR}' local >/dev/null 2>&1 &`);
    }
    system("sleep 1");
    return shellAlive();
};

function createClient(role)
{
    const cid = newId();
    const dir = clientDir(cid);
    ensureDir(CLIENTS_DIR);
    ensureDir(dir);
    writeRole(cid, role);
    fs.writefile(`${dir}/order`, `${nextOrder()}`);
    touchClient(cid);

    const st = fs.stat(`${SHELL_DIR}/stdout`);
    let offset = 0;
    if (st && st.size > VIEWER_CATCHUP) {
        offset = st.size - VIEWER_CATCHUP;
    }
    // Primary joining a fresh shell starts at 0; viewers joining live get catch-up tail.
    if (role == "primary" && (!st || st.size == 0)) {
        offset = 0;
    }
    fs.writefile(`${dir}/offset`, `${offset}`);
    return cid;
};

export function cleanupStale()
{
    ensureDir(SESSION_ROOT);
    if (!fs.stat(SHELL_DIR)) {
        clearBadge();
        return;
    }
    if (!shellAlive()) {
        killShell();
        return;
    }

    const now = clock()[0];
    const ids = listClientIds();
    let primaryGone = false;
    for (let i = 0; i < length(ids); i++) {
        const cid = ids[i];
        const hb = int(trim(fs.readfile(`${clientDir(cid)}/heartbeat`) || "0"));
        if (hb > 0 && now - hb > IDLE_SECS) {
            if (readRole(cid) == "primary") {
                primaryGone = true;
            }
            removeClientFiles(cid);
        }
    }

    const left = listClientIds();
    if (length(left) == 0) {
        killShell();
        return;
    }

    let hasPrimary = false;
    for (let i = 0; i < length(left); i++) {
        if (readRole(left[i]) == "primary") {
            hasPrimary = true;
            break;
        }
    }
    if (!hasPrimary || primaryGone) {
        promotePrimary();
    }
    refreshBadge();
};

/**
 * Join existing session as viewer, or create session + join as primary.
 * target: "local" (default) or "mac:<addr>" — different target kills and respawns.
 */
export function joinSession(target)
{
    cleanupStale();

    const resolved = resolveTarget(target);
    if (resolved.error) {
        return resolved;
    }

    if (shellAlive()) {
        if (currentTargetKey() == resolved.key) {
            const cid = createClient("viewer");
            // Ensure someone is primary (e.g. after races).
            let hasPrimary = false;
            const ids = listClientIds();
            for (let i = 0; i < length(ids); i++) {
                if (readRole(ids[i]) == "primary") {
                    hasPrimary = true;
                    break;
                }
            }
            if (!hasPrimary) {
                promotePrimary();
            }
            refreshBadge();
            return { sid: "active", cid: cid, role: readRole(cid), target: resolved.key };
        }
        // Requested target differs from the live session — replace it.
        killShell();
    }

    system(`rm -rf '${SESSION_ROOT}'`);
    if (!spawnShell(resolved)) {
        system(`rm -rf '${SESSION_ROOT}'`);
        return { error: "spawn", message: "Failed to start shell session" };
    }
    const cid = createClient("primary");
    setBadge(true);
    return { sid: "active", cid: cid, role: "primary", target: resolved.key };
};

export function leaveClient(cid)
{
    cleanupStale();
    if (!validId(cid)) {
        return { error: "bad_request" };
    }
    if (!fs.stat(clientDir(cid))) {
        if (length(listClientIds()) == 0) {
            killShell();
        }
        else {
            refreshBadge();
        }
        return { ok: true };
    }

    const wasPrimary = readRole(cid) == "primary";
    removeClientFiles(cid);

    const left = listClientIds();
    if (length(left) == 0) {
        killShell();
        return { ok: true, closed: true };
    }
    if (wasPrimary) {
        promotePrimary();
    }
    refreshBadge();
    return { ok: true, closed: false };
};

/** Tear down entire shell (admin / last-resort). */
export function stopAll()
{
    killShell();
    return { ok: true };
};

export function takeover(cid)
{
    cleanupStale();
    if (!validId(cid) || !fs.stat(clientDir(cid))) {
        return { error: "gone" };
    }
    if (!shellAlive()) {
        return { error: "gone" };
    }
    touchClient(cid);
    const ids = listClientIds();
    for (let i = 0; i < length(ids); i++) {
        writeRole(ids[i], ids[i] == cid ? "primary" : "viewer");
    }
    return { ok: true, role: "primary", cid: cid, sid: "active" };
};

export function writeSession(cid, data)
{
    if (!validId(cid) || data == null) {
        return { error: "bad_request" };
    }
    if (!shellAlive() || !fs.stat(clientDir(cid))) {
        return { error: "gone" };
    }
    touchClient(cid);
    if (readRole(cid) != "primary") {
        return { error: "readonly", message: "Viewer mode — take control to type" };
    }
    // PTY expects CR from xterm for Enter; do not convert to LF.
    const f = fs.open(`${SHELL_DIR}/infile`, "a");
    if (!f) {
        return { error: "write" };
    }
    f.write(data);
    f.close();
    return { ok: true, role: "primary" };
};

export function readSession(cid)
{
    if (!validId(cid)) {
        return { error: "bad_request" };
    }
    if (!shellAlive() || !fs.stat(clientDir(cid))) {
        cleanupStale();
        return { error: "gone" };
    }
    touchClient(cid);
    const dir = clientDir(cid);
    const offset = int(trim(fs.readfile(`${dir}/offset`) || "0"));
    const f = fs.open(`${SHELL_DIR}/stdout`, "r");
    if (!f) {
        return { data: "", offset: offset, role: readRole(cid), cid: cid };
    }
    f.seek(offset);
    const chunk = f.read("all") || "";
    const st = fs.stat(`${SHELL_DIR}/stdout`);
    const newOffset = st ? st.size : offset + length(chunk);
    f.close();
    fs.writefile(`${dir}/offset`, `${newOffset}`);
    return {
        data: chunk,
        offset: newOffset,
        alive: true,
        role: readRole(cid),
        cid: cid,
        sid: "active"
    };
};

export function pingClient(cid)
{
    if (!validId(cid) || !fs.stat(clientDir(cid))) {
        return { error: "gone" };
    }
    touchClient(cid);
    return { ok: true, role: readRole(cid), cid: cid };
};

// Back-compat aliases used by older call sites during transition.
export function listSessions()
{
    return listClientIds();
};

export function stopSession(cid)
{
    return leaveClient(cid);
};

export function touchHeartbeat(cid)
{
    if (validId(cid) && fs.stat(clientDir(cid))) {
        touchClient(cid);
    }
};

export function readPostBody()
{
    const cl = int(getenv("CONTENT_LENGTH") || "0");
    if (cl <= 0) {
        return "";
    }
    const max = cl > 65536 ? 65536 : cl;
    // Prefer the CGI stdin fd; /dev/stdin is unreliable under some uhttpd setups.
    let f = fs.open("/proc/self/fd/0", "r");
    if (!f) {
        f = fs.open("/dev/stdin", "r");
    }
    if (!f) {
        return "";
    }
    const body = f.read(max) || "";
    f.close();
    return body;
};

// CGI ucode has no global urldecode; decode %XX and +.
export function urlDecode(s)
{
    if (s == null || s === "") {
        return "";
    }
    s = replace(`${s}`, /\+/g, " ");
    let out = "";
    for (let i = 0; i < length(s); ) {
        const ch = substr(s, i, 1);
        if (ch == "%" && i + 2 < length(s)) {
            out += chr(hex(substr(s, i + 1, 2)));
            i += 3;
        }
        else {
            out += ch;
            i++;
        }
    }
    return out;
};

export function parseQuery(q)
{
    const out = {};
    if (!q) {
        return out;
    }
    const parts = split(q, "&");
    for (let i = 0; i < length(parts); i++) {
        const kv = split(parts[i], "=");
        if (length(kv) >= 1 && kv[0] !== "") {
            out[kv[0]] = length(kv) > 1 ? urlDecode(kv[1]) : "";
        }
    }
    return out;
};

export function jsonEscape(s)
{
    s = replace(s, /\\/g, "\\\\");
    s = replace(s, /"/g, "\\\"");
    s = replace(s, /\n/g, "\\n");
    s = replace(s, /\r/g, "\\r");
    s = replace(s, /\t/g, "\\t");
    return s;
};
