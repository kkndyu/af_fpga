// Independent numerical oracle: JavaScript binary64 represents BF16*E2M1
// products exactly; Float32 conversion supplies RNE and gradual underflow.
// Binary64 also has enough precision to correctly round a sum of two FP32s.
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const out = path.join(root, 'build', 'fp4_arithmetic');
fs.mkdirSync(out, { recursive: true });
const buf = new ArrayBuffer(4);
const view = new DataView(buf);
function number(bits) { view.setUint32(0, bits >>> 0, true); return view.getFloat32(0, true); }
function bits(value) {
  if (Number.isNaN(value)) return 0x7fc00000;
  view.setFloat32(0, value, true); return view.getUint32(0, true);
}
function hex(value, width = 8) { return (value >>> 0).toString(16).padStart(width, '0'); }
let seed = 0x6d785034;
function random() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; }
const positive = [0, 0.5, 1, 1.5, 2, 3, 4, 6];
const mul = [];
for (let a = 0; a <= 65535; a++) {
  for (let code = 0; code < 16; code++) {
    const w = code & 8 ? -positive[code & 7] : positive[code & 7];
    mul.push(`${hex(a, 4)} ${hex(code, 1)} ${hex(bits(number(a << 16) * w))}\n`);
  }
}
fs.writeFileSync(path.join(out, 'mul.txt'), mul.join(''));
const add = [];
function addition(a, b) { add.push(`${hex(a)} ${hex(b)} ${hex(bits(number(a) + number(b)))}\n`); }
const edge = [0, 0x80000000, 1, 2, 3, 0x007fffff, 0x00800000, 0x00800001,
  0x3f000000, 0x3f7fffff, 0x3f800000, 0x3f800001, 0x33800000, 0x33000000,
  0x7f7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0xff800001];
for (const a of edge) for (const b of edge) addition(a, b);
for (let i = 0; i < 200000; i++) {
  const a = random();
  let b = random();
  if (i % 4 === 1) b = a ^ 0x80000000;
  if (i % 4 === 2) b = (a + 1) >>> 0;
  if (i % 4 === 3) b = (a & 0x7f800000) | (random() & 0x807fffff);
  addition(a, b);
}
fs.writeFileSync(path.join(out, 'add.txt'), add.join(''));
const pack = [];
function packing(m, e, s, inf = 0, nan = 0) {
  const value = nan ? NaN : inf ? (s ? -Infinity : Infinity) : (s ? -1 : 1) * m * 2 ** e;
  pack.push(`${hex(m)} ${e} ${s} ${inf} ${nan} ${hex(bits(value))}\n`);
}
for (const m of [0, 1, 2, 3, 5, 0x7fffff, 0xffffff, 0x1000001, 0x1000003, 0xffffffff])
  for (const e of [-320, -181, -150, -149, -148, -127, -126, -24, 0, 96, 127, 300])
    for (const sign of [0, 1]) packing(m, e, sign);
for (let i = 0; i < 100000; i++) packing(random(), (random() % 641) - 320, random() & 1);
for (const sign of [0, 1]) { packing(0, 0, sign, 1, 0); packing(0, 0, sign, 0, 1); }
fs.writeFileSync(path.join(out, 'pack.txt'), pack.join(''));
console.log(`Arithmetic vectors: ${mul.length} BF16/E2M1 products, ${add.length} FP32 additions, ${pack.length} packs.`);
