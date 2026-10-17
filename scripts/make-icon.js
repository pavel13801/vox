// Generates the 1024×1024 app icon (gradient + waveform) as a PNG without external dependencies.
// Usage: node scripts/make-icon.js Vox/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
const fs = require("fs");
const zlib = require("zlib");

const W = 1024, H = 1024;
const out = process.argv[2] || "icon-1024.png";
const px = Buffer.alloc(W * H * 3);

function lerp(a, b, t) { return a + (b - a) * t; }
const top = [88, 60, 230];    // violet
const bottom = [20, 160, 255]; // blue

// Background gradient (diagonal)
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const t = Math.min(1, Math.max(0, (x * 0.35 + y * 0.65) / (W * 0.35 + H * 0.65)));
    const i = (y * W + x) * 3;
    px[i] = lerp(top[0], bottom[0], t);
    px[i + 1] = lerp(top[1], bottom[1], t);
    px[i + 2] = lerp(top[2], bottom[2], t);
  }
}

// Soft glow in the center
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const dx = x - W / 2, dy = y - H / 2;
    const d = Math.sqrt(dx * dx + dy * dy) / (W * 0.55);
    const g = Math.max(0, 1 - d) * 0.18;
    const i = (y * W + x) * 3;
    for (let c = 0; c < 3; c++) px[i + c] = Math.min(255, px[i + c] + 255 * g);
  }
}

// Rounded white bars (waveform)
const heights = [0.18, 0.34, 0.52, 0.72, 0.52, 0.86, 0.6, 0.4, 0.24];
const barW = 58, gap = 34;
const total = heights.length * barW + (heights.length - 1) * gap;
let x0 = (W - total) / 2;
function inRoundedRect(x, y, rx, ry, rw, rh, r) {
  if (x < rx || x > rx + rw || y < ry || y > ry + rh) return 0;
  const cx = Math.min(Math.max(x, rx + r), rx + rw - r);
  const cy = Math.min(Math.max(y, ry + r), ry + rh - r);
  const d = Math.sqrt((x - cx) ** 2 + (y - cy) ** 2);
  return Math.max(0, Math.min(1, r - d + 0.5));
}
for (const h of heights) {
  const bh = h * 560;
  const by = H / 2 - bh / 2;
  for (let y = Math.floor(by) - 2; y < by + bh + 2; y++) {
    for (let x = Math.floor(x0) - 2; x < x0 + barW + 2; x++) {
      if (x < 0 || y < 0 || x >= W || y >= H) continue;
      const a = inRoundedRect(x, y, x0, by, barW, bh, barW / 2);
      if (a <= 0) continue;
      const i = (y * W + x) * 3;
      for (let c = 0; c < 3; c++) px[i + c] = px[i + c] * (1 - a) + 255 * a;
    }
  }
  x0 += barW + gap;
}

// PNG encoding
const raw = Buffer.alloc((W * 3 + 1) * H);
for (let y = 0; y < H; y++) {
  raw[y * (W * 3 + 1)] = 0;
  px.copy(raw, y * (W * 3 + 1) + 1, y * W * 3, (y + 1) * W * 3);
}
const crcTable = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
});
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);
fs.writeFileSync(out, png);
console.log("wrote", out, png.length, "bytes");
