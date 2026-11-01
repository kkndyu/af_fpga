// Independent exact dot-product oracle, in units of 2^-261. No RTL helper
// code is imported. BigInt preserves cancellation, subnormals and sticky bits.
const coefficients=[0,1,2,3,4,6,8,12];
function roundShift(n,shift) {
  if(shift<=0) return n<<BigInt(-shift);
  const sh=BigInt(shift),q=n>>sh,rem=n-(q<<sh),half=1n<<(sh-1n);
  return q+((rem>half || (rem===half && (q&1n)))?1n:0n);
}
function packAccumulator(signed) {
  if(signed===0n) return 0;
  const sign=signed<0n?0x80000000:0,n=signed<0n?-signed:signed;
  const top=n.toString(2).length-1;
  let e=top-261;
  if(e>127) return (sign|0x7f800000)>>>0;
  if(e>=-126) {
    let m=roundShift(n,top-23);
    if(m===(1n<<24n)) {m>>=1n;e++;}
    if(e>127) return (sign|0x7f800000)>>>0;
    return (sign|((e+127)<<23)|Number(m&0x7fffffn))>>>0;
  }
  return (sign|Number(roundShift(n,112)))>>>0;
}
function dotReference(klen,acts,weights,scales) {
  return Array.from({length:weights[0].length},(_,j)=>{
    let acc=0n,nan=false,pos=false,neg=false;
    for(let k=0;k<klen;k++) {
      const a=acts[k],e=(a>>>7)&255,f=a&127,w=weights[k][j],s=scales[k>>>5][j];
      const coeff=coefficients[w&7],negative=!!((a>>>15)^(w>>>3));
      if(s===255 || (e===255 && (f!==0 || coeff===0))) {nan=true;continue;}
      if(e===255) {if(negative) neg=true;else pos=true;continue;}
      const m=e===0?f:128+f;
      const value=BigInt(m*coeff)<<BigInt(Math.max(e,1)+s-1);
      acc+=negative?-value:value;
    }
    return nan||(pos&&neg)?0x7fc00000:pos?0x7f800000:neg?0xff800000:packAccumulator(acc);
  });
}
// Binary32 accumulation oracle: the product is exact before accumulation, so a
// double holds it exactly, and Math.fround after each addition is correctly
// rounded FP32 round-to-nearest-even (the exact sum of two binary32 values has
// at most 50 significant bits, inside double's 53).
//
// This is the reference for the MOE_MXFP4_FP32 lane. It deliberately disagrees
// with dotReference: that one sums exactly and rounds once.
function dotReferenceFp32(klen,acts,weights,scales) {
  return Array.from({length:weights[0].length},(_,j)=>{
    let acc=0,nan=false,pos=false,neg=false;
    for(let k=0;k<klen;k++) {
      const a=acts[k],e=(a>>>7)&255,f=a&127,w=weights[k][j],s=scales[k>>>5][j];
      const coeff=coefficients[w&7],negative=!!((a>>>15)^(w>>>3));
      if(s===255 || (e===255 && (f!==0 || coeff===0))) {nan=true;continue;}
      if(e===255) {if(negative) neg=true;else pos=true;continue;}
      const m=e===0?f:128+f;
      // product = m*coeff * 2**(max(e,1)+s-262), exact in double
      const p=Math.fround(Math.fround(m*coeff)*Math.pow(2,Math.max(e,1)+s-262));
      const sp=negative?-p:p;
      if(Number.isNaN(sp)) {nan=true;continue;}
      if(!Number.isFinite(sp)) {if(sp>0) pos=true;else neg=true;continue;}
      acc=Math.fround(acc+sp);
    }
    if(nan||(pos&&neg)) return 0x7fc00000;
    if(pos) return 0x7f800000;
    if(neg) return 0xff800000;
    const buf=new ArrayBuffer(4); new DataView(buf).setFloat32(0,acc);
    return new DataView(buf).getUint32(0);
  });
}
module.exports={dotReference,dotReferenceFp32,packAccumulator,roundShift};