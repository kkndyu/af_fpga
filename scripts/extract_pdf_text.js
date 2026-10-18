// -----------------------------------------------------------------------------
// extract_pdf_text.js - pull readable text out of a PDF using only Node built-ins
// -----------------------------------------------------------------------------
//   node build/pdftxt/extract_pdf_text.js <input.pdf> [output.txt]
//
// Why: the AX7203B user manual and the peripheral tutorials are the only source
// for pin assignments (UART, etc.), and this machine has no pdftotext, no
// ghostscript and no working Python.  Node is available and has zlib built in,
// which is all a PDF needs: content streams are usually FlateDecode compressed.
//
// Limitations, stated up front:
//   * Chinese glyphs are almost always encoded through a CID font plus a
//     ToUnicode CMap, which this does not implement.  Chinese text will come out
//     as garbage or be dropped.
//   * That is acceptable for this purpose, because everything needed for pin
//     assignment is ASCII: net names like UART_TX, package pins like Y11, and
//     I/O site names like IO_L1P_T0_34.
//   * Text position is ignored, so reading order is not guaranteed.  Treat the
//     output as a searchable bag of strings, not as prose.
// -----------------------------------------------------------------------------

const fs = require('fs');
const zlib = require('zlib');

const inPath = process.argv[2];
const outPath = process.argv[3] || null;
if (!inPath) {
  console.error('usage: node extract_pdf_text.js <input.pdf> [output.txt]');
  process.exit(2);
}
if (!fs.existsSync(inPath)) {
  console.error('not found: ' + inPath);
  process.exit(2);
}

const buf = fs.readFileSync(inPath);
const latin = buf.toString('latin1');

// -----------------------------------------------------------------------------
// 1. Collect every stream ... endstream body, inflate the ones that are zlib
// -----------------------------------------------------------------------------
const chunks = [];
let pos = 0;
let streamCount = 0;
let inflated = 0;

while (true) {
  const s = latin.indexOf('stream', pos);
  if (s < 0) break;
  const e = latin.indexOf('endstream', s);
  if (e < 0) break;

  // Skip the EOL that follows the "stream" keyword.
  let dataStart = s + 'stream'.length;
  if (latin[dataStart] === '\r') dataStart++;
  if (latin[dataStart] === '\n') dataStart++;

  const body = buf.slice(dataStart, e);
  streamCount++;

  let text = null;
  try {
    text = zlib.inflateSync(body).toString('latin1');
    inflated++;
  } catch (err) {
    // Not zlib-compressed, or it is an image/other object.  Fall back to raw.
    text = body.toString('latin1');
  }
  chunks.push(text);
  pos = e + 'endstream'.length;
}

// -----------------------------------------------------------------------------
// 2. Extract the operands of text-showing operators
// -----------------------------------------------------------------------------
// Literal strings: ( ... ) with \( \) \\ escapes
// Hex strings: < ... >
// These appear before Tj, TJ, ' and ".
function unescapeLiteral(s) {
  return s.replace(/\\([nrtbf()\\]|[0-7]{1,3})/g, (m, g) => {
    if (/^[0-7]+$/.test(g)) return String.fromCharCode(parseInt(g, 8));
    const map = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f' };
    return map[g] !== undefined ? map[g] : g;
  });
}

const pieces = [];
for (const c of chunks) {
  if (!c) continue;

  // Literal strings
  const litRe = /\((?:\\.|[^\\()])*\)/g;
  let m;
  while ((m = litRe.exec(c)) !== null) {
    const inner = m[0].slice(1, -1);
    pieces.push(unescapeLiteral(inner));
  }

  // Hex strings of printable ASCII, e.g. <554152545F5458> = UART_TX
  const hexRe = /<([0-9A-Fa-f]{4,})>/g;
  while ((m = hexRe.exec(c)) !== null) {
    const hex = m[1];
    if (hex.length % 2 !== 0) continue;
    let s2 = '';
    for (let i = 0; i < hex.length; i += 2) {
      const ch = parseInt(hex.substr(i, 2), 16);
      if (ch >= 0x20 && ch < 0x7f) s2 += String.fromCharCode(ch);
      else s2 += '\u0000';
    }
    if (s2.replace(/\u0000/g, '').length >= 3) pieces.push(s2);
  }
}

// -----------------------------------------------------------------------------
// 3. Reduce to readable ASCII runs
// -----------------------------------------------------------------------------
const joined = pieces.join('\n');
const runs = joined.match(/[ -~]{3,}/g) || [];

// Deduplicate but keep first-seen order (document order roughly).
const seen = new Set();
const uniq = [];
for (const r of runs) {
  const t = r.trim();
  if (t.length < 3) continue;
  if (seen.has(t)) continue;
  seen.add(t);
  uniq.push(t);
}

// -----------------------------------------------------------------------------
// 4. Report
// -----------------------------------------------------------------------------
console.log('streams found      : ' + streamCount);
console.log('streams inflated   : ' + inflated);
console.log('text pieces        : ' + pieces.length);
console.log('unique ascii runs  : ' + uniq.length);

// Highlight anything that looks like a pin or peripheral name.
const interesting = uniq.filter((t) =>
  /UART|uart|RS232|rs232|CP210|CH340|FT232|IO_L\d|IO_[A-Z]?\d|^\s*[A-Z]{1,2}\d{1,2}\s*$/.test(t)
);
console.log('');
console.log('--- candidates containing UART / package pins / IO sites ---');
for (const t of interesting) console.log('  ' + t);

if (outPath) {
  fs.writeFileSync(outPath, uniq.join('\n'), 'utf8');
  console.log('');
  console.log('full list written to ' + outPath);
}
