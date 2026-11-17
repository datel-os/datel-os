#!/usr/bin/env python3
"""Puts webrtc-player.js in place of the WebRTC camera-streamer player's
methods in Mainsail 2.19.0's release build, and gives that file a revision in
the service worker's precache list, so that a browser which installed the
worker fetches it again instead of serving the old one from its cache.

    patch-webrtc-player.py <Mainsail's installed directory> <webrtc-player.js>

Stops with an error when the release is not the one the methods were written
for: a new Mainsail needs a new look at its player first."""
import hashlib
import pathlib
import sys

PLAYER = "assets/WebrtcCameraStreamer-CoCX5QFo.js"
# from the constructor to onLoadedMetadata() of the player in 2.19.0
ORIGINAL = "7a21704a752983a99cb4d9d029eb08b85e77029e8fb453870d9672a14487fba7"
REVISION = "k1os-webrtc-player-1"


def once(text, old, new, what):
    found = text.count(old)
    if found != 1:
        sys.exit(f"patch-webrtc-player: {what} found {found} times, expected once")
    return text.replace(old, new)


def main():
    dist = pathlib.Path(sys.argv[1])
    methods = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

    player = dist / PLAYER
    text = player.read_text(encoding="utf-8")
    first = text.find("constructor(...e){")
    end = text.find("onLoadedMetadata(){")
    if first < 0 or end < 0 or hashlib.sha256(text[first:end].encode()).hexdigest() != ORIGINAL:
        sys.exit(f"patch-webrtc-player: {player} is not the player of Mainsail 2.19.0")
    start = text.index("async start(){", first)
    text = text[:start] + "\n" + methods + "\n" + text[end:]
    text = once(text, "this.restartTimer=null}get url(){",
                "this.restartTimer=null,this.streamSession=0,this.gone=!1}get url(){",
                "the end of the player's constructor")
    player.write_text(text, encoding="utf-8")

    worker = dist / "sw.js"
    text = worker.read_text(encoding="utf-8")
    text = once(text, '{url:"%s",revision:null}' % PLAYER,
                '{url:"%s",revision:"%s"}' % (PLAYER, REVISION),
                "the player's entry in sw.js")
    worker.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
