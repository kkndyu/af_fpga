// -----------------------------------------------------------------------------
// verify_consistency.js - recompute the reference GEMV output from the current
// input.mem + gate_r*.mem and compare against the stored ref_out.hex.
//
// This is an independent cross-check of data integrity: the three file sets
// (activation, weights, reference) must agree with each other.  It reuses the
// exact integer product codebook of rtl/core/fp4_product_gen.v.
//
//   node scripts/verify_consistency.js
//
// Exit code 0 = consistent, 1 = mismatch or missing file.
// -----------------------------------------------------------------------------
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const H_DIM = 1024;
const OUT_LANES = 256;
const REGION_LANES = 64;
const NUM_REGIONS = 4;

function readLines(p) {
  if (!fs.existsSync(p)) { console.error('MISSING: ' + p); process.exit(1); }
  return fs.readFileSync(p, 'utf8').split(/\r?\n/).filter(l => l.trim() !== '');
}

// Sign-extend a 16-bit two's complement value.
function toInt16(hex) {
  const v = parseInt(hex, 16) & 0xffff;
  return v >= 0x8000 ? v - 0x10000 : v;
}

// Mirror of fp4_product_gen.v: shifts/adds/negates, no multiplier.
function fp4Product(a, code) {
  switch (code & 0xf) {
    case 0x0: return 0;
    case 0x1: return a >> 1;
    case 0x2: return a;
    case 0x3: return a + (a >> 1);
    case 0x4: return a << 1;
    case 0x5: return a << 2;
    case 0x6: return a >> 2;
    case 0x7: return 0;
    case 0x8: return 0;
    case 0x9: return -(a >> 1);
    case 0xa: return -a;
    case 0xb: return -(a + (a >> 1));
    case 0xc: return -(a << 1);
    case 0xd: return -(a << 2);
    case 0xe: return -(a >> 2);
    case 0xf: return 0;
    default: throw new Error('bad code ' + code);
  }
}

function toInt32(v) {
  const m = ((v % 4294967296) + 4294967296) % 4294967296;
  return m >= 2147483648 ? m - 4294967296 : m;
}

function hex32(v) {
  return (((v % 4294967296) + 4294967296) % 4294967296).toString(16).padStart(8, '0');
}

// ---- load -------------------------------------------------------------------
const actHex = readLines(path.join(ROOT, 'sim/data/input.mem'));
if (actHex.length !== H_DIM) {
  console.error(`input.mem line count ${actHex.length}, expected ${H_DIM}`);
  process.exit(1);
}
const act = actHex.map(toInt16);

// weights[k][j], reconstructed from the four region files.
// Each line is 64 nibbles; lane 0 is the LOWEST nibble = rightmost character.
const weights = Array.from({ length: H_DIM }, () => new Array(OUT_LANES).fill(0));
for (let r = 0; r < NUM_REGIONS; r++) {
  const lines = readLines(path.join(ROOT, `mem_init/expert0/gate_r${r}.mem`));
  if (lines.length !== H_DIM) {
    console.error(`gate_r${r}.mem line count ${lines.length}, expected ${H_DIM}`);
    process.exit(1);
  }
  for (let k = 0; k < H_DIM; k++) {
    const line = lines[k].trim();
    if (line.length !== REGION_LANES) {
      console.error(`gate_r${r}.mem line ${k} length ${line.length}, expected ${REGION_LANES}`);
      process.exit(1);
    }
    for (let n = 0; n < REGION_LANES; n++) {
      const j = r * REGION_LANES + n;
      weights[k][j] = parseInt(line[REGION_LANES - 1 - n], 16);
    }
  }
}

// ---- recompute --------------------------------------------------------------
const refStored = readLines(path.join(ROOT, 'sim/data/ref_out.hex'));
if (refStored.length !== OUT_LANES) {
  console.error(`ref_out.hex line count ${refStored.length}, expected ${OUT_LANES}`);
  process.exit(1);
}

let mismatches = 0;
for (let j = 0; j < OUT_LANES; j++) {
  let acc = 0;
  for (let k = 0; k < H_DIM; k++) {
    acc = toInt32(acc + fp4Product(act[k], weights[k][j]));
  }
  const mine = hex32(acc);
  const stored = refStored[j].trim().toLowerCase();
  if (mine !== stored) {
    if (mismatches < 8) {
      console.log(`  lane ${j}: recomputed=${mine} stored=${stored}`);
    }
    mismatches++;
  }
}

console.log(`activation values read : ${act.length}`);
console.log(`weight codes read      : ${H_DIM * OUT_LANES}`);
console.log(`reference lanes checked: ${OUT_LANES}`);
if (mismatches === 0) {
  console.log('CONSISTENT: ref_out.hex matches the recomputation from input.mem + gate_r*.mem');
  process.exit(0);
}
console.log(`INCONSISTENT: ${mismatches} lane(s) differ`);
process.exit(1);
