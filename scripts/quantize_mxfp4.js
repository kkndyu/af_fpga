// JSON {weights: [1024][256], activations: [1024]} -> board-ready MXFP4
// weights/scales, BF16 activations and exact FP32 reference outputs.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {dotReference,packAccumulator}=require('./lib/mxfp4_reference');
const values=[0,0.5,1,1.5,2,3,4,6];
const bytes=new DataView(new ArrayBuffer(4));
const hex=(x,n=8)=>(x>>>0).toString(16).padStart(n,'0');
function toBf16(value) {
  bytes.setFloat32(0,value,true);
  const bits=bytes.getUint32(0,true);
  if((bits&0x7fffffff)>0x7f800000) return 0x7fc0;
  return ((bits+0x7fff+((bits>>>16)&1))>>>16)&65535;
}
function toE2m1(value) {
  const sign=value<0 || Object.is(value,-0)?8:0;
  if(Math.abs(value)>=6) return sign|7;
  let index=0,distance=Infinity;
  for(let i=0;i<8;i++) {
    const delta=Math.abs(Math.abs(value)-values[i]);
    if(delta<distance || (delta===distance && !(i&1))) {index=i;distance=delta;}
  }
  return sign|index;
}
function blockScale(amax) {
  // OCP MX section 6.3: floor power-of-two of amax / maximum power-of-two
  // of E2M1 (4). Zero blocks use scale 1. Clamp to the E8M0 finite range.
  return amax===0?127:Math.max(0,Math.min(254,Math.floor(Math.log2(amax))-2+127));
}
function selfTest() {
  for(let i=0;i<8;i++) {
    assert.strictEqual(toE2m1(values[i]),i);
    assert.strictEqual(toE2m1(-values[i]),i|8);
    if(i<7) {
      const mid=(values[i]+values[i+1])/2,expected=(i&1)?i+1:i;
      assert.strictEqual(toE2m1(mid),expected);
      assert.strictEqual(toE2m1(-mid),expected|8);
    }
  }
  assert.strictEqual(toE2m1(1e20),7);
  assert.strictEqual(toE2m1(-1e20),15);
  assert.strictEqual(toBf16(1),0x3f80);
  assert.strictEqual(toBf16(-0),0x8000);
  assert.strictEqual(toBf16(1+2**-8),0x3f80);
  assert.strictEqual(toBf16(1+3*2**-8),0x3f82);
  assert.strictEqual(toBf16(2**-133),1);
  assert.strictEqual(blockScale(0),127);
  assert.strictEqual(blockScale(6),127);
  assert.strictEqual(blockScale(7),127);
  assert.strictEqual(blockScale(8),128);
  assert.strictEqual(blockScale(2**-149),0);
  assert.strictEqual(packAccumulator(1n<<261n),0x3f800000);
  assert.strictEqual(packAccumulator((1n<<261n)+(1n<<237n)),0x3f800000);
  assert.strictEqual(packAccumulator((1n<<261n)+(1n<<237n)+1n),0x3f800001);
  assert.strictEqual(packAccumulator(1n<<112n),1);
  assert.strictEqual(packAccumulator(1n<<111n),0);
  assert.strictEqual(packAccumulator((1n<<111n)+1n),1);
  const smoke=path.resolve(__dirname,'../build/mxfp4_quantizer_smoke');
  fs.mkdirSync(smoke,{recursive:true});
  const matrix=Array.from({length:1024},()=>Array(256).fill(0));
  const input=Array(1024).fill(0);
  for(const k of [0,1,31,32,1023]) input[k]=1;
  matrix[0][0]=1;matrix[1][0]=2;matrix[31][0]=3;matrix[32][0]=4;matrix[1023][255]=-6;
  const inputFile=path.join(smoke,'input.json'),modelDir=path.join(smoke,'model');
  fs.writeFileSync(inputFile,JSON.stringify({weights:matrix,activations:input}));
  quantize(inputFile,modelDir);
  const lines=name=>fs.readFileSync(path.join(modelDir,name),'utf8').trim().split(/\r?\n/);
  const expected=lines('ref_1024.hex');
  assert.strictEqual(expected[0],'41200000'); // 1+2+3+4 = 10.
  assert.strictEqual(expected[255],'c0c00000'); // -6.
  assert(expected.slice(1,255).every(x=>x==='00000000'));
  assert(lines('scale_r0.mem')[0].endsWith('7e'));
  assert(lines('scale_r0.mem')[1].endsWith('7f'));
  assert(lines('weight_r0.mem')[0].endsWith('4'));
  assert(lines('weight_r3.mem')[1023].startsWith('f'));
  console.log('MXFP4 quantizer: encoding, ties-to-even, BF16, scales and exact rounding tests passed.');
}
function quantize(input,output) {
  const source=JSON.parse(fs.readFileSync(input,'utf8'));
  if(!Array.isArray(source.weights)||source.weights.length!==1024 || source.weights.some(row=>!Array.isArray(row)||row.length!==256))
    throw Error('weights must have shape [1024][256], indexed [input][output]');
  if(!Array.isArray(source.activations)||source.activations.length!==1024) throw Error('activations must contain 1024 values');
  for(const value of source.weights.flat().concat(source.activations))
    if(typeof value!=='number'||!Number.isFinite(Math.fround(value))) throw Error('JSON input values must be finite FP32 numbers');
  const weights=Array.from({length:1024},()=>Array(256).fill(0));
  const scales=Array.from({length:32},()=>Array(256).fill(0));
  let saturated=0;
  for(let block=0;block<32;block++) for(let lane=0;lane<256;lane++) {
    let amax=0;
    for(let k=0;k<32;k++) amax=Math.max(amax,Math.abs(Math.fround(source.weights[block*32+k][lane])));
    const scale=blockScale(amax),factor=2**(scale-127);
    scales[block][lane]=scale;
    for(let k=0;k<32;k++) {
      const value=Math.fround(source.weights[block*32+k][lane])/factor;
      if(Math.abs(value)>6) saturated++;
      weights[block*32+k][lane]=toE2m1(value);
    }
  }
  const activation=source.activations.map(toBf16);
  fs.mkdirSync(output,{recursive:true});
  const write=(name,lines)=>fs.writeFileSync(path.join(output,name),lines.join('\n')+'\n');
  for(let bank=0;bank<4;bank++) {
    write(`weight_r${bank}.mem`,weights.map(row=>row.slice(bank*64,bank*64+64).reverse().map(x=>hex(x,1)).join('')));
    write(`scale_r${bank}.mem`,scales.map(row=>row.slice(bank*64,bank*64+64).reverse().map(x=>hex(x,2)).join('')));
  }
  write('activation.mem',activation.map(x=>hex(x,4)));
  write('ref_1024.hex',dotReference(1024,activation,weights,scales).map(x=>hex(x)));
  fs.writeFileSync(path.join(output,'metadata.json'),JSON.stringify({format:'BF16 x MXFP4 weights',shape:[1024,256],blockSize:32,scaleFormat:'E8M0',rounding:'RNE',scaleSelection:'OCP MX section 6.3',saturatedElements:saturated,result:'FP32 RNE after exact accumulation'},null,2));
  console.log(`Wrote ${output}; ${saturated} weights saturated after block scaling.`);
}
if(require.main===module) {
  if(process.argv[2]==='--self-test') selfTest();
  else if(process.argv.length===4) quantize(process.argv[2],path.resolve(process.argv[3]));
  else {console.error('Usage: node scripts/quantize_mxfp4.js input.json output-directory | --self-test');process.exitCode=1;}
}
module.exports={toBf16,toE2m1,blockScale,quantize};
