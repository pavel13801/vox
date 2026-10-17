// AudioWorklet: converts the microphone stream to 16 kHz mono Int16 and posts ~100 ms chunks.
class PCMCapture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const target = (options && options.processorOptions && options.processorOptions.targetRate) || 16000;
    this.ratio = sampleRate / target; // `sampleRate` is the AudioContext rate (global in worklet scope)
    this.phase = 0;
    this.acc = 0;
    this.cnt = 0;
    this.size = Math.round(target / 10);
    this.out = new Int16Array(this.size);
    this.n = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || !input.length) return true;
    const ch0 = input[0];
    const ch1 = input.length > 1 ? input[1] : null;
    for (let i = 0; i < ch0.length; i++) {
      // Box-filter decimation (cheap anti-aliasing) + mono downmix.
      this.acc += ch1 ? (ch0[i] + ch1[i]) * 0.5 : ch0[i];
      this.cnt++;
      this.phase += 1;
      if (this.phase >= this.ratio) {
        this.phase -= this.ratio;
        let v = this.acc / this.cnt;
        this.acc = 0;
        this.cnt = 0;
        if (v > 1) v = 1; else if (v < -1) v = -1;
        this.out[this.n++] = v < 0 ? v * 0x8000 : v * 0x7fff;
        if (this.n === this.size) {
          this.port.postMessage(this.out.buffer, [this.out.buffer]);
          this.out = new Int16Array(this.size);
          this.n = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor('pcm-capture', PCMCapture);
