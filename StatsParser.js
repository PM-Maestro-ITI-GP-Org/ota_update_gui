.pragma library

/* Parse a "size" token like "512M", "128K", "1.5G", "1852MB" or plain bytes. */
function parseSize(s) {
    if (!s) return null
    s = s.trim()
    var m = s.match(/^([\d.]+)\s*([KMGT]?)(B?)$/i)
    if (!m) return null
    var v = parseFloat(m[1])
    var u = m[2].toUpperCase()
    if (u === "K") v *= 1024
    else if (u === "M") v *= 1024 * 1024
    else if (u === "G") v *= 1024 * 1024 * 1024
    else if (u === "T") v *= 1024 * 1024 * 1024 * 1024
    return v
}

/* Parse a pidin proc TIME field ("0:00:01.200" or "1:02:03") into ms. */
function parseTimeMs(s) {
    if (!s) return null
    var m = s.match(/^(\d+):(\d+):(\d+)(?:\.(\d+))?$/)
    if (m) {
        var ms = (+m[1]) * 3600000 + (+m[2]) * 60000 + (+m[3]) * 1000
        if (m[4]) ms += +(("0." + m[4]) * 1000).toFixed(3)
        return ms
    }
    m = s.match(/^(\d+):(\d+)(?:\.(\d+))?$/)
    if (m) {
        var m2 = (+m[1]) * 60000 + (+m[2]) * 1000
        if (m[3]) m2 += +(("0." + m[3]) * 1000).toFixed(3)
        return m2
    }
    return null
}

