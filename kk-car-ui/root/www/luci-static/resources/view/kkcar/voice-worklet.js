// 8 kHz mono S16 PCM over WebSocket. The browser side remains at its native
// sample rate; the worklet keeps resampler state across 128-frame callbacks.
class KkCarVoiceProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        this.micSum = 0;
        this.micCount = 0;
        this.micPhase = 0;
        this.up = new Int16Array(160);
        this.upUsed = 0;
        this.down = [];
        this.downIndex = 0;
        this.downPhase = 0;
        this.downSample = 0;
        this.downBuffering = true;
        this.downStarted = false;
        this.downUnderruns = 0;
        this.downDropped = 0;
        this.reportFrames = 0;
        this.port.onmessage = (event) => {
            if (event.data && event.data.down) {
                const pcm = new Int16Array(event.data.down);
                if (!pcm.length) return;
                this.down.push(pcm);
                // Keep latency bounded if the browser briefly stops rendering.
                if (this.down.length > 10) {
                    this.down.shift();
                    this.downIndex = 0;
                    this.downDropped++;
                }
            }
        };
    }
    process(inputs, outputs) {
        const source = inputs[0] && inputs[0][0];
        const out = outputs[0] && outputs[0][0];
        const ratio = sampleRate / 8000;
        if (source) {
            for (let i = 0; i < source.length; i++) {
                this.micSum += source[i];
                this.micCount++;
                this.micPhase++;
                if (this.micPhase >= ratio) {
                    const value = Math.max(-1, Math.min(1, this.micSum / this.micCount));
                    this.up[this.upUsed++] = Math.round(value * 32767);
                    this.micSum = 0; this.micCount = 0; this.micPhase -= ratio;
                    if (this.upUsed === 160) {
                        this.port.postMessage(this.up.buffer, [this.up.buffer]);
                        this.up = new Int16Array(160); this.upUsed = 0;
                    }
                }
            }
        }
        if (out) {
            for (let i = 0; i < out.length; i++) {
                // Three 20 ms packets absorb ordinary Wi-Fi and main-thread
                // scheduling jitter before playback begins or resumes.
                if (this.downBuffering) {
                    if (this.down.length < 3) {
                        out[i] = 0;
                        continue;
                    }
                    this.downBuffering = false;
                    this.downStarted = true;
                    this.downSample = 0;
                }
                out[i] = this.downSample;
                this.downPhase += 8000 / sampleRate;
                if (this.downPhase >= 1) {
                    this.downPhase -= 1;
                    while (this.down.length && this.downIndex >= this.down[0].length) {
                        this.down.shift(); this.downIndex = 0;
                    }
                    if (this.down.length) this.downSample = this.down[0][this.downIndex++] / 32768;
                    else {
                        this.downSample = 0;
                        this.downBuffering = true;
                        if (this.downStarted) this.downUnderruns++;
                    }
                }
            }
            this.reportFrames += out.length;
            if (this.reportFrames >= sampleRate * 5) {
                this.reportFrames = 0;
                this.port.postMessage({quality:{
                    queuedMs:Math.max(0,Math.round(this.down.length * 20 - this.downIndex / 8)),
                    underruns:this.downUnderruns,
                    dropped:this.downDropped
                }});
            }
        }
        return true;
    }
}
registerProcessor('kkcar-voice', KkCarVoiceProcessor);
