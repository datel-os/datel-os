# Test of the Moonraker component k1os_slot against the real k1os-slot script
# and files in place of the eMMC:
#   python3 k1os_slot_test.py <k1os_slot.py> <k1os-slot>
# The recipe runs it on the build host (do_compile).
import asyncio, importlib.util, os, sys, tempfile

COMPONENT, SLOT = sys.argv[1], os.path.abspath(sys.argv[2])
spec = importlib.util.spec_from_file_location("k1os_slot", COMPONENT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
fails = 0


def check(what, got, want):
    global fails
    if got == want:
        print("ok   %s" % what)
    else:
        fails += 1
        print("FAIL %s: got %r, want %r" % (what, got, want))


class Klippy:
    def __init__(self): self.sent = []
    async def run_gcode(self, script, default=None): self.sent.append(script)


class Server:
    def __init__(self): self.klippy, self.methods, self.endpoints = Klippy(), {}, {}
    def lookup_component(self, name): return self.klippy
    def register_remote_method(self, name, cb): self.methods[name] = cb
    def register_endpoint(self, path, methods, cb): self.endpoints[path] = (methods, cb)
    def error(self, msg, code=400): return RuntimeError(msg)


class Config:
    def __init__(self, server, tool): self.server, self.tool = server, tool
    def get_server(self): return self.server
    def get(self, key, default=None): return self.tool if key == "tool" else default


T = tempfile.mkdtemp()
os.environ.update(K1OS_SLOT_MARKER=T + "/p1", K1OS_SLOT_KEEP=T + "/boot-keep",
                  K1OS_SLOT_CMDLINE=T + "/cmdline", K1OS_SLOT_PART=T + "/p", K1OS_SLOT_RUN=T)


def marker(text=None):
    if text is not None:
        open(T + "/p1", "wb").write((text + "\n\n").encode().ljust(512, b"\0"))
    return open(T + "/p1", "rb").read(512).split(b"\0")[0].decode().split("\n")[0]


def system(*parts):
    for p in parts: open(T + "/p%d" % p, "wb").write(b"hsqs" + bytes(8188))


def boot(part):
    open(T + "/cmdline", "w").write("console=ttyS2 root=/dev/mmcblk0p%d rootwait ro\n" % part)
    os.system("sh %s trial >/dev/null 2>&1; sh %s confirm >/dev/null 2>&1" % (SLOT, SLOT))


async def main():
    # the tool is a shell script; the component runs it as a program
    tool = T + "/slot"
    open(tool, "w").write("#!/bin/sh\nexec sh %s \"$@\"\n" % SLOT)
    os.chmod(tool, 0o755)
    server = Server()
    comp = mod.load_component(Config(server, tool))
    check("remote methods", sorted(server.methods), ["k1os_slot_keep", "k1os_slot_status"])
    check("endpoints", {p: m for p, (m, _) in server.endpoints.items()},
          {"/server/k1os/slot": ["GET"], "/server/k1os/slot/keep": ["POST"]})

    # a new system in slot 2, written from slot 1
    system(5, 6, 7, 8); marker("ota:kernel2"); boot(8)
    st = await server.endpoints["/server/k1os/slot"][1](None)
    check("trial: running, next, kept", (st["running_slot"], st["next_slot"], st["kept"]), ("slot 2", "slot 1", False))
    await server.methods["k1os_slot_status"]()
    check("trial: the console says where a power cycle goes",
          "trial boot of slot 2" in server.klippy.sent[-1] and "returns to slot 1" in server.klippy.sent[-1], True)
    check("the message is one RESPOND", server.klippy.sent[-1].startswith('RESPOND TYPE=echo MSG="') and server.klippy.sent[-1].count('"') == 2, True)

    await server.methods["k1os_slot_keep"]()
    check("SLOT_KEEP: the marker names this slot", marker(), "ota:kernel2")
    check("SLOT_KEEP: boot-keep names this slot", open(T + "/boot-keep").read().strip(), "ota:kernel2")
    check("SLOT_KEEP: the console says kept", "(slot 2) is kept" in server.klippy.sent[-1], True)
    boot(8)
    st = await server.endpoints["/server/k1os/slot/keep"][1](None)
    check("kept system after a restart, keep again over HTTP", (st["kept"], st["next"]), (True, "ota:kernel2"))

    # the other slot is being written: nothing to return to
    os.remove(T + "/boot-keep"); open(T + "/p5", "wb").write(bytes(8192)); marker("ota:kernel2"); boot(8)
    st = await comp.status()
    check("other slot empty: reported", (st["other_empty"], st["kept"], st["next_slot"]), (True, False, "slot 2"))
    check("other slot empty: the console does not promise a return", "holds no system" in comp.describe(st), True)

    # a root that is neither slot: keep fails and says so, the marker stays
    open(T + "/cmdline", "w").write("console=ttyS2 root=PARTUUID=1 ro\n"); marker("ota:kernel")
    await server.methods["k1os_slot_keep"]()
    check("unknown root: the marker stays", marker(), "ota:kernel")
    check("unknown root: the console reports the failure", "keep failed" in server.klippy.sent[-1], True)


asyncio.run(main())
print("k1os_slot: all tests passed" if not fails else "k1os_slot: %d FAILED" % fails)
sys.exit(1 if fails else 0)