function fmtBytes(b) {
    if (b === null || b === undefined || b < 0) return "\u2013"
    if (b < 1024) return Math.round(b) + " B"
    if (b < 1024 * 1024) return (b / 1024).toFixed(0) + " KB"
    if (b < 1024 * 1024 * 1024) return (b / (1024 * 1024)).toFixed(1) + " MB"
    return (b / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function fmtUptime(ms) {
    if (ms === null || ms === undefined || ms < 0) return "\u2013"
    var s = Math.floor(ms / 1000)
    var d = Math.floor(s / 86400)
    s -= d * 86400
    var h = Math.floor(s / 3600)
    s -= h * 3600
    var mi = Math.floor(s / 60)
    if (d > 0) return d + "d " + h + "h " + mi + "m"
    if (h > 0) return h + "h " + mi + "m " + s + "s"
    return mi + "m " + s + "s"
}

/*
 * Parse one "pidin" thread-table row:
 *   " 20483   1 bin/slogger2  10r RECEIVE  1076K 340K 512K/512K"
 *   (pid tid name prio STATE code data stack)
 * Aggregates per-process mem (code+data of the first thread) and counts
 * busy (RUNNING/READY) threads for the CPU-busy estimate.
 */
function parseThreadRow(t, agg) {
    var m = t.match(/^\s*(\d+)\s+(\d+)\s+(.+?)\s+([\da-f]+[ir]?)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+\/\S+)\s*$/)
    if (!m) return
    var pid = m[1]
    var state = m[5].toUpperCase()
    var code = parseSize(m[6])
    var data = parseSize(m[7])
    var rec = agg.procs[pid]
    if (!rec) {
        rec = agg.procs[pid] = {
            name: m[3],
            memBytes: (code !== null && data !== null) ? code + data : null,
            cpuMs: null
        }
    }
    agg.threads++
    if (state === "RUNNING" || state === "READY")
        agg.busyThreads++
}

/*
 * Parse the raw output of the STATS_CMD composite command.
 * Sections: ###HOSTNAME ###KERNEL ###UPTIME ###UPTIMESEC ###CPUINFO ###CPUUSE ###MEM ###PROC ###END
 * Returns { hostname, kernel, load[], uptimeMs, cpus, threads,
 *           ram { total, free, used }, cpuBusyPct,
 *           procs [ {pid, cpuMs, memBytes, name} ] }
 */
function parseSnapshot(raw) {
    var snap = {
        hostname: "", kernel: "", load: [], uptimeMs: null,
        cpus: 0, threads: -1,
        ram: { total: null, free: null, used: null },
        cpuBusyPct: null,
        idlePcts: [],
        procs: []
    }
    if (!raw) return snap

    var agg = { procs: {}, threads: 0, busyThreads: 0 }
    var section = ""
    var rawLines = raw.split("\n")
    var lines = []
    for (var i = 0; i < rawLines.length; i++) {
        var l = rawLines[i].replace(/\r$/, "").replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "")
        var glued = l.match(/^(.*?)###([A-Z]+)$/)
        if (glued && glued[1].trim() !== "") {
            lines.push(glued[1])
            lines.push("###" + glued[2])
        } else {
            lines.push(l)
        }
    }

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "")
        var marker = line.match(/^###([A-Z]+)$/)
        if (marker) { section = marker[1]; continue }
        var t = line.trim()
        if (t === "" && section !== "PROC") continue

        if (section === "HOSTNAME") {
            if (snap.hostname === "" && t !== "") snap.hostname = t
        } else if (section === "KERNEL") {
            if (snap.kernel === "" && t !== "") snap.kernel = t
        } else if (section === "UPTIME") {
            var lm = t.match(/load\s+averages?:?\s*([\d.]+)?(?:,\s*([\d.]+))?(?:,\s*([\d.]+))?/i)
            if (lm && (lm[1] !== undefined || lm[2] !== undefined || lm[3] !== undefined)) {
                var loads = []
                for (var k = 1; k <= 3; k++)
                    if (lm[k] !== undefined) loads.push(parseFloat(lm[k]))
                snap.load = loads
            }
            var um = t.match(/up\s+(\d+)\s+day[s]?,\s*(\d+):(\d+)/i)
            if (um)
                snap.uptimeMs = (+um[1]) * 86400000 + (+um[2]) * 3600000 + (+um[3]) * 60000
        } else if (section === "UPTIMESEC") {
            var fm = t.match(/^([\d.]+)/)
            if (fm && snap.uptimeMs === null) snap.uptimeMs = Math.round(parseFloat(fm[1]) * 1000)
        } else if (section === "CPUINFO") {
            if (/^Processor\d/i.test(t)) snap.cpus++
            var tm = t.match(/threads?\s*[:=]\s*(\d+)/i)
            if (tm) snap.threads = +tm[1]
            /* QNX 8 pidin info: FreeMem:1852MB/2048MB — reliable RAM source. */
            var fm = t.match(/FreeMem:\s*([\d.]+[KMGT]?B?)\s*\/\s*([\d.]+[KMGT]?B?)/i)
            if (fm && snap.ram.total === null) {
                snap.ram.free = parseSize(fm[1])
                snap.ram.total = parseSize(fm[2])
                snap.ram.used = snap.ram.total - snap.ram.free
            }
            var lm2 = t.match(/load\s+averages?:?\s*([\d.]+)(?:,\s*([\d.]+))?(?:,\s*([\d.]+))?/i)
            if (lm2 && (lm2[1] !== undefined || lm2[2] !== undefined || lm2[3] !== undefined)) {
                var loads2 = []
                for (var k2 = 1; k2 <= 3; k2++)
                    if (lm2[k2] !== undefined) loads2.push(parseFloat(lm2[k2]))
                if (loads2.length > 0) snap.load = loads2
            }
            var um2 = t.match(/Uptime:\s*(\d+)\s+day[s]?,\s*(\d+):(\d+)(?::(\d+))?/i)
            if (um2 && snap.uptimeMs === null)
                snap.uptimeMs = (+um2[1]) * 86400000 + (+um2[2]) * 3600000 +
                                (+um2[3]) * 60000 + (um2[4] ? (+um2[4]) * 1000 : 0)
        } else if (section === "CPUUSE") {
            /* pidin cpu: per-CPU idle% lines -> busy% = 100 - avg(idle). */
            var im = t.match(/idle\s*[:=]?\s*([\d.]+)%/i)
            if (im) snap.idlePcts.push(parseFloat(im[1]))
        } else if (section === "MEM") {
            var mt = t.match(/total\s+([\d.]+[KMG]?B?)\b/i)
            if (mt) snap.ram.total = parseSize(mt[1])
            var mf = t.match(/free\s+([\d.]+[KMG]?B?)\b/i)
            if (mf) snap.ram.free = parseSize(mf[1])
            var mu = t.match(/used\s+([\d.]+[KMG]?B?)\b/i)
            if (mu) snap.ram.used = parseSize(mu[1])
            if (snap.ram.total !== null && snap.ram.free !== null)
                snap.ram.used = snap.ram.total - snap.ram.free
            else if (snap.ram.total === null && snap.ram.used !== null && snap.ram.free !== null)
                snap.ram.total = snap.ram.used + snap.ram.free

            /* QNX 8: "pidin mem" prints the same thread table as plain
               "pidin". Parse it as a process listing too. */
            parseThreadRow(t, agg)
        } else if (section === "PROC") {
            /* top -b output: "PID TID PRI STATE HH:MM:SS CPU COMMAND"
               Also handles "Memory:", "Idle:" and "CPU X:" lines from top,
               plus plain pidin rows (fallback).
               ps -A: "PID TTY TIME CMD" is also detected by TIME-token scan. */
            var toks = t.split(/\s+/)
            if (toks.length < 3) continue

            /* top Memory: line — fallback RAM source. */
            var mm = t.match(/Memory:\s*([\d.]+[KMGT]?B?)\s+\S+\s*,\s*([\d.]+[KMGT]?B?)\s+(avail|free)/i)
            if (mm && snap.ram.total === null) {
                snap.ram.total = parseSize(mm[1])
                snap.ram.free = parseSize(mm[2])
                snap.ram.used = snap.ram.total - snap.ram.free
                continue
            }

            /* top Idle: block — per-CPU idle% -> busy%. */
            var im = t.match(/CPU\s+\d+:\s+([\d.]+)%/i)
            if (im) { snap.idlePcts.push(parseFloat(im[1])); continue }

            var pid = toks[0]
            if (!/^\d+$/.test(pid)) continue
            var cpuMs = null, ti = -1
            for (var x = 1; x < toks.length - 1; x++) {
                var tt = parseTimeMs(toks[x])
                if (tt !== null) { cpuMs = tt; ti = x; break }
            }
            if (ti >= 0) {
                var cmdStart = ti + 1
                var cpuPct = null
                while (cmdStart < toks.length && /^\d+(?:\.\d+)?%$/.test(toks[cmdStart])) {
                    if (cpuPct === null) cpuPct = parseFloat(toks[cmdStart])
                    cmdStart++
                }
                var procName = toks.slice(cmdStart).join(" ")
                if (!procName) continue
                var mb = (agg.procs[pid] && agg.procs[pid].memBytes !== null) ? agg.procs[pid].memBytes : null
                snap.procs.push({ pid: +pid, cpuMs: cpuMs, cpuPct: cpuPct, memBytes: mb, name: procName })
            } else {
                parseThreadRow(t, agg)
            }
        }
    }
    if (snap.idlePcts.length > 0) {
        var sum = 0
        for (var q = 0; q < snap.idlePcts.length; q++) sum += snap.idlePcts[q]
        snap.cpuBusyPct = 100 - sum / snap.idlePcts.length
    } else if (agg.threads > 0) {
        /* No pidin cpu on QNX 8: estimate busy from thread states. */
        snap.cpuBusyPct = agg.busyThreads / agg.threads * 100
    }
    /* Merge per PID: top provides thread-level data — aggregate threads per
       process (sum cpu time, max cpu%). Then merge pidin mem (agg.procs)
       info into those entries, and add pidin-only processes. */
    var procByPid = {}
    for (var k = 0; k < snap.procs.length; k++) {
        var sp = snap.procs[k]
        var key = "" + sp.pid
        var x = procByPid[key]
        if (x) {
            x.cpuMs = (x.cpuMs !== null && sp.cpuMs !== null) ? x.cpuMs + sp.cpuMs : (x.cpuMs || sp.cpuMs)
            if (sp.cpuPct !== null && sp.cpuPct !== undefined)
                x.cpuPct = (x.cpuPct !== null && x.cpuPct !== undefined) ? Math.max(x.cpuPct, sp.cpuPct) : sp.cpuPct
        } else {
            procByPid[key] = { pid: sp.pid, name: sp.name,
                               cpuMs: sp.cpuMs, cpuPct: sp.cpuPct,
                               memBytes: sp.memBytes }
        }
    }
    for (var pidk in agg.procs) {
        var rec = agg.procs[pidk]
        var x = procByPid[pidk]
        if (x)
            x.memBytes = rec.memBytes
        else
            procByPid[pidk] = { pid: +pidk, name: rec.name, cpuMs: null, cpuPct: null, memBytes: rec.memBytes }
    }
    var procsSorted = []
    for (var pidkey in procByPid)
        procsSorted.push(procByPid[pidkey])
    procsSorted.sort(function (a, b) { return a.pid - b.pid })
    snap.procs = procsSorted
    return snap
}

