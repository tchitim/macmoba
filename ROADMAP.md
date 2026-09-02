# MacMoba 功能清單（對照 MobaXterm）

驗證狀態請看 [STATUS.md](STATUS.md)；已完成功能的用法看 [README.md](README.md)。
本檔只回答一件事：**MobaXterm 有的，我們做了沒有？接下來做什麼？**

---

## ✅ 已實作

| MobaXterm 功能 | MacMoba |
|---|---|
| SSH 分頁終端 | ✅ SwiftTerm + SwiftNIO SSH，xterm-256color |
| 分割畫面 | ✅ ⌘D / ⇧⌘D，可合併既有分頁進來 |
| MultiExec（多終端同步輸入） | ✅ ⇧⌘B |
| SFTP 檔案瀏覽器 | ✅ 含三方向拖放、遞迴資料夾、傳輸狀態面板 |
| 遠端檔案本機編輯 | ✅ Edit Locally，存檔自動回傳 |
| Port forwarding -L / -R | ✅ 圖形化 tunnel 管理 |
| Session 管理 + 資料夾分組 | ✅ 拖放分組、Connect All |
| 主密碼保險庫 | ✅ scrypt + AES-256-GCM，與 Electron 版相容 |
| 本機終端分頁 | ✅ ⌘T（登入 shell） |
| Quick Connect | ✅ ⌘K，`user@host:port` 不存檔直連 |
| 匯入既有設定 | ✅ `~/.ssh/config`（MobaXterm 是匯入 PuTTY） |
| 終端搜尋 | ✅ ⌘F / ⌘G |
| 終端配色主題 | ✅ View 選單 6 種（MacMoba Dark / Solarized Dark·Light / Nord / Dracula / GitHub Light） |
| 終端通知（bell） | ✅ 背景時響鈴發 macOS 通知＋Dock 跳動，5 秒節流 |
| Session 記錄（logging） | ✅ ⇧⌘L 開關，寫到 ~/Documents/MacMoba Logs/，escape 已濾掉 |
| 金鑰認證 | ✅ ed25519 / ECDSA，含 passphrase 加密金鑰 |
| Host key 驗證 | ✅ SHA256 指紋 pin（MobaXterm 也有） |
| Dynamic forwarding -D（SOCKS5） | ✅ tunnel 方向選 Dynamic，瀏覽器指到 SOCKS5 127.0.0.1:<port> |
| ProxyJump / 跳板機 | ✅ session 編輯器選「Via jump host」，bastion 的 direct-tcpip channel 當第二段 transport |
| 複製貼上強化 | ✅ 選取即複製、右鍵／中鍵貼上、多行與控制字元貼上前確認、⇧⌘V 併成一行 |
| 命令片語 / Macros | ✅ 側邊欄 Macros 區、⌃⌘1…⌃⌘9、多行、可選不按 Enter、存在加密 vault |
| 多視窗 | ✅ ⌘N 開新視窗，分頁各自獨立，vault／sessions／macros／tunnels 共用 |
| VNC | ✅ **內建分頁**（RoyalVNCKit，MIT），可經 SSH session 通道連線 |
| Mosh | ✅ **當成終端分頁**：先用 SSH 跑 `mosh-server new -s`，解析 `MOSH CONNECT <port> <key>`，再把 port/key 交給**內附的 mosh-client**（真的 mosh C++ core，1.4.0，靜態編、只依賴系統函式庫）。UDP 斷線可續、可 roaming，實測 pause 容器 12 秒後照樣接回去。⚠️ **GPLv3**：以獨立行程執行，並隨附 COPYING 與書面 source offer |
| Telnet | ✅ **當成終端分頁**（RFC 854 協商：ECHO / SGA / TERMINAL-TYPE / NAWS），**可以 split、broadcast、記錄、搜尋**，因為它走的就是既有的 terminal pane。明碼傳輸，所以編輯器裡有警告，圖示與側邊欄顏色也和 SSH 區隔 |
| RDP | ✅ **內建分頁**（自建 FreeRDP 3.30.0 靜態庫 + C shim）：NLA/CredSSP、憑證指紋確認、滑鼠鍵盤與快捷鍵、**動態解析度**、**剪貼簿雙向（文字／圖片／檔案）**、**資料夾分享**；全部對真 Windows AD server 驗證過 |

