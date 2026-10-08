// 協定自測：模擬 Surface 接收端，驗證第 4 節協定與第 6 節第 4 項（重連立刻有畫面）
// 用法：node tools/test_client.mjs ws://<Mac IP>:8765/stream [秒數]
const url = process.argv[2] ?? 'ws://127.0.0.1:8765/stream';
const secs = Number(process.argv[3] ?? 4);
let fails = 0;
const check = (ok, msg) => { console.log((ok ? '  ✔ ' : '  ✘ ') + msg); if (!ok) fails++; };

function nalTypes(buf) {
  const types = [];
  for (let i = 0; i + 4 < buf.length; i++) {
    if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 0 && buf[i + 3] === 1) types.push(buf[i + 4] & 0x1f);
  }
  return types;
}

function session(label, { requestKeyframeAt } = {}) {
  return new Promise((resolve) => {
    console.log(`\n[${label}] 連線 ${url}`);
    const t0 = performance.now();
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    const st = { gotConfig: false, configBeforeFrame: null, frames: 0, keys: 0, bytes: 0, firstFrameMs: null, lastTs: -1n, monotonic: true, keyAfterReq: null, reqAt: null };
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: 'hello', client: 'surface', width: 2256, height: 1504 }));
      ws.send(JSON.stringify({ type: 'unknown-type-test' }));
      if (requestKeyframeAt) setTimeout(() => { st.reqAt = performance.now(); ws.send(JSON.stringify({ type: 'keyframe' })); }, requestKeyframeAt);
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        const m = JSON.parse(ev.data);
        if (m.type === 'config') {
          if (!st.gotConfig) console.log('  config:', ev.data);
          st.gotConfig = true;
          if (st.configBeforeFrame === null) st.configBeforeFrame = st.frames === 0;
          st.codec = m.codec;
        }
        return;
      }
      const b = new Uint8Array(ev.data);
      const key = (b[0] & 1) === 1;
      const ts = new DataView(ev.data).getBigUint64(1, false);
      if (ts <= st.lastTs) st.monotonic = false;
      st.lastTs = ts;
      const payload = b.subarray(9);
      if (st.frames === 0) {
        st.firstFrameMs = performance.now() - t0;
        const t = nalTypes(payload);
        st.firstKey = key;
        st.firstNals = t;
        // 用 SPS 驗 codec 字串
        const spsIdx = (() => { for (let i = 0; i + 8 < payload.length; i++) if (payload[i]===0&&payload[i+1]===0&&payload[i+2]===0&&payload[i+3]===1&&(payload[i+4]&0x1f)===7) return i+4; return -1; })();
        if (spsIdx >= 0) st.spsCodec = 'avc1.' + [1,2,3].map(k => payload[spsIdx+k].toString(16).padStart(2,'0')).join('');
      }
      if (key) { st.keys++; if (st.reqAt && st.keyAfterReq === null && performance.now() > st.reqAt) st.keyAfterReq = performance.now() - st.reqAt; }
      st.frames++; st.bytes += b.length;
    };
    ws.onerror = (e) => console.log('  錯誤', e.message ?? e);
    setTimeout(() => { ws.close(); resolve(st); }, secs * 1000);
  });
}

const a = await session('第一次連線', { requestKeyframeAt: 1500 });
check(a.gotConfig && a.configBeforeFrame, 'config 在第一個影像之前送達');
check(a.frames > 0, `收到影像 ${a.frames} 幀（${(a.frames / secs).toFixed(1)} fps，${(a.bytes * 8 / secs / 1e6).toFixed(2)} Mbps）`);
check(a.firstKey === true, `第一幀是關鍵幀（${a.firstFrameMs?.toFixed(0)} ms 內到達）`);
check(a.firstNals?.[0] === 7 && a.firstNals?.[1] === 8 && a.firstNals?.includes(5), `關鍵幀 NAL 順序 SPS/PPS/IDR：[${a.firstNals}]`);
check(a.spsCodec === a.codec, `codec 字串與 SPS 相符（${a.codec}）`);
check(a.monotonic, 'timestamp 單調遞增');
check(a.keyAfterReq !== null, `送 {"type":"keyframe"} 後 ${a.keyAfterReq?.toFixed(0)} ms 收到關鍵幀`);

const b = await session('斷線後重連');
check(b.firstKey === true && b.firstFrameMs < 500, `重連後第一幀是關鍵幀，${b.firstFrameMs?.toFixed(0)} ms 到達`);

console.log(fails ? `\n${fails} 項失敗` : '\n全部通過');
process.exit(fails ? 1 : 0);
