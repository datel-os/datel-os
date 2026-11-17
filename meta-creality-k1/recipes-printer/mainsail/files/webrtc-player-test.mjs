// Tries webrtc-player.js, the methods Datel OS gives Mainsail's WebRTC camera
// player, in Node: fetch, RTCPeerConnection and the timers are stand-ins, and
// each check looks at what the player does when it is terminated, destroyed
// or restarted with work in flight. Not part of the build (the build host has
// no Node); run it after changing the methods, and when a new Mainsail makes
// patch-webrtc-player.py stop.
//
//   node webrtc-player-test.mjs patched  webrtc-player.js
//   node webrtc-player-test.mjs original <Mainsail 2.19.0>/assets/WebrtcCameraStreamer-CoCX5QFo.js
//
// "original" runs the release's own methods, which fail six of the checks:
// those are what webrtc-player.js is for.
//
// MIT License, part of Datel OS.
import fs from 'node:fs'

const mode = process.argv[2]
let methods = fs.readFileSync(process.argv[3], 'utf8')
if (mode === 'original') {
    methods = methods.slice(methods.indexOf('async start(){'), methods.indexOf('onLoadedMetadata(){'))
}

function makeWorld() {
    const w = { fetches: [], pcs: [], timers: [], nextTimer: 1, logs: [] }
    w.fetch = (url, opts) => new Promise((resolve, reject) => {
        w.fetches.push({ url, body: JSON.parse(opts.body), resolve, reject })
    })
    w.PC = class {
        constructor(config) {
            this.config = config
            this.closed = false
            this.connectionState = 'new'
            this.localDescription = null
            this.held = null          // a test may hold setRemoteDescription back
            w.pcs.push(this)
        }
        addTransceiver() {}
        setRemoteDescription() {
            if (w.holdSdp) return new Promise((resolve) => { this.held = resolve })
            return Promise.resolve()
        }
        createAnswer() { return Promise.resolve({ type: 'answer', sdp: 'answer-sdp' }) }
        setLocalDescription(d) { this.localDescription = d; return Promise.resolve() }
        close() { this.closed = true; this.connectionState = 'closed' }
    }
    w.window = {
        console: { log: (...a) => w.logs.push(a.join(' ')) },
        setTimeout: (fn, delay) => { const id = w.nextTimer++; w.timers.push({ id, fn, delay }); return id },
        clearTimeout: (id) => { w.timers = w.timers.filter((t) => t.id !== id) },
    }
    w.runTimers = async () => {
        const due = w.timers
        w.timers = []
        // not awaited: the release's timer waits for its start(), whose
        // request stays open until the test answers it
        for (const t of due) t.fn()
        await settle()
    }
    const Player = new Function('fetch', 'RTCPeerConnection', 'window', `return class Player {
        constructor() {
            this.pc = null; this.useStun = true; this.status = 'connecting'; this.restartTimer = null
            this.streamSession = 0; this.gone = false
            this.expanded = true; this.url = 'http://printer/webcam/webrtc'; this.stream = {}
        }
        ${methods}
    }`)(w.fetch, w.PC, w.window)
    w.player = new Player()
    return w
}

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve() }
const ok200 = (json) => ({ status: 200, json: async () => json, text: async () => '' })
const offer = { type: 'offer', id: '7', iceServers: [], sdp: 'offer-sdp' }
const open = (w) => w.pcs.filter((p) => !p.closed).length