---

## 📋 待實作（依價值排序）

### 高價值（日常會用到）

（清空了）

~~FTP / FTPS~~ ✅ **做好了**：session 種類多了 FTP，開起來是**一個純檔案瀏覽器分頁**
（沒有終端機——FTP 本來就沒有 shell）。用的是跟 SFTP 同一個面板：上傳、下載、
拖放、改名、遞迴刪除、edit locally 全部共用，靠 `RemoteFileService` 這個 protocol
把兩種傳輸抽象起來。加密可選 None 或 **implicit TLS**；選 None 時編輯器會跳
跟 Telnet 同一種等級的警告。**explicit AUTH TLS 還沒有**，原因見 STATUS.md。

### ⏸ 卡在上游（不是不做，是現在做不了）

**Keyboard-interactive 認證（2FA/OTP）** — NIOSSH **0.15.0（最新版）還沒做**。
`NIOSSHUserAuthenticationOffer.Offer` 只有 privateKey / password / hostBased / none，
連「提出這個方法」都沒有接口；而且 message id 60 在 `SSHMessages.swift` 被寫死解析成
`UserAuthPKOKMessage`（公鑰），server 送的 `SSH_MSG_USERAUTH_INFO_REQUEST` 同樣是 60
但 payload 完全不同，一定解析失敗。auth 狀態機是 internal，我們這層攔不到。
上游有 PR [#242](https://github.com/apple/swift-nio-ssh/pull/242)（2026-07-01，RFC 4256
client 端），但 **13 個檔案 +1099 行、零 review、有 merge 衝突、七月一日之後沒動靜**。
要現在就要，只能 fork swift-nio-ssh 並自行維護一份「沒人審過的認證狀態機修改」——
對一個管理真實憑證的 SSH client 來說不划算。**建議：等上游合併後升版即可。**

### RDP 還缺的（對照 Microsoft Windows App 的選項）

channel 都已經編進 FreeRDP 了，只差接線與 UI：

~~1. 剪貼簿共用（cliprdr）~~ ✅ **做好了**（純文字雙向）
~~2. 視窗縮放時同步改遠端解析度（disp）~~ ✅ **做好了**

還沒做的：

~~1. 資料夾／磁碟重導（rdpdr）~~ ✅ **做好了**（session 編輯器的 Folders 區，可加多個）

~~1. 音訊（rdpsnd）~~ ✅ **做好了**：加 `/sound`，改用真正的 macOS AudioQueue backend。
   log 會寫 `Loaded mac backend for rdpsnd`（之前是 fake，收到聲音就直接丟掉）。
   ⚠️ **只驗證到「真的 backend 有載入」**——手邊的 xrdp 測試容器沒有
   pulseaudio-module-xrdp，不會真的送聲音出來，所以「聽得到」還沒驗過。
   麥克風輸入（audin）是另一件事，還沒做。
~~3. 剪貼簿的檔案~~ ✅ **做好了**（雙向，promise + 背景補實體檔，200MB 以上只留 promise）
~~4a. Retina 原生解析度~~ ✅ **做好了**：向 server 要的是**像素**不是點，
   而且 layer 的 `contentsScale` 也跟著設——之前 `requestResize` 已經有乘
   scale，但 layer 還停在 1，等於**要來的 Retina 像素在合成時又被降回去**。
   ⚠️ 手邊三台螢幕都是 1:1，**Retina 本身在本機驗不到**；算式本身有單元測試
   （`RDPDesktopSizeTests`，1x/2x/1.5x/邊界都測了）。

~~4b. 指定固定解析度~~ ✅ **做好了**：session 編輯器多了 Display 區，
   可選「Fit to window」（預設，維持舊行為）或「Fixed size」＋自填解析度。
   選 fixed 時**不送 `/dynamic-resolution`**——既然要固定，就不該讓 server
   還能重新協商；resize 也直接不送，改成把桌面縮放進 pane。

~~4c. 全螢幕~~ ✅ **做好了**：View ▸ Full Screen Session（⌃⇧⌘F），
   **側邊欄和分頁列一起收起來**，遠端桌面吃滿整個螢幕。
   只對 VNC/RDP 分頁可用；用綠燈或系統的 Exit Full Screen 離開也會還原
   （有監聽 `didExitFullScreenNotification`，否則側邊欄會收著回不來）。
   Esc **故意不解除**——那顆鍵要送給遠端。

~~4d. 多螢幕~~ ✅ **做好了，使用者在 MBA 實測通過**：session 編輯器的
   Display 區多了「Use all displays」。**只有全螢幕（⌃⇧⌘F）才會鋪開**——
   平常還是待在分頁裡，不然等於霸佔整台機器。
   做法：把每個螢幕換算成 RDP monitor（`RDPMonitorLayout`，17 項測試），
   server 送**一整片涵蓋所有螢幕的 framebuffer**，然後**每個螢幕開一個
   borderless 視窗**、各自 crop 自己那塊；滑鼠座標會加回自己的 offset。
   ⚠️ **只有一個螢幕時自動退回單螢幕模式**（已在真 AD server 上驗過沒有回歸）。
   **驗收：MBA ＋ 4K 外接雙螢幕，兩個螢幕都出畫面、第二個螢幕的滑鼠落點正確**
   （見 STATUS.md）。這台開發機只有一個螢幕，前後花了六個版本才收斂——
   每個 bug 都只在特定螢幕組合下才現形。

### 低價值 / 之後再說

~~1. known_hosts 管理 UI~~ ✅ **做好了**：File ▸ Trusted Hosts…
   **SSH host key 和 RDP 憑證兩個 store 一起列**（分兩區），可以看指紋、
   單筆「Forget」（有確認對話框）。加了 RDP 憑證 pin 之後這件事更需要做——
   等於自己多開了一個沒有出口的 store。
~~2. Session 匯出 / 匯入~~ ✅ **做好了**：File ▸ Export / Import Sessions…
   預設**不帶密碼**；要帶密碼就**一定加密**（scrypt + AES-256-GCM，跟 vault 同一套），
   沒有「明碼但含密碼」這個選項。匯入是**只增不減**，重複匯入同一個檔不會變多。
~~3. zmodem（rz/sz）~~ ✅ **兩個方向都做好了**：接收（遠端 `sz`）在 v1.42，
   發送（Session ▸ Send File (ZMODEM)…）在 v1.43，各自跟真的 lrzsz 對傳對測過；
   檔案拖進終端 pane 也能直接送。使用者在 v1.96 實機驗收雙向通過。
   送檔時**不必自己先跑 `rz`**——那句是 MacMoba 自己打的，先跑反而會兩端一起卡住。
~~4. 分頁拖曳排序~~ ✅ **做好了**：拖過去就重排（放開前就會即時預覽位置），
   **只動順序，不動連線**——連線、pane、scrollback 全都留著。
   往右拖會落在目標右邊、往左拖落在左邊，兩個方向都實測過。

---

## ❌ 不打算做（macOS 上不合理）

| MobaXterm 功能 | 原因 |
|---|---|
| 內建 X11 server | macOS 用 XQuartz；重造一個不划算 |
| Serial | 有成熟的 macOS 原生 app；需求也低（Telnet 已改為實作，見上） |
| Cygwin 工具集（bash/ls/grep…） | macOS 本身就是 Unix |
| 外掛系統 | 個人工具，先不做擴充框架 |
| RSA 金鑰 | SwiftNIO SSH 上游不支援（見 STATUS.md 已知限制） |
| **ssh-agent 認證 / forwarding** | **上游擋住**：`NIOSSHPrivateKey` 只能用具體金鑰型別建立（ed25519 / ECDSA / Secure Enclave P256），沒有自訂簽章器的接口——但 agent 的重點就是「金鑰不外流、由 agent 代簽」，所以做不到。agent forwarding 也不行：NIOSSH 的 `SSHChannelType` 只有 session / directTCPIP / forwardedTCPIP，收不到 `auth-agent@openssh.com` channel。<br>替代方案：加密金鑰已支援（填 passphrase 一次），硬體金鑰可走 Secure Enclave P256。 |

---

## 效能（不是 MobaXterm 對照,是自己量出來的）

數字來自 `TerminalThroughputBenchmark`(release build,`MACMOBA_BENCH=1`)。

| 項目 | 現況 |
|---|---|
| feed ASCII | 51 MB/s ＝ 53.6M 字元/秒 |
| feed 帶色 ANSI | 27 MB/s |
| feed CJK | **31.9 MB/s**(原本 11.8,見下) |
| draw 1200×800 | 3.5 ms/frame |
| draw 2560×1440 | 8.1 ms/frame |
| copy 全選 10,000 行 | 17 ms |

~~CJK 解析比 ASCII 慢一個數量級~~ ✅ **做好了**:每字元 5.3M → 14.2M(2.7 倍),
與 ASCII 的差距從 10.1 倍收到 3.8 倍。做法與驗證見 `Vendor/SwiftTerm/README.md`
與 STATUS.md;SwiftTerm 因此從版本相依改成 `Vendor/` 裡的分支。

還沒做的:

~~1. Metal 算繪完全沒被量到~~ ✅ **量到了**(`scripts/check-metal-in-app.sh`,
   `Sources/terminal-render-bench`):把終端機放進真的視窗、關掉 vsync、
   數**真正畫出來的** frame。

   | 視窗 | CoreGraphics | Metal | 倍數 |
   |---|---|---|---|
   | 1200×800 | 4.0 ms(250 fps) | **0.7 ms(1450 fps)** | ~6× |
   | 2560×1440 | 8.5 ms(117 fps) | **0.97 ms(1035 fps)** | ~8.8× |

   **README 那句「明顯更順」是真的,而且解析度越高差越多。**
   實務上的意義在 60fps 的 16.7 ms 預算:1440p 單格 CG 就吃掉 8.5ms(51%),
   **四格分割 34ms 直接超支**;Metal 四格只要 3.9ms(23%)。
   也就是說 GPU 算繪**正好在這個 App 的主場景**(大視窗＋分割)才真的重要。

   ⚠️ 量測上有兩個坑,都寫在 `terminal-render-bench` 的註解裡:
   (a) 先前用「餵一段資料計時」量到的是**解析器**不是算繪(6.4MB/0.14s = 45 MB/s);
   (b) 直接數 `draw(in:)` 會得到 40,000 fps ——因為 renderer 拿不到 frame semaphore
   時會立刻返回,那些空轉也被算進去了。真正畫出來的 frame 要用耗時區分
   (4,473 次有畫 vs 114,748 次空轉)。

   ✅ **也驗過在打包後的 .app 裡 Metal 真的會啟用**(shader 在
   `Contents/Resources` 的 SwiftPM 資源包裡,並把 `.build` 那份藏起來)。
   這件事值得單獨驗:libghostty 那邊就是栽在同一類問題上,而 SwiftTerm 的
   `MetalTerminalRenderer.candidateBundles` 正是為此手寫的繞法——它成立。
2. **draw 隨 pane 數線性成長,而分割正是本 App 的賣點** — 1440p 一格就吃掉
   60fps 預算(16.7 ms)的一半,四格必然超支。上表是單一 view,是樂觀下限。
3. **混合內容仍走慢路徑** — `handlePrint` 的 ASCII 批次寫入是**整段全有全無**:
   一個 CJK byte 就讓**整個 chunk**(連同裡面的 ASCII)退回逐字元處理。
   把 ASCII 連續段切出來各自批次寫,對中英混排的 log 會有效。

---

## 下一步建議

沒有特別偏好的話，我會照這個順序做：
~~配色主題~~ ✅ → ~~session logging~~ ✅ → ~~ProxyJump~~ ✅ →
~~SOCKS5(-D)~~ ✅ → ~~ssh-agent~~ ❌（上游擋住，已移到「不做」並說明原因）

**高價值與中價值都清完了**：
~~複製貼上強化~~ ✅ → ~~Macros 命令片語~~ ✅ → ~~多視窗~~ ✅ →
keyboard-interactive ⏸（上游還沒做，等 PR #242 合併）。

剩下的都是低價值項目，沒有特別順序。
