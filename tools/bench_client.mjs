// 管線延遲量測：在 Mac 本機連線，frame timestamp（擷取時的 host time）和 process.hrtime 同一個時鐘
// 量到的是「擷取 → 編碼 → 送到 socket 對端」，不含 Wi‑Fi 與解碼
// 用法：node tools/bench_client.mjs ws://127.0.0.1:8765/stream 秒數
const url = process.argv[2], secs = Number(process.argv[3] ?? 15);
const lat = []; let frames = 0, bytes = 0, keys = 0;
const ws = new WebSocket(url); ws.binaryType = 'arraybuffer';
ws.onopen = () => ws.send(JSON.stringify({ type: 'hello', client: 'bench', width: 2256, height: 1504 }));
ws.onmessage = (ev) => {
  if (typeof ev.data === 'string') return;
  const now = Number(process.hrtime.bigint() / 1000n);
  const dv = new DataView(ev.data);
  const ts = Number(dv.getBigUint64(1, false));
  frames++; bytes += ev.data.byteLength; if (dv.getUint8(0) & 1) keys++;
  if (frames > 30) lat.push((now - ts) / 1000);   // 前 30 幀暖機不算
};
setTimeout(() => {
  ws.close();
  lat.sort((a, b) => a - b);
  const q = (p) => lat.length ? +lat[Math.min(lat.length - 1, Math.floor(p * lat.length))].toFixed(1) : null;
  const avg = lat.length ? +(lat.reduce((a, b) => a + b, 0) / lat.length).toFixed(1) : null;
  console.log(JSON.stringify({ fps: +(frames / secs).toFixed(1), mbps: +(bytes * 8 / secs / 1e6).toFixed(2), keys, latMs: { avg, p50: q(0.5), p95: q(0.95), max: q(1) } }));
  process.exit(0);
}, secs * 1000);