/*
 * Combine a snapshot with the previous one to get CPU% deltas.
 * Returns { procs: [ {pid, name, cpu, memBytes} ] } sorted by cpu desc.
 * cpu is null when the process is new or no previous snapshot exists.
 */
function buildView(snap, prev, elapsedMs) {
    var prevMap = {}
    if (prev && prev.procs)
        for (var i = 0; i < prev.procs.length; i++)
            prevMap[prev.procs[i].pid] = prev.procs[i].cpuMs

    var out = []
    for (var j = 0; j < snap.procs.length; j++) {
        var pr = snap.procs[j]
        var cpu = null
        if (pr.cpuPct !== null && pr.cpuPct !== undefined)
            cpu = pr.cpuPct
        else if (prevMap[pr.pid] !== undefined && pr.cpuMs !== null &&
                 prevMap[pr.pid] !== null && elapsedMs > 0)
            cpu = (pr.cpuMs - prevMap[pr.pid]) / elapsedMs * 100
        if (cpu !== null && cpu < 0)
            cpu = 0
        out.push({ pid: pr.pid, name: pr.name, cpu: cpu, mem: pr.memBytes })
    }
    out.sort(function (a, b) {
        var ac = (a.cpu === null) ? -1 : a.cpu
        var bc = (b.cpu === null) ? -1 : b.cpu
        return bc - ac
    })
    return out
}
