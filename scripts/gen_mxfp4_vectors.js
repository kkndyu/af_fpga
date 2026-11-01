const fs = require('fs');
const path = require('path');
const {dotReference,dotReferenceFp32} = require('./lib/mxfp4_reference');
const out = path.resolve(__dirname, '../build/mxfp4_vectors');
fs.mkdirSync(out, {recursive: true});
let seed = 0x4d584634;
function rnd() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; }
const hex = (x, n=8) => (x >>> 0).toString(16).padStart(n, '0');
const activation = Array.from({length:1024}, () => ((rnd() & 1) << 15) | ((117+rnd()%21) << 7) | (rnd() & 127));
activation[0] = 0x8001; activation[1] = 0x3f80; activation[2] = 0xbf80;
activation[3] = 0x3380; activation[4] = 0x2b80; activation[5] = 0x0080;
const weights = Array.from({length:1024}, () => Array.from({length:256}, () => rnd() & 15));
const scales = Array.from({length:32}, () => Array.from({length:256}, () => 107+rnd()%41));
for (let j=0;j<16;j++) for(let k=0;k<1024;k++) weights[k][j] = 0;
for(let block=0;block<32;block++) {
  for(let j=0;j<16;j++) scales[block][j] = 127;
  scales[block][2] = block%2 ? 254 : 0;
  scales[block][4] = 254;
  scales[block][5] = 0;
  scales[block][10] = 254;
}
scales[0][3] = 255;
for(let k=0;k<1024;k++) {
  weights[k][1] = 2;
  weights[k][2] = (k%2 ? 2 : 10);
  weights[k][4] = k===1 ? 7 : 0;
}
weights[1][5]=1; weights[0][6]=1;
weights[1][7]=2; weights[2][7]=2;
weights[1][8]=7;
weights[0][10]=1; weights[1][10]=7; weights[2][10]=7;
weights[1][11]=2; weights[3][11]=2;
weights[1][12]=2; weights[3][12]=2; weights[4][12]=2;
weights[1][13]=10; weights[3][13]=10; weights[4][13]=10;
weights[5][14]=1;
function reference(klen, acts, scaleValues) {
  return dotReference(klen,acts,weights,scaleValues);
}
function write(name, rows) { fs.writeFileSync(path.join(out,name), rows.join('\n')+'\n'); }
write('activation.mem',activation.map(x=>hex(x,4)));
for(let bank=0;bank<4;bank++) {
  write(`weight_r${bank}.mem`,weights.map(row=>row.slice(bank*64,bank*64+64).reverse().map(x=>hex(x,1)).join('')));
  write(`scale_r${bank}.mem`,scales.map(row=>row.slice(bank*64,bank*64+64).reverse().map(x=>hex(x,2)).join('')));
}
write('ref_1024.hex',reference(1024,activation,scales).map(x=>hex(x)));
// Reference for MOE_MXFP4_FP32: one binary32 rounding per addition.  It differs
// from ref_1024.hex wherever exact accumulation and per-step rounding disagree.
write('ref_1024_fp32.hex',dotReferenceFp32(1024,activation,weights,scales).map(x=>hex(x)));
const changedFull=scales.map(row=>row.slice()); changedFull[0][11]+=1;
write('ref_1024_changed.hex',reference(1024,activation,changedFull).map(x=>hex(x)));
write('ref_64.hex',reference(64,activation,scales).map(x=>hex(x)));
write('ref_64_fp32.hex',dotReferenceFp32(64,activation,weights,scales).map(x=>hex(x)));
const changed=scales.map(row=>row.slice()); changed[1][9]+=3;
write('ref_64_changed.hex',reference(64,activation,changed).map(x=>hex(x)));
write('ref_64_changed_fp32.hex',dotReferenceFp32(64,activation,weights,changed).map(x=>hex(x)));
const special=activation.slice(); special[0]=0x7f80; special[1]=0xff80;
write('ref_64_special.hex',reference(64,special,changed).map(x=>hex(x)));
write('ref_64_special_fp32.hex',dotReferenceFp32(64,special,weights,changed).map(x=>hex(x)));
fs.writeFileSync(path.join(out,'metadata.json'),JSON.stringify({format:'BF16 x MXFP4 weights', blockSize:32, scaleFormat:'E8M0', accumulatorLsb:-261, accumulatorBits:544, result:'FP32 RNE once after exact accumulation',changedScale:changed[1][9]},null,2));
console.log('Generated independent BigInt MXFP4 references (64 and 1024 inputs, 256 outputs).');
