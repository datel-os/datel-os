/* Methods of Mainsail 2.19.0's WebRTC camera-streamer player
 * (src/components/webcams/streamers/WebrtcCameraStreamer.vue), put by
 * patch-webrtc-player.py in place of the release build's own, from start()
 * to log(), beforeDestroy(), terminate() and restartStream().
 *
 * The release's player goes on with what it has in flight after it is gone:
 * a request for an offer that comes back after the view was switched or the
 * panel went away (it does when Moonraker's websocket drops) opens a
 * connection, and a failure schedules a restart, on a component nobody shows
 * any more. Such a connection is never closed; it keeps one of the camera's
 * two viewer places, its encryption and its 2.5 Mbit/s of Wi-Fi until the
 * page is reloaded, and the next view that is opened is turned away. The
 * player also took events of a connection it had already replaced for its
 * current one, and start() cleared a pending restart without forgetting it,
 * after which restartStream() never restarted again.
 *
 * Here every start belongs to one session: terminate() ends it, and work of
 * an ended session closes what it opened and stops. Only the current
 * connection's events count, and a player that is gone does not restart. A
 * network error is retried like an error answer, five seconds later, so the
 * view does not stay dark after a short outage. Class body, minified
 * Mainsail around it: no imports of its own. */
async start() {
	this.clearRestart()
	if (this.gone) return
	if (!this.expanded) {
		this.log(`Not expanded, not starting stream`)
		return
	}
	const session = ++this.streamSession
	this.log(`Requesting ICE servers from ${this.url}`)
	try {
		const iceServers = this.useStun ? [{ urls: [`stun:stun.l.google.com:19302`] }] : null
		const response = await fetch(this.url, {
			body: JSON.stringify({ type: `request`, iceServers, keepAlive: true }),
			method: `POST`,
		})
		if (session !== this.streamSession) return
		if (this.useStun && response.status === 500) {
			const text = await response.text()
			if (session !== this.streamSession) return
			this.log(`Server returned 500 error, likely due to unsupported ICE server request.`)
			this.log(`Server error message: ${text}`)
			this.useStun = false
			this.restartStream()
			return
		}
		if (response.status !== 200) {
			this.log(`Failed to start stream: ${response.status}`)
			this.restartStream()
			return
		}
		const offer = await response.json()
		if (session !== this.streamSession) return
		await this.onIceServers(offer, session)
	} catch (e) {
		if (session !== this.streamSession) return
		this.log(`Failed to start stream`, e)
		this.restartStream(5e3)
	}
}
async onIceServers(offer, session) {
	if (session !== this.streamSession) return
	const pc = new RTCPeerConnection({ iceServers: offer.iceServers ?? [], sdpSemantics: `unified-plan` })
	if (this.pc) this.pc.close()
	this.pc = pc
	pc.addTransceiver(`video`, { direction: `recvonly` })
	if (`iceServers` in offer) {
		pc.onicecandidate = (e) => {
			if (this.pc === pc) this.onIceCandidate(e, offer.id, pc)
		}
	} else {
		this.log(`No ICE servers returned, so the current camera-streamer version may not support them`)
	}
	pc.onconnectionstatechange = () => {
		if (this.pc === pc) this.onConnectionStateChange()
	}
	pc.ontrack = (e) => {
		if (this.pc === pc) this.onTrack(e)
	}
	pc.ondatachannel = (e) => {
		if (this.pc === pc) this.onDataChannel(e)
	}
	let local
	try {
		await pc.setRemoteDescription(offer)
		const answer = await pc.createAnswer()
		await pc.setLocalDescription(answer)
		local = pc.localDescription
	} catch (e) {
		if (this.pc !== pc) return
		this.log(`Failed to create answer`, e)
		this.restartStream()
		return
	}
	if (this.pc !== pc) return
	if (!local) {
		this.log(`Failed to create offer`)
		this.restartStream()
		return
	}
	try {
		const response = await fetch(this.url, {
			body: JSON.stringify({ type: local.type, id: offer.id, sdp: local.sdp }),
			headers: { 'Content-Type': `application/json` },
			method: `POST`,
		})
		if (this.pc !== pc) return
		if (response.status !== 200) {
			this.log(`Failed to send offer: ${response.status}`)
			this.restartStream()
		}
	} catch (e) {
		if (this.pc !== pc) return
		this.log(`Failed to send offer`, e)
		this.restartStream()
	}
}
async onIceCandidate(e, id, pc) {
	if (!e.candidate) return
	try {
		const response = await fetch(this.url, {
			body: JSON.stringify({ id, type: `remote_candidate`, candidates: [e.candidate] }),
			headers: { 'Content-Type': `application/json` },
			method: `POST`,
		})
		if (this.pc !== pc) return
		if (response.status !== 200) {
			this.log(`Failed to send ICE candidate: ${response.status}`)
			this.restartStream()
		}
	} catch (err) {
		if (this.pc !== pc) return
		this.log(`Failed to send ICE candidate`, err)
		this.restartStream()
	}
}
onConnectionStateChange() {
	this.status = this.pc?.connectionState ?? `connecting`
	this.log(`State: ${this.status}`)
	if ([`failed`, `disconnected`].includes(this.status)) this.restartStream(5e3)
}
onTrack(e) {
	if (e.track.kind === `video`) this.stream.srcObject = e.streams[0]
}
onDataChannel(e) {
	const channel = e.channel
	this.log(`Data channel opened: ${channel.label}`)
	if (channel.label !== `keepalive`) {
		this.log(`Unknown data channel label: ${channel.label}`)
		return
	}
	channel.onmessage = (m) => {
		if (m.data === `ping`) channel.send(`pong`)
	}
}
log(message, details) {
	const text = `[WebRTC camera-streamer] ${message}`
	if (details) {
		window.console.log(text, details)
		return
	}
	window.console.log(text)
}
beforeDestroy() {
	this.gone = true
	this.terminate()
}
terminate() {
	this.log(`Terminating stream`)
	this.streamSession++
	this.clearRestart()
	if (this.pc) {
		this.pc.close()
		this.pc = null
	}
}
clearRestart() {
	if (this.restartTimer) {
		window.clearTimeout(this.restartTimer)
		this.restartTimer = null
	}
}
restartStream(delay = 500) {
	this.terminate()
	if (this.gone) return
	this.restartTimer = window.setTimeout(() => {
		this.restartTimer = null
		this.start()
	}, delay)
}