const cases = {
    async 'a start connects: one connection, the answer goes to the offer\'s id'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200(offer)); await settle()
        w.fetches[1].resolve(ok200({})); await settle()
        return w.fetches[0].body.type === 'request' && w.fetches[1].body.type === 'answer' && w.fetches[1].body.id === '7' &&
            w.pcs.length === 1 && open(w) === 1 && w.player.pc === w.pcs[0] && w.timers.length === 0
    },
    async 'terminated while the offer is on its way: no connection is opened'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.player.terminate()
        w.fetches[0].resolve(ok200(offer)); await settle()
        return open(w) === 0 && w.fetches.length === 1 && w.timers.length === 0
    },
    async 'destroyed while the offer is on its way: no connection, no restart'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.player.beforeDestroy()
        w.fetches[0].resolve(ok200(offer)); await settle()
        await w.runTimers()
        return open(w) === 0 && w.fetches.length === 1 && w.timers.length === 0
    },
    async 'destroyed, then the request fails: no restart'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.player.beforeDestroy()
        w.fetches[0].resolve({ status: 503, json: async () => ({}), text: async () => '' }); await settle()
        await w.runTimers()
        return open(w) === 0 && w.fetches.length === 1 && w.timers.length === 0
    },
    async 'terminated while the offer is being applied: closed, no answer sent'() {
        const w = makeWorld()
        w.holdSdp = true
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200(offer)); await settle()
        w.player.terminate()
        w.pcs[0].held(); await settle()
        return open(w) === 0 && w.fetches.length === 1 && w.timers.length === 0
    },
    async 'a network error is tried again'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].reject(new Error('network')); await settle()
        const waited = w.timers.length === 1
        await w.runTimers()
        return waited && w.fetches.length === 2 && w.fetches[1].body.type === 'request'
    },
    async 'an error answer is tried again after 500 ms'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve({ status: 503, json: async () => ({}), text: async () => '' }); await settle()
        const waited = w.timers.length === 1 && w.timers[0].delay === 500
        await w.runTimers()
        return waited && w.fetches.length === 2
    },
    async 'a 500 to the STUN request: asked again without STUN servers'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve({ status: 500, json: async () => ({}), text: async () => 'no ice servers' }); await settle()
        await w.runTimers()
        return w.fetches[0].body.iceServers !== null && w.fetches.length === 2 && w.fetches[1].body.iceServers === null
    },
    async 'a restart closes the old connection and opens one new'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200(offer)); await settle()
        w.fetches[1].resolve(ok200({})); await settle()
        w.player.restartStream(0)
        const closed = w.pcs[0].closed
        await w.runTimers()
        w.fetches[2].resolve(ok200({ ...offer, id: '8' })); await settle()
        w.fetches[3].resolve(ok200({})); await settle()
        return closed && w.pcs.length === 2 && open(w) === 1 && w.player.pc === w.pcs[1] && w.fetches[3].body.id === '8'
    },
    async 'events of a connection that was replaced are not acted on'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200(offer)); await settle()
        w.fetches[1].resolve(ok200({})); await settle()
        w.player.restartStream(0); await w.runTimers()
        w.fetches[2].resolve(ok200({ ...offer, id: '8' })); await settle()
        w.fetches[3].resolve(ok200({})); await settle()
        w.pcs[1].connectionState = 'connected'
        w.pcs[1].onconnectionstatechange()
        w.pcs[0].connectionState = 'failed'          // the old one, late
        w.pcs[0].onconnectionstatechange(); await settle()
        return open(w) === 1 && !w.pcs[1].closed && w.timers.length === 0 && w.player.status === 'connected'
    },
    async 'the current connection failing: closed, started again after 5 s'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200(offer)); await settle()
        w.fetches[1].resolve(ok200({})); await settle()
        w.pcs[0].connectionState = 'failed'
        w.pcs[0].onconnectionstatechange(); await settle()
        const waited = w.pcs[0].closed && w.timers.length === 1 && w.timers[0].delay === 5000
        await w.runTimers()
        return waited && w.fetches.length === 3 && w.fetches[2].body.type === 'request'
    },
    async 'destroyed with a restart pending: nothing starts'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200(offer)); await settle()
        w.fetches[1].resolve(ok200({})); await settle()
        w.player.restartStream(500)
        w.player.beforeDestroy()
        await w.runTimers()
        return open(w) === 0 && w.fetches.length === 2 && w.timers.length === 0
    },
    async 'a start that clears a pending restart leaves later restarts working'() {
        const w = makeWorld()
        w.player.restartStream(500)                  // pending
        w.player.start(); await settle()             // as when the panel is expanded again
        const cleared = w.timers.length === 0
        w.fetches[0].resolve({ status: 503, json: async () => ({}), text: async () => '' }); await settle()
        return cleared && w.timers.length === 1     // the failure is tried again
    },
    async 'an offer without iceServers: a connection with none, no candidates posted'() {
        const w = makeWorld()
        w.player.start(); await settle()
        w.fetches[0].resolve(ok200({ type: 'offer', id: '9', sdp: 'offer-sdp' })); await settle()
        return w.pcs.length === 1 && Array.isArray(w.pcs[0].config.iceServers) && w.pcs[0].config.iceServers.length === 0 &&
            w.pcs[0].onicecandidate == null
    },
    async 'a collapsed panel does not start'() {
        const w = makeWorld()
        w.player.expanded = false
        w.player.start(); await settle()
        return w.fetches.length === 0 && w.timers.length === 0
    },
    async 'the state with no connection reads "connecting"'() {
        const w = makeWorld()
        w.player.onConnectionStateChange()
        return w.player.status === 'connecting'
    },
}

let failed = 0
for (const [name, run] of Object.entries(cases)) {
    let pass
    try { pass = await run() } catch (e) { pass = false; console.log(`   threw: ${e.message}`) }
    if (!pass) failed++
    console.log(`${pass ? 'ok  ' : 'FAIL'} ${name}`)
}
console.log(`${mode}: ${Object.keys(cases).length - failed} of ${Object.keys(cases).length} checks pass`)
process.exit(mode === 'patched' && failed ? 1 : 0)
