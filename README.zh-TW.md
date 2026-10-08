# SideScreen42：把任何有瀏覽器的筆電，變成 Mac 的無線延伸螢幕

**42 系列**作品之一，作者 [Okle42](https://github.com/Okle42)。追蹤看更多真的做完、能用的工具。

[English](README.md)

**一句話：Mac 建一個真的虛擬螢幕，用硬體 H.264 透過家裡的 Wi‑Fi 傳出去，旁邊那台筆電開一個瀏覽器分頁，全螢幕播放。在 Mac 的系統設定裡，它就像一台真的外接螢幕，可以排列位置，視窗也能拖過去。**

我的 Mac mini 旁邊放著一台閒置的 Surface Laptop 2。它的 Mini DisplayPort 只能輸出、不能輸入，接線行不通。市面上有商用軟體，但我想要的是：程式小到一次讀得完、Windows 那邊什麼都不用裝、沒人在看的時候不吃資源。

![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![deps](https://img.shields.io/badge/dependencies-0-brightgreen) ![license](https://img.shields.io/badge/license-MIT-green)

---

## 運作方式

```
 Mac（傳送端，本 repo）                             筆電（接收端）
┌───────────────────────────────────┐            ┌──────────────────────────────┐
│ CGVirtualDisplay  虛擬螢幕        │            │ Edge／Chrome 全螢幕          │
│   ↓                               │            │   ↑                          │
│ ScreenCaptureKit  NV12＋游標      │ WebSocket  │ WebCodecs 硬體解碼           │
│   ↓                               │ ─────────► │   ↑                          │
│ VideoToolbox  H.264 High、無 B 幀 │   :8765    │ receiver/index.html          │
│   ↓                               │ ◄───────── │ hello／要求關鍵幀            │
│ Network.framework  WebSocket      │            │                              │
└───────────────────────────────────┘            └──────────────────────────────┘
```

- **傳送端**：Swift Package，只用 Apple 原生框架，沒有任何第三方套件。分成三部分：共用核心（`SideScreenCore`）、**選單列 App**（`SideScreen42.app`）、命令列工具（`sidescreen`）。裝了 Command Line Tools 就能編譯，不需要 Xcode 專案。
- **接收端**：只有一個 HTML 檔。在 Edge 或 Chrome 直接開本機檔案就能用（`file://` 算安全環境，WebCodecs 可以用）。筆電上什麼都不用裝，也不限 Windows。

## 實測數據

測試環境：Mac mini M4、macOS 27.0.1；接收端是 Surface Laptop 2（i5‑8250U、Intel UHD 620）、Edge 154。畫面 2256 × 1504，最高 60 fps。

傳送端的資源消耗用 `tools/bench.sh` 量：先閒置 20 秒，再用全螢幕 60 fps 測試圖（`tools/testpattern.swift`）加本機用戶端串流 20 秒。CPU 是單核百分比，由 `ps` 的累計 CPU 時間算出。

| | 優化前 | 優化後 |
|---|---|---|
| CPU，沒人連線 | 1.8 % | **0.1 %** |
| CPU，串流 60 fps | 5.8 % | 5.7–6.1 % |
| 畫面每秒變 60 次時實際送出 | 57.5 fps | **60.0 fps** |
| 每幀編碼時間（平均／最大） | — | **9.0／10.7 ms** |
| 交給 socket → 送完，最慢的一幀 | — | **≤ 1 ms**（本機） |
| 記憶體（RSS） | 44 MB | 44 MB |

編碼和送出時間都是在程式內部、用同一個單調時鐘量的。跨 Wi‑Fi 時，「最慢的一幀」可以看出網路有沒有卡住。

**更正。** 這份 README 第一版寫「擷取 → 送上 socket 1.2 ms」。那個數字是拿每一幀的時間戳，去跟本機測試用戶端的時鐘相減算出來的。後來發現 ScreenCaptureKit 的時間戳帶著一段會隨時間漂移的偏移（同一版程式幾個小時後量出 −4 ms），所以絕對值是錯的。Mac 端真正的耗時大約 10 ms，就是編碼加送出。優化前後的比較仍然成立，因為兩次是在同一個偏移量下量的：修正擷取間隔後，p95 的延遲抖動少了約 8 ms。我也試過把低延遲編碼器（`h264.rtvc`）換成一般的硬體編碼器（`ave.avc`），每幀要 15–16 ms，比較慢，所以維持低延遲版。

接收端（Surface 上的 Edge，數字來自網頁自己的統計）：硬體解碼，**每幀 1–2 ms**（只有第一個關鍵幀約 43 ms），測試期間解碼錯誤 0、丟幀 0。

**還沒量的**：跨 Wi‑Fi 從 Mac 畫面到筆電畫面的整體延遲。兩台時鐘沒有同步，要用手機慢動作同時拍兩個螢幕才量得到。主觀感受是拖視窗沒有感覺到延遲。

### 實際用了一個晚上的紀錄

一晚 4 小時的 log（同一條連線，一次都沒斷）：

- 畫面大多是靜止的：擷取 fps 中位數只有 **3**，平均 8.4。省資源的關鍵就在畫面沒變時待機。
- 傳送端的背壓一共丟了 438 幀，分布在 43 個 5 秒區段，集中在幾分鐘忙碌的時候。有幾次發生在每秒只有 2–3 幀的時候，代表有一幀卡在 Wi‑Fi 上超過 1 秒，看起來是筆電 Wi‑Fi 的省電模式，不是 Mac 的問題。
- log 也抓到一個 bug：背壓丟幀後要關鍵幀時，程式會**把最後一張舊畫面再編成一個額外的關鍵幀**。關鍵幀是最大的一種幀，偏偏在網路最塞的時候多送。現在改成讓下一張新畫面直接編成關鍵幀，50 ms 內都沒有新畫面（畫面靜止）才拿舊畫面重編。
- 統計紀錄新增關鍵幀數、編碼時間、最慢送出時間；只在畫面有在動時才寫（另加每分鐘一次心跳），整晚的 log 也讀得完。

### 做了哪些優化

1. **沒人看就待機。** 沒有用戶端連線時完全不編碼，擷取降到每秒 2 張，只為了手上隨時有最新一張畫面。有人連上就恢復 60 fps，並立刻把手上那張編成關鍵幀，所以就算畫面是靜止的，連上約 40 ms 就有畫面。
2. **擷取間隔比 1/fps 放寬 10%。** `minimumFrameInterval` 設剛好 1/60 秒時，螢幕時間的微小抖動會讓 ScreenCaptureKit 跳過約 4% 的幀，被跳過的幀還會拖慢後面幾幀。實際擷取仍然被螢幕的 60 Hz 限住。光這一項，p95 的延遲抖動就少了約 8 ms。
3. **封包零複製。** 編碼器直接把 9 byte 標頭、SPS/PPS 和 Annex B 本體寫進最終的 WebSocket 訊息，原本要複製兩次。
4. **socket 標記 `serviceClass = .interactiveVideo`**，讓 Wi‑Fi（WMM）走視訊優先佇列。
5. **背壓控制。** 還有 3 幀沒送完時就丟掉非關鍵幀，並把下一幀改編成關鍵幀。寧可掉幀，也不讓延遲越積越多。

## 怎麼用

### 選單列 App

```bash
git clone https://github.com/Okle42/SideScreen42.git
cd SideScreen42
scripts/make-app.sh          # 建置、簽章、安裝到 /Applications/SideScreen42.app 並打開
```

第一次打開時，macOS 會跟 SideScreen42 要「螢幕與系統錄音」權限。允許之後選「結束並重新打開」，App 就會自動開始分享。

選單列圖示用形狀表示狀態：一台螢幕＝分享中、等接收端；兩台螢幕＝有人在看；斜線＝已停止。選單裡有：誰在看、幾 fps、**拷貝接收網址**、**停止／開始分享**、**在Finder中顯示接收網頁**、關於、設定⋯（⌘,）、結束。

設定：解析度、碼率、埠（改了會立刻重新開始分享，接收端會自動重連）、**在登入時打開**（預設關）、打開 App 時自動開始分享、在選單列中顯示，以及記錄檔位置（`~/Library/Logs/SideScreen42/sidescreen.log`，接續寫入，超過 5 MB 輪替）。

打包腳本有 Apple Development 或 Developer ID 憑證就用它簽章，這樣重新建置後「螢幕錄影」授權不會失效；沒有憑證就用 ad-hoc 簽章，每次重建可能要重新允許一次。

### 命令列

```bash
swift build -c release
.build/release/sidescreen
```

啟動後會印出像這樣的網址：

```
➜ 在接收端連線：ws://192.168.1.20:8765/stream
```

### 筆電這邊

用 Edge 或 Chrome 開 `receiver/index.html`，貼上這個網址，按「連線」。快捷鍵：**F**（或按兩下畫面）切換全螢幕、**S** 顯示統計、**C** 顯示／隱藏連線面板。網址會被記住，斷線會自動重連。

接著在 Mac 打開 **系統設定 → 顯示器 → 排列**，把 `SideScreen (Surface)` 拖到筆電實際擺放的那一側。虛擬螢幕每次都用同一個序號，所以 macOS 會記住這個位置。

命令列參數：

| | |
|---|---|
| `--port 8765` | WebSocket 埠 |
| `--bitrate 12` | 平均碼率（Mbps），瞬間上限是 1.5 倍 |
| `--fps 60` | 幀率 |
| `--mode 1504x1003` | 預設模式（單位 point，HiDPI）：`1504x1003` 看起來跟 Windows 150% 一樣大；`1128x752` 像素一比一，最銳利；`1880x1253` 空間最大 |
| `--dump out.h264` | 同時把串流寫成檔案（`ffplay out.h264` 可播） |

結束 App（或命令列按 Ctrl+C）時，虛擬螢幕會一起移除，上面的視窗會回到其他螢幕。如果擷取被外部停掉（例如按了 macOS 選單列的**停止共享**，上面顯示的是正在錄影的 App 名稱），會在 3 秒後自動接回；真的要停，請用選單裡的「停止分享」，命令列版則按 Ctrl+C。

### 權限

- **螢幕錄影**：系統設定 → 隱私權與安全性 → 螢幕與系統錄音，允許 SideScreen42；命令列版則是允許你用來執行它的終端機 App（終端機、Ghostty、iTerm…）。
- **防火牆**：第一次執行若跳出詢問，允許連入連線。

### 測試與工具

| | |
|---|---|
| `node tools/test_client.mjs ws://<ip>:8765/stream` | 協定自測：config 比第一幀先到、第一幀是含 SPS/PPS/IDR 的關鍵幀、`codec` 字串與 SPS 相符、時間戳單調遞增、要求關鍵幀有回應、重連能恢復 |
| `tools/bench.sh` | 上面那張表的 CPU／記憶體／編碼時間量測 |
| `swift tools/testpattern.swift 20` | 在虛擬螢幕上顯示 20 秒全螢幕 60 fps 測試圖（移動色條、可數掉幀的 60 格閃爍方塊、毫秒計時） |

## 通訊協定

協定很小，用任何語言都寫得出接收端。詳見 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

## 限制

- **`CGVirtualDisplay` 是 CoreGraphics 的私有 API。** 套件設定支援 macOS 14 以上，但我只在 macOS 27.0.1 上實測過，Apple 任何一版都可能改掉這個 API。宣告放在 `Sources/CVirtualDisplay/include/CGVirtualDisplay.h`，是在 macOS 27.0.1 上用 Objective‑C runtime 逐一核對過的。
- **只有單向。** 筆電上的觸控、滑鼠、鍵盤不會傳回 Mac，延伸螢幕要用 Mac 自己的滑鼠鍵盤操作。
- **沒有聲音、沒有加密、沒有密碼。** 設計給家用區網。同一個網路上知道埠號的人都看得到畫面，不要在公共 Wi‑Fi 上執行。
- **一次只服務一個用戶端。** 新連線會取代舊的。如果同時開了兩個接收分頁，它們會一直互相踢掉對方。
- **不檢查 WebSocket 路徑。** Network.framework 拿不到 request path，所以任何路徑都連得上。
- 接收網頁的介面文字是繁體中文。

## 怎麼做出來的

這是兩個 Claude Code 在一個下午合作做出來的，兩台電腦各一個。Windows 那邊先查清楚筆電的實際規格，寫好交接文件（協定和分工），再做接收端；Mac 這邊做傳送端。兩邊只透過共用資料夾裡的 Markdown 檔溝通（Mac 這邊用 SSH 讀寫），一共三份：交接、回報、回覆。雙方都是看了對方的測試數據，才抓到自己那半邊的 bug：
- 接收端：第一個關鍵幀比解碼器設定好還早到，被丟掉了。
- 傳送端：還沒完成握手的連線，會把正常連著的那條取代掉。

## 致謝

虛擬螢幕的做法和私有 API 宣告，參考了 Stengo 的 [DeskPad](https://github.com/Stengo/DeskPad)（MIT）。

## 授權

MIT © 2026 Okle42
