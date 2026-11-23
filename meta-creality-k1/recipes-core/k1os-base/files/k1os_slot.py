# k1os_slot: the boot slot from Mainsail, for a printer nobody has SSH on.
#
# Datel OS starts as a trial: a power cycle brings the previous system back
# until "k1os-slot keep" is run on the new one. This component runs that tool
# for the macros SLOT_STATUS and SLOT_KEEP (Klipper: action_call_remote_method)
# and for the HTTP endpoints /server/k1os/slot (GET) and /server/k1os/slot/keep
# (POST). It only ever asks for the state or keeps the running slot; pointing
# the printer at the other system stays with "k1os-slot release" over SSH.
#
# MIT License, part of Datel OS.
from __future__ import annotations
import asyncio
import logging
import re
from typing import TYPE_CHECKING, Any, Dict, Tuple

if TYPE_CHECKING:
    from ..confighelper import ConfigHelper
    from ..common import WebRequest
    from .klippy_apis import KlippyAPI

SLOT_NAMES = {"ota:kernel": "slot 1", "ota:kernel2": "slot 2"}


def _gcode_str(text: str) -> str:
    """A string safe inside RESPOND MSG="..."."""
    return re.sub(r"[\r\n\"]", " ", text).strip()


def parse_status(text: str) -> Dict[str, Any]:
    """The lines of "k1os-slot status" as a dictionary."""
    fields: Dict[str, str] = {}
    for line in text.splitlines():
        key, sep, val = line.partition(":")
        if sep:
            fields[key.strip()] = val.strip()
    running, nxt = fields.get("running", "unknown"), fields.get("next", "unknown")
    return {
        "running": running,
        "running_slot": SLOT_NAMES.get(running, running),
        "next": nxt,
        "next_slot": SLOT_NAMES.get(nxt, nxt),
        "kept": fields.get("keep", "").startswith("yes"),
        # a slot that is being written, or whose write broke off
        "other_empty": "other" in fields,
        "text": text,
    }


class K1osSlot:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.tool: str = config.get("tool", "/usr/libexec/k1os/slot")
        self.klippy_apis: KlippyAPI = self.server.lookup_component("klippy_apis")
        self.server.register_remote_method("k1os_slot_status", self.remote_status)
        self.server.register_remote_method("k1os_slot_keep", self.remote_keep)
        self.server.register_endpoint("/server/k1os/slot", ["GET"], self._handle_status)
        self.server.register_endpoint("/server/k1os/slot/keep", ["POST"], self._handle_keep)

    async def _run(self, action: str) -> Tuple[int, str]:
        proc = await asyncio.create_subprocess_exec(
            self.tool, action, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        out, _ = await asyncio.wait_for(proc.communicate(), 20.0)
        return proc.returncode or 0, out.decode(errors="replace").strip()

    async def status(self) -> Dict[str, Any]:
        rc, out = await self._run("status")
        if rc != 0:
            raise self.server.error(f"k1os-slot status failed: {out}", 500)
        return parse_status(out)

    async def keep(self) -> Dict[str, Any]:
        rc, out = await self._run("keep")
        if rc != 0:
            raise self.server.error(f"k1os-slot keep failed: {out}", 500)
        st = await self.status()
        if not st["kept"]:
            raise self.server.error(f"k1os-slot keep did not keep the slot: {st['text']}", 500)
        return st

    def describe(self, st: Dict[str, Any]) -> str:
        if st["kept"]:
            return (f"Datel OS: this system ({st['running_slot']}) is kept; "
                    "it starts after every power-up")
        if st["next"] == st["running"]:
            # the other slot holds no system, so the trial step left the marker alone
            return (f"Datel OS: this system ({st['running_slot']}) is not kept, "
                    "but the other slot holds no system to return to. SLOT_KEEP keeps it")
        return (f"Datel OS: trial boot of {st['running_slot']}. Turning the printer off and on "
                f"returns to {st['next_slot']}. SLOT_KEEP makes this system stay")

    async def console(self, msg: str) -> None:
        try:
            await self.klippy_apis.run_gcode(f'RESPOND TYPE=echo MSG="{_gcode_str(msg)}"', None)
        except Exception:
            logging.info(f"k1os_slot: {msg}")

    async def remote_status(self, **kwargs: Any) -> None:
        try:
            await self.console(self.describe(await self.status()))
        except Exception as e:
            await self.console(f"Datel OS: {e}")

    async def remote_keep(self, **kwargs: Any) -> None:
        try:
            await self.console(self.describe(await self.keep()))
        except Exception as e:
            await self.console(f"Datel OS: {e}")

    async def _handle_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self.status()

    async def _handle_keep(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self.keep()


def load_component(config: ConfigHelper) -> K1osSlot:
    return K1osSlot(config)
