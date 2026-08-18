.pragma library

/*
 * Decide whether a process row is one of our own stats-poll helpers
 * (the sh -c wrapper echoing the STATS_CMD, top/grep/head/ps pipeline
 * members) rather than a real application. They are real processes at
 * sampling time, but showing "sh -c echo '###HOSTNAME'; uname -n ..."
 * as a process name reads as corrupted data, so filter them out.
 */
function isStatsNoise(name) {
    if (!name) return false
    if (name.indexOf("###") >= 0) return true
    if (name.indexOf("sh -c ") === 0) return true
    var base = name
    var slash = name.lastIndexOf("/")
    if (slash >= 0) base = name.substring(slash + 1)
    switch (base) {
        case "head": case "top": case "grep": case "sh": case "ps": case "tail":
        case "head -n 400": case "top -b -n 1":
        /* "top -b -n 1" is only the Linux probe (piped to `grep -q COMMAND`
           to check the flag is accepted) -- the command that actually
           produces the captured table on a Linux guest is "top -b -n 2 -d 1"
           (see STATS_CMD in hms/main.c). That name was missing here, so on
           every poll the guest's own stats-gathering top showed up in its
           own process table as a row named "top -b -n 2 -d 1", indistinguishable
           from a real process. */
        case "top -b -n 2 -d 1":
        case "top -b -i 1 -z 100": case "grep -q COMMAND":
        case "ps aux": case "ps -A":
            return true
        default:
            return false
    }
}

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

/* Parse a `top`/`ps` RES or VSZ column value. Unlike parseSize(), a bare
   number here (no K/M/G letter) is understood as kibibytes -- that is the
   long-standing convention for those two columns specifically (procps top's
   RES/VIRT, busybox top's VSZ), unlike a generic size token which is bytes
   when unsuffixed. Treating it as raw bytes made every parsed process
   memory figure read about 1024x too small. */
