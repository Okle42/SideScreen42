# SideScreen42 protocol

[繁體中文在下方](#繁體中文)

One WebSocket connection, `ws://<Mac IP>:8765/stream` (port set with `--port`; the path is not checked). The Mac is the server and serves **one client**; a new connection replaces the old one once its handshake completes.

## Mac → receiver: text (JSON)

Sent right after the connection opens, and again whenever resolution or codec parameters change:

```json
{"type":"config","codec":"avc1.640033","width":2256,"height":1504,"fps":60}
```

- `codec` is taken from the real SPS: `avc1.` + profile_idc, constraint flags, level_idc as hex (High@5.1 → `avc1.640033`).
- `width` / `height` are the encoded pixel size.

## Mac → receiver: binary (one message = one frame)

```
byte 0      flags: bit0 = 1 for a keyframe (IDR); other bits are 0
byte 1..8   timestamp in microseconds, uint64 big-endian, monotonic
            (the Mac's capture host time, mach_absolute_time based)
byte 9..    one complete H.264 access unit in Annex B (00 00 00 01 start codes)
```

- Every keyframe carries SPS and PPS in front of the IDR, so the receiver never needs a separate `description`.
- The first frame a new client gets is always a keyframe.
- No B-frames: decode order = display order.
- When the screen doesn't change, no frames are sent. That's normal; don't treat silence as a disconnect.
- Periodic keyframe at least every 2 s.

## Receiver → Mac: text (JSON)

```json
{"type":"hello","client":"surface","width":2256,"height":1504}
{"type":"keyframe"}
```

- `hello`: the receiver's physical screen size (currently only logged).
- `keyframe`: force the next frame to be a keyframe. Send it after connecting, after a decode error, or after dropping frames. If the screen is static, the Mac re-encodes its latest frame, so a keyframe arrives within about 40 ms either way.
- Unknown `type`s are ignored, never a reason to disconnect.

## Receiver tips (WebCodecs)

```js
decoder.configure({ codec, codedWidth: width, codedHeight: height,
                    optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' });
```

- Configure the decoder only after `isConfigSupported` resolves, then request a keyframe: one that arrived before configuration finished was dropped.
- If `decodeQueueSize` grows past ~3, drop delta frames and request a keyframe instead of falling behind.

---

## 繁體中文

一條 WebSocket 連線：`ws://<Mac IP>:8765/stream`。埠號用 `--port` 設定；路徑不檢查，任何路徑都連得上。Mac 是伺服器，一次只服務**一個用戶端**；新連線完成握手後，就會取代舊的那條。

**Mac → 接收端，文字（JSON）**：連線一建立就送一次 `config`，之後解析度或編碼參數有變時再送。`codec` 是從實際產生的 SPS 取出的（`avc1.` 後面接 profile_idc、constraint flags、level_idc 三個 byte 的十六進位），不是寫死的。

**Mac → 接收端，二進位（一個訊息＝一幀）**：
- 格式：第 0 byte 是 flags（bit0＝關鍵幀）；第 1–8 byte 是微秒時間戳（uint64 big-endian，單調遞增，用的是 Mac 擷取當下的系統時間）；第 9 byte 起是 Annex B 格式的完整 access unit。
- 每個關鍵幀前面都附 SPS/PPS，接收端不需要另外拿 `description`。
- 新用戶端收到的第一幀一定是關鍵幀。
- 沒有 B 幀，解碼順序就是顯示順序。
- 畫面沒變化時不會送幀，這是正常的，不要因此判定斷線。
- 至少每 2 秒送一個關鍵幀。

**接收端 → Mac，文字（JSON）**：
- `hello`：告知接收端螢幕的實體解析度，目前只寫進 log。
- `keyframe`：要求下一幀編成關鍵幀。連上後、解碼出錯或丟幀時送。就算畫面是靜止的，Mac 也會把最後一張畫面重編，所以大約 40 ms 內就會收到。
- 看不懂的 `type` 一律忽略，不會因此斷線。

**WebCodecs 接收端建議**：
- 等 `isConfigSupported` 回來、解碼器設定好之後，再要一次關鍵幀。設定完成前就到的關鍵幀已經被丟掉了。
- `decodeQueueSize` 超過 3 左右時，丟掉非關鍵幀並要求關鍵幀，不要讓畫面越落越後面。
