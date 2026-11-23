# Runs on the printer, fed to python3 by tools/release-test.sh after the
# system under test has started:
#
#   python3 - <version> <root partition number> <marker of the slot to return to>
#
# Every check prints one line, "ok   <what>" or "FAIL <what>: <found>". The last
# line is "CHECKS <passed> passed, <failed> failed"; the exit status is 1 when
# any check failed. Nothing here moves an axis or heats anything.
import hashlib, json, subprocess, sys, time, urllib.parse, urllib.request

VERSION, ROOT_PART, RETURN_MARKER = sys.argv[1], sys.argv[2], sys.argv[3]
MOONRAKER = "http://127.0.0.1:7125"
KLIPPY_LOG = "/usr/data/k1os/printer_data/logs/klippy.log"
passed = failed = 0


def check(what, ok, found=""):
    global passed, failed
    if ok:
        passed += 1
        print("ok   %s%s" % (what, (" (%s)" % found) if found else ""))
    else:
        failed += 1
        print("FAIL %s: %s" % (what, found))


def attempt(what, fn):
    """A check that cannot even be made is a failed check, not a crash."""
    try:
        fn()
    except Exception as e:
        check(what, False, "%s: %s" % (type(e).__name__, e))


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()


def fetch(url, data=None, timeout=15):
    return urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=timeout).read()


def moonraker(path, post=False):
    return json.loads(fetch(MOONRAKER + path, data=b"" if post else None))["result"]


def system():
    cmdline = open("/proc/cmdline").read().split()
    check("runs from mmcblk0p%s" % ROOT_PART, "root=/dev/mmcblk0p%s" % ROOT_PART in cmdline,
          " ".join(a for a in cmdline if a.startswith("root=")))
    rel = dict(l.rstrip("\n").split("=", 1) for l in open("/etc/os-release") if "=" in l)
    ver = rel.get("VERSION", "").strip('"')
    check("os-release names version %s" % VERSION, ver == VERSION or ver.startswith(VERSION + " "),
          "VERSION=%s BUILD_ID=%s" % (ver, rel.get("BUILD_ID", "").strip('"')))
    status = sh("/usr/libexec/k1os/slot status")
    lines = dict(l.split(":", 1) for l in status.splitlines() if ":" in l)
    nxt = lines.get("next", "").strip()
    check("a trial boot: the next boot is %s" % RETURN_MARKER,
          nxt == RETURN_MARKER and lines.get("keep", "").strip().startswith("no"), status.replace("\n", "; "))
    # systemd may still be starting units a minute after the kernel
    state = ""
    for _ in range(40):
        state = sh("systemctl is-system-running")
        if state != "starting":
            break
        time.sleep(3)
    units = sh("systemctl --failed --no-legend --plain | cut -d' ' -f1 | tr '\\n' ' '")
    check("systemd reached its target with no failed unit", state == "running" and not units,
          "state %s, failed: %s" % (state, units or "none"))
    taint = open("/proc/sys/kernel/tainted").read().strip()
    check("kernel not tainted", taint == "0", "tainted %s" % taint)
    avail = [int(l.split()[1]) // 1024 for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0]
    check("memory left", avail >= 60, "%d MiB available" % avail)


def klipper():
    info = moonraker("/server/info")
    check("Moonraker sees Klipper ready", info.get("klippy_state") == "ready", "klippy_state %s" % info.get("klippy_state"))
    check("Moonraker has no warning and no failed component",
          not info.get("warnings") and not info.get("failed_components"),
          "warnings %s, failed %s" % (info.get("warnings"), info.get("failed_components")))
    host = moonraker("/printer/info")
    check("the host is zklippy", "zklippy" in host.get("software_version", ""), host.get("software_version", "?"))
    mcus = ["mcu", "mcu nozzle_mcu", "mcu leveling_mcu"]
    q = "&".join(urllib.parse.quote(m) + "=last_stats" for m in mcus)
    st = moonraker("/printer/objects/query?webhooks=state&print_stats=state&" + q)["status"]
    check("Klipper ready and idle",
          st["webhooks"]["state"] == "ready" and st["print_stats"]["state"] in ("standby", "complete", "cancelled"),
          "webhooks %s, print %s" % (st["webhooks"]["state"], st["print_stats"]["state"]))
    for m in mcus:
        ls = st.get(m, {}).get("last_stats", {})
        inv, retx = ls.get("bytes_invalid"), ls.get("bytes_retransmit")
        check("%s talks cleanly" % m, inv == 0 and retx is not None and retx < 100, "invalid %s, retransmit %s" % (inv, retx))
    # commands that only report: nothing here changes the printer's state
    for g in ("M114", "M115", "GET_POSITION", "QUERY_ENDSTOPS", "BED_MESH_OUTPUT"):
        try:
            r = moonraker("/printer/gcode/script?script=" + urllib.parse.quote(g), post=True)
        except Exception as e:
            r = "%s: %s" % (type(e).__name__, e)
        check("G-code %s" % g, r == "ok", "" if r == "ok" else str(r)[:120])
    log = open(KLIPPY_LOG, errors="replace").read().splitlines()
    starts = [i for i, l in enumerate(log) if "Start printer at" in l]
    boot = log[starts[-1]:] if starts else log
    bad = [l for l in boot if any(w in l for w in ("Traceback", "Internal error", "Unhandled exception", "MCU shutdown", "Transition to shutdown"))]
    check("klippy.log of this start is clean", not bad, bad[0][:120] if bad else "%d lines" % len(boot))
    # from the process itself: the log line about mlockall is gone after a rollover
    pid = sh("systemctl show -p MainPID --value klipper")
    locked = [l.split()[1] for l in open("/proc/%s/status" % pid) if l.startswith("VmLck:")][0]
    check("the host locked its memory", int(locked) > 0, "VmLck %s kB" % locked)


def camera():
    a = fetch("http://127.0.0.1:8080/snapshot", timeout=20)
    time.sleep(1.5)
    b = fetch("http://127.0.0.1:8080/snapshot", timeout=20)
    jpeg = a[:2] == b"\xff\xd8" and b[:2] == b"\xff\xd8"
    check("camera gives a picture", jpeg and len(a) > 10000, "%d and %d bytes" % (len(a), len(b)))
    # the same bytes twice is a stream that stopped: a live sensor never repeats a JPEG
    check("camera frames keep coming", hashlib.md5(a).digest() != hashlib.md5(b).digest(),
          "two snapshots 1.5 s apart are identical" if a == b else "")


def web():
    page = fetch("http://127.0.0.1/").decode("utf-8", "replace").lower()
    check("Mainsail is served", "mainsail" in page, "%d bytes" % len(page))


for name, fn in (("system", system), ("Klipper", klipper), ("camera", camera), ("web interface", web)):
    attempt(name, fn)
print("CHECKS %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