function parseMemCol(s) {
    if (!s) return null
    var v = parseSize(s)
    if (v === null) return null
    if (/^[\d.]+$/.test(s.trim())) v *= 1024
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

/* QNX pidin times utime/stime come as cumulative CPU seconds, either plain
   seconds ("3.726") or a compact h:m form ("17m20s"). Returns ms. */
function parseUtime(s) {
    if (!s) return null
    var m = s.match(/^(\d+)m(\d+(?:\.\d+)?)s$/)
    if (m) return (+m[1]) * 60000 + (+m[2]) * 1000
    if (/^\d+(?:\.\d+)?$/.test(s)) return Math.round(parseFloat(s) * 1000)
    return parseTimeMs(s)
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
    if (!m) return false
    var pid = m[1]
    var state = m[5].toUpperCase()
    var code = parseSize(m[6])
    var data = parseSize(m[7])
    var rec = agg.procs[pid]
    if (!rec) {
        rec = agg.procs[pid] = {
            name: m[3],
            memBytes: (code !== null && data !== null) ? code + data : null,
            cpuMs: null,
            threadCount: 0,
            busyThreads: 0
        }
    }
    rec.threadCount++
    if (state === "RUNNING" || state === "READY")
        rec.busyThreads++
    agg.threads++
    if (state === "RUNNING" || state === "READY")
        agg.busyThreads++
    return true
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
        statBusy: null,
        busyboxBusy: null,
        procs: []
    }
    if (!raw) return snap

    var agg = { procs: {}, threads: 0, busyThreads: 0 }
    var commNames = {}
    var pidinCpu = {}
    var rssPids = {}
    var exeNames = {}
    var section = ""
    /* Column map for the current PROC block, built from its own header row
       (see below) so PID/CPU/MEM/COMMAND are read by name instead of by a
       guessed position -- guessed positions silently dropped any row whose
       top variant did not match the assumed shape, which is why the process
       list showed only a couple of rows instead of the system's whole list. */
    var procCols = null
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
        if (marker) { section = marker[1]; if (section === "PROC") procCols = null; continue }
        /* HMS appends the guest's configured RAM (qvmconf `ram`) as
           "###RAMCONF <bytes>" on a single line. */
        var rcInline = line.match(/^###RAMCONF\s+(\d+)$/)
        if (rcInline) {
            if (+rcInline[1] > 0) snap.ram.total = +rcInline[1]
            continue
        }
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
            /* "Processor0: ..." (QNX pidin info) or "processor : 0" (Linux
               /proc/cpuinfo) -- the old /^Processor\d/ never matched the
               Linux spelling, so a Linux guest always reported 0 CPUs. */
            if (/^processor\s*:?\s*\d+/i.test(t)) snap.cpus++
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
            /* QNX pidin times: per-process cumulative CPU time rows
               "  pid name sid start utime stime cutime cstime" (utime in
               seconds or "17m20s"). This is the ONLY source on QNX that has
               a CPU figure for EVERY process -- top -z caps its thread list
               at 100, so a quiet process never appears there at all. Storing
               utime+stime per PID lets buildView turn the delta between two
               polls into a real per-process CPU%, and makes the process
               column sum to roughly the same number the busy% tile shows. */
            var pt = t.match(/^\s*(\d+)\s+(\S+)\s+\d+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(\S+)\s+\S+\s+\S+\s*$/)
            if (pt) {
                var u = parseUtime(pt[2])
                var s2 = parseUtime(pt[3])
                if (u !== null || s2 !== null)
                    pidinCpu[pt[1]] = (u === null ? 0 : u) + (s2 === null ? 0 : s2)
            }
            /* Linux /proc/stat: "cpu  user nice system idle iowait irq softirq
               steal ..." -- busy = total - idle over total. This is a
               LIFETIME average from a single snapshot, so on a guest that was
               idle for hours it stays near 0 even while a process hammers the
               CPU; busybox top's CPU: summary (parsed in ###PROC) is the
               instantaneous figure and overrides this. */
            var sm = t.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
            if (sm) {
                var idle = +sm[4]
                var total = +sm[1] + +sm[2] + +sm[3] + idle
                var extra = t.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
                if (extra) total += +extra[5] + +extra[6] + +extra[7] + +extra[8]
                if (total > 0)
                    snap.statBusy = 100 - idle / total * 100
            }
        } else if (section === "NAME") {
            /* busybox grep over /proc/PID/comm: "path:name". The kernel's
               comm is the FULL thread name (e.g. pool_workqueue_release);
               busybox top/ps only ever show a 15-char truncation of it
               ([pool_workqueue_]), which read as corrupted names. */
            var nm = t.match(/^\/proc\/(\d+)\/comm:\s*(.+?)\s*$/)
            if (nm) commNames[nm[1]] = nm[2]
        } else if (section === "EXE") {
            /* busybox ls -l over /proc/PID/exe: "path -> /usr/bin/foo".
               The exe basename is the FULL program name -- the kernel
               truncates comm to 15 chars (systemd-timesyncd shows up as
               systemd-timesyn). Kernel threads have no exe (broken symlink,
               no target) and are skipped. Only the target's basename is
               kept; the raw target is checked later against comm so that
               busybox applets (klogd -> busybox.nosuid) do not get their
               comm replaced with the wrong binary name. */
            var em = t.match(/^.*?\/proc\/(\d+)\/exe\s*->\s*(.+)$/)
            if (em) {
                var target = em[2].trim()
                var slash = target.lastIndexOf("/")
                exeNames[em[1]] = slash >= 0 ? target.substring(slash + 1) : target
            }
        } else if (section === "THREADS") {
            /* Linux thread count: every kernel task appears as
               /proc/PID/task/TID, so the count of those dirs is the system
               thread total. QNX has no task dirs and already got its count
               from pidin info, so a 0/absent value is ignored. */
            var thm = t.match(/^(\d+)$/)
            if (thm && +thm[1] > 0 && snap.threads < 0) snap.threads = +thm[1]
        } else if (section === "RSS") {
            /* busybox statm dump "path:size resident ..." in pages. RSS is
               the physical RAM per process; busybox top only offers VSZ
               (virtual), whose sum can be many times the real usage, which
               is why a Linux guest's process RAM column never added up. */
            var rm = t.match(/^\/proc\/(\d+)\/statm:\s*\d+\s+(\d+)/)
            if (rm) rssPids[rm[1]] = +rm[2] * 4096
        } else if (section === "MEM") {
            var mt = t.match(/total\s+([\d.]+[KMG]?B?)\b/i)
            if (mt) snap.ram.total = parseSize(mt[1])
            var mf = t.match(/free\s+([\d.]+[KMG]?B?)\b/i)
            if (mf) snap.ram.free = parseSize(mf[1])
            var mu = t.match(/used\s+([\d.]+[KMG]?B?)\b/i)
            if (mu) snap.ram.used = parseSize(mu[1])
            /* free -m on Linux: "Mem:  3914  891  3023" (total used free, MB).
               Nothing in the parser matched it, so a Linux guest's RAM tiles
               stayed "—" even when the rest of its stats parsed fine. */
            var fm = t.match(/^Mem:\s+(\d+)\s+\d+\s+(\d+)/)
            if (fm && snap.ram.total === null) {
                snap.ram.total = parseSize(fm[1] + "M")
                snap.ram.free = parseSize(fm[2] + "M")
            }
            /* /proc/meminfo: "MemTotal: 3914 kB" / "MemFree: 3023 kB". */
            var mt2 = t.match(/^MemTotal:\s+(\d+)\s+kB/i)
            if (mt2 && snap.ram.total === null)
                snap.ram.total = parseSize(mt2[1] + "K")
            var mf2 = t.match(/^MemFree:\s+(\d+)\s+kB/i)
            if (mf2 && snap.ram.free === null)
                snap.ram.free = parseSize(mf2[1] + "K")
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

            /* top Memory: line (QNX top) — fallback RAM source. */
            var mm = t.match(/Memory:\s*([\d.]+[KMGT]?B?)\s+\S+\s*,\s*([\d.]+[KMGT]?B?)\s+(avail|free)/i)
            if (mm && snap.ram.total === null) {
                snap.ram.total = parseSize(mm[1])
                snap.ram.free = parseSize(mm[2])
                snap.ram.used = snap.ram.total - snap.ram.free
                continue
            }
            /* procps top -b -n1 header line: "MiB Mem :   3914.0 total,   3023.4 free, ..."
               (or "KiB Mem" on an older procps). Another fallback RAM source,
               used only when ###MEM did not already give us one. */
            var mm3 = t.match(/^(Ki|Mi|Gi)B\s+Mem\s*:\s*([\d.]+)\s+total,\s*([\d.]+)\s+free/i)
            if (mm3 && snap.ram.total === null) {
                var mu3 = mm3[1].toUpperCase() === "KI" ? "K" : (mm3[1].toUpperCase() === "GI" ? "G" : "M")
                snap.ram.total = parseSize(mm3[2] + mu3)
                snap.ram.free = parseSize(mm3[3] + mu3)
                snap.ram.used = snap.ram.total - snap.ram.free
                continue
            }

            /* top Idle: block — per-CPU idle% -> busy%. */
            var im = t.match(/CPU\s+\d+:\s+([\d.]+)%/i)
            if (im) { snap.idlePcts.push(parseFloat(im[1])); continue }
            /* busybox top summary "CPU: 50% usr ... 50% idle ...": the value
               precedes the label, and with -n 2 -d 1 the LAST such line is
               the instantaneous busy% over the 1s sample window (the same
               window the per-process %CPU column is computed over). This is
               the source that makes a Linux guest's busy% tile move. */
            var bs = t.match(/^CPU:\s+\d+%\s+\S+\s+\d+%\s+\S+\s+\d+%\s+\S+\s+([\d.]+)%\s+idle/i)
            if (bs) { snap.busyboxBusy = 100 - parseFloat(bs[1]); continue }

            /* Header row of the process table itself ("PID ... COMMAND"),
               from whichever top/ps produced this block. Read once per PROC
               section and used to pull PID/CPU/MEM/COMMAND out of every data
               row that follows by column name -- this is what lets one parser
               cope with QNX top, procps top and busybox top without guessing
               a fixed layout for each. */
            if (/^PID\b/i.test(t)) {
                procCols = {}
                for (var ci = 0; ci < toks.length; ci++) {
                    var cu = toks[ci].toUpperCase()
                    if (cu === "PID" && procCols.pid === undefined) procCols.pid = ci
                    else if (cu === "%MEM" && procCols.pmem === undefined) procCols.pmem = ci
                    else if ((cu === "RES" || cu === "RSS") && procCols.mem === undefined) procCols.mem = ci
                    else if ((cu === "VSZ" || cu === "SIZE") && procCols.mem === undefined && procCols.mem !== -1) procCols.mem = ci
                    else if (cu === "%CPU" && procCols.pcpu === undefined) procCols.pcpu = ci
                    else if (cu === "CPU" && procCols.cpu === undefined) procCols.cpu = ci
                    else if ((cu === "TIME" || cu === "TIME+") && procCols.time === undefined) procCols.time = ci
                    /* QNX top labels its TIME column "HH:MM:SS" -- without
                       this mapping QNX rows never got a cumulative cpuMs, so
                       buildView had nothing to compute a CPU% delta from for
                       threads that top's -z 100 cap never showed a live % for. */
                    else if (cu === "HH:MM:SS" && procCols.time === undefined) procCols.time = ci
                    else if ((cu === "COMMAND" || cu === "CMD") && procCols.cmd === undefined) procCols.cmd = ci
                }
                /* RES beats VSZ when both are present (RES is the more useful
                   number); the loop above only skips VSZ once RES has already
                   claimed procCols.mem, so re-scan is unnecessary. */
                continue
            }

            var pid = toks[0]
            if (!/^\d+$/.test(pid)) continue
            var pushed = false

            if (procCols && procCols.pid !== undefined && procCols.cmd !== undefined &&
                toks.length > procCols.cmd) {
                var name = toks.slice(procCols.cmd).join(" ")
                if (name) {
                    var cpuPct = null
                    if (procCols.pcpu !== undefined && toks[procCols.pcpu] !== undefined)
                        cpuPct = parseFloat(toks[procCols.pcpu])
                    else if (procCols.cpu !== undefined && toks[procCols.cpu] !== undefined &&
                             /%$/.test(toks[procCols.cpu]))
                        cpuPct = parseFloat(toks[procCols.cpu])
                    var cpuMs2 = (procCols.time !== undefined) ? parseTimeMs(toks[procCols.time]) : null
                    var mb2 = null
                    if (procCols.mem !== undefined && toks[procCols.mem] !== undefined)
                        mb2 = parseMemCol(toks[procCols.mem])
                    var pctMem = (procCols.pmem !== undefined && toks[procCols.pmem] !== undefined)
                        ? parseFloat(toks[procCols.pmem]) : null
                    if (!isStatsNoise(name))
                        snap.procs.push({ pid: +pid, cpuMs: cpuMs2, cpuPct: cpuPct,
                                          memBytes: mb2, pctMem: pctMem, name: name })
                    pushed = true
                }
            }

            if (!pushed) {
                var cpuMs = null, ti = -1
                for (var x = 1; x < toks.length - 1; x++) {
                    var tt = parseTimeMs(toks[x])
                    if (tt !== null) { cpuMs = tt; ti = x; break }
                }
                if (ti >= 0) {
                    var cmdStart = ti + 1
                    var cpuPct2 = null
                    while (cmdStart < toks.length && /^\d+(?:\.\d+)?%$/.test(toks[cmdStart])) {
                        if (cpuPct2 === null) cpuPct2 = parseFloat(toks[cmdStart])
                        cmdStart++
                    }
                    var procName = toks.slice(cmdStart).join(" ")
                    if (procName) {
                        var mb = (agg.procs[pid] && agg.procs[pid].memBytes !== null) ? agg.procs[pid].memBytes : null
                        if (!isStatsNoise(procName))
                            snap.procs.push({ pid: +pid, cpuMs: cpuMs, cpuPct: cpuPct2, memBytes: mb, name: procName })
                        pushed = true
                    }
                } else {
/* busybox top: "  231     1 root     S     378m  10%   0% /usr/bin/motor_ai_server"
                   -- no TIME column, %CPU is the last %-number before the
                   command (%VSZ may precede it, STAT may be 2-3 chars, and the
                   command may contain spaces, e.g. "systemd-userwork: waiting"
                   or "[kworker/R-rcu_g]"). The negative lookahead on the
                   leading token span stops \S+ from swallowing a %-column, so
                   the final capture always lands on %CPU. Without it the parser
                   read %VSZ (10) as the CPU% for an idle process. The VSZ token
                   itself (the last one before the %-run) is now captured too --
                   it used to be thrown away, which is why a Linux guest's
                   process list never showed a MEM figure. */
                    var bm = t.match(/^\s*(\d+)\s+((?:(?!\d+%)\S+\s+){3,6})(?:[\d.]+%?\s+)*([\d.]+)%?\s+(.+)$/)
                    if (bm) {
                        var midToks = bm[2].trim().length ? bm[2].trim().split(/\s+/) : []
                        var vsz = null
                        if (midToks.length > 0) {
                            var last = midToks[midToks.length - 1]
                            if (/^[\d.]+[KMGTkmgt]?B?$/.test(last)) vsz = parseMemCol(last)
                        }
                        if (!isStatsNoise(bm[4]))
                            snap.procs.push({ pid: +bm[1], cpuMs: null, cpuPct: parseFloat(bm[3]),
                                              memBytes: vsz, name: bm[4] })
                        pushed = true
                    } else if (parseThreadRow(t, agg)) {
                        pushed = true
                    }
                }
            }

            /* Catch-all: a row that starts with a numeric PID is a real
               process no matter which of the shapes above it failed to match
               exactly. Previously such a row was just dropped, which is why
               the Monitor page could show only one or two processes even
               though `top`/`pidin` sent back the system's whole table -- most
               rows quietly failed every regex and vanished. Record it with
               whatever we can read off it (at minimum PID and a name) rather
               than lose it. */
            if (!pushed) {
                var fallbackName = toks[toks.length - 1]
                if (fallbackName && fallbackName !== pid && !isStatsNoise(fallbackName))
                    snap.procs.push({ pid: +pid, cpuMs: null, cpuPct: null, memBytes: null, name: fallbackName })
            }
        }
    }
    if (snap.idlePcts.length > 0) {
        var sum = 0
        for (var q = 0; q < snap.idlePcts.length; q++) sum += snap.idlePcts[q]
        snap.cpuBusyPct = 100 - sum / snap.idlePcts.length
    } else if (snap.busyboxBusy !== null) {
        /* busybox top's last CPU: summary — instantaneous (the 1s window the
           %CPU column uses); beats the /proc/stat lifetime average. */
        snap.cpuBusyPct = snap.busyboxBusy
    } else if (snap.statBusy !== null) {
        snap.cpuBusyPct = snap.statBusy
    } else if (agg.threads > 0) {
        /* No pidin cpu on QNX 8: estimate busy from thread states. */
        snap.cpuBusyPct = agg.busyThreads / agg.threads * 100
    }
    /* procps top only gives per-process memory as %MEM, not an absolute
       figure. Resolve it against the total RAM figure (from ###MEM or a
       top/free line elsewhere in this same snapshot) now that the whole
       block has been read, so the process table can still show a MEM column
       instead of leaving it blank for every row. */
    if (snap.ram.total !== null) {
        for (var pm = 0; pm < snap.procs.length; pm++) {
            var spm = snap.procs[pm]
            if (spm.memBytes === null && spm.pctMem !== null && spm.pctMem !== undefined)
                spm.memBytes = spm.pctMem / 100 * snap.ram.total
        }
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
            if (x.memBytes === null && sp.memBytes !== null && sp.memBytes !== undefined)
                x.memBytes = sp.memBytes
        } else {
            procByPid[key] = { pid: sp.pid, name: sp.name,
                               cpuMs: sp.cpuMs, cpuPct: sp.cpuPct,
                               memBytes: sp.memBytes }
        }
    }
    for (var pidk in agg.procs) {
        var rec = agg.procs[pidk]
        if (isStatsNoise(rec.name)) continue
        var x = procByPid[pidk]
        if (x) {
            x.memBytes = rec.memBytes
            /* pidin times is the only QNX source with a CPU figure for every
               process; prefer it over top's thread-level TIME sum. */
            if (pidinCpu[pidk] !== undefined)
                x.cpuMs = pidinCpu[pidk]
            /* First poll has no previous snapshot to diff cpuMs against, so
               every process would show "—" once. The busy-thread ratio is an
               acceptable stand-in until the real delta arrives. */
            if (x.cpuPct === null && rec.threadCount > 0)
                x.cpuPct = rec.busyThreads / rec.threadCount * 100
        } else {
            procByPid[pidk] = { pid: +pidk, name: rec.name, cpuMs: null, cpuPct: null,
                memBytes: rec.memBytes }
            if (pidinCpu[pidk] !== undefined)
                procByPid[pidk].cpuMs = pidinCpu[pidk]
            if (rec.threadCount > 0)
                procByPid[pidk].cpuPct = rec.busyThreads / rec.threadCount * 100
        }
    }
    /* Linux comm is the canonical process name. busybox top shows a
       "{threadname} cmdline" hybrid for threaded processes ("{systemd}
       /sbin/init") and full argv for everything else, both of which read as
       corrupted; /proc/PID/comm has the short name the kernel actually
       stores. Apply it to every process we know a comm for; bracketed
       kernel threads keep their brackets around the full comm. */
    for (var cn in commNames) {
        var cp = procByPid[cn]
        if (cp && cp.name) {
            var raw = commNames[cn]
            var brack = cp.name.charAt(0) === "[" &&
                        cp.name.charAt(cp.name.length - 1) === "]"
            /* A bracketed (kernel-thread) name at exactly 15 chars has hit
               TASK_COMM_LEN (16 bytes, including the NUL) -- the kernel's own
               struct field, not a display-width cut. "kworker/R-dm_bufio"
               is stored, and readable from ANY tool including this section's
               own /proc/PID/comm read, only as "kworker/R-dm_bu": there is
               no longer form left anywhere in kernel state to recover, which
               is what makes this different from the exe-recovery case just
               below (a userspace comm truncation, where the full name still
               exists on disk at /proc/PID/exe). Mark it with an ellipsis so
               it reads as "shortened", not "corrupted" -- a real bug in an
               earlier version of this parser. Non-bracketed names are left
               alone here; they still get a chance at the exe-based full
               recovery immediately below. */
            if (brack && raw.length === 15)
                cp.name = "[" + raw + "…]"
            else
                cp.name = brack ? "[" + raw + "]" : raw
        }
    }
    /* comm itself is kernel-truncated to 15 chars (systemd-timesyn for
       systemd-timesyncd). The exe symlink's basename is the full program
       name -- but only take it when comm is a strict PREFIX of it: that is
       exactly the truncation case. klogd is not a prefix of busybox.nosuid
       (its exe is the busybox applet binary), and systemd-udevd is not a
       prefix of udevadm, so those keep the correct comm name. The one false
       positive left is a real comm that happens to prefix a multi-call
       binary's name (dropbear vs dropbearmulti), so known multi-call
       binaries are excluded outright. */
    var multiCall = /^(busybox|busybox\.nosuid|toybox|dropbearmulti|tinylogin|telnetdmulti)$/
    for (var ek in exeNames) {
        var ep = procByPid[ek]
        var exeBase = exeNames[ek]
        if (ep && ep.name && exeBase &&
            ep.name.length < exeBase.length &&
            exeBase.indexOf(ep.name) === 0 &&
            !multiCall.test(exeBase))
            ep.name = exeBase
    }
    /* Linux: RSS from /proc/PID/statm is the physical figure; replace the
       VSZ (virtual size) that top provided. */
    for (var rk in rssPids)
        if (procByPid[rk]) procByPid[rk].memBytes = rssPids[rk]
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
        /* Kernel threads ("[kworker/...]", "[jbd2/vda-8]", "[ksoftirqd/0]", …)
           are real and correctly named, but they are Linux/kernel internals
           with nothing an operator watching a guest's applications can act
           on -- they only add noise a QNX guest's process list never has
           (QNX has no bracket-wrapped kernel-thread convention). Drop them
           here rather than in parseSnapshot(), so they still count toward
           snap.cpuBusyPct/ram.used (computed earlier from the full snapshot)
           and this filtering only affects what the table displays. */
        if (pr.name && pr.name.charAt(0) === "[") continue
        var cpu = null
        /* pidin times / top TIME column are cumulative CPU time; the delta
           between two polls is the real per-process CPU% over the interval.
           The live %CPU column (cpuPct) is a snapshot and is used only when
           no cumulative source exists (busybox top has no TIME column). */
        if (prevMap[pr.pid] !== undefined && pr.cpuMs !== null &&
            prevMap[pr.pid] !== null && elapsedMs > 0)
            cpu = (pr.cpuMs - prevMap[pr.pid]) / elapsedMs * 100
        else if (pr.cpuPct !== null && pr.cpuPct !== undefined)
            cpu = pr.cpuPct
        if (cpu !== null && cpu < 0)
            cpu = 0
        out.push({ pid: pr.pid, name: pr.name, cpu: cpu, mem: pr.memBytes })
    }
    out.sort(function (a, b) {
        var ac = (a.cpu === null) ? -1 : a.cpu
        var bc = (b.cpu === null) ? -1 : b.cpu
        return bc - ac
    })
    /* Normalize the CPU column so it sums to the system busy% tile: a
       process column is per-core (%) while the tile is an average across
       cores, so without this the two never agree ("the sum of the CPUs
       should equal the CPU usage"). Rows with no figure stay null and are
       left out of the scale. */
    if (snap.cpuBusyPct !== null && snap.cpuBusyPct !== undefined) {
        var total = 0, n = 0
        for (var z = 0; z < out.length; z++)
            if (out[z].cpu !== null) { total += out[z].cpu; n++ }
        if (total > 0 && n > 0) {
            var scale = snap.cpuBusyPct / total
            for (var z2 = 0; z2 < out.length; z2++)
                if (out[z2].cpu !== null) out[z2].cpu *= scale
        }
    }
    /* Same for the MEM column: scale it so the processes sum to the used
       RAM the tile shows. On QNX pidin code+data already lands within ~10%
       of used; on Linux RSS is close to used as well, so this mostly
       absorbs the small difference rather than inflating anything. */
    if (snap.ram && snap.ram.used !== null && snap.ram.used !== undefined &&
        snap.ram.used > 0) {
        var mtotal = 0, mn = 0
        for (var mz = 0; mz < out.length; mz++)
            if (out[mz].mem !== null && out[mz].mem !== undefined) {
                mtotal += out[mz].mem
                mn++
            }
        if (mtotal > 0 && mn > 0) {
            var mscale = snap.ram.used / mtotal
            for (var mz2 = 0; mz2 < out.length; mz2++)
                if (out[mz2].mem !== null && out[mz2].mem !== undefined)
                    out[mz2].mem *= mscale
        }
    }
    return out
}
