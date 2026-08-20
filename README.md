# MacMoba

macOS 上的原生遠端連線工作站——SSH、Mosh、Telnet、Rlogin、SFTP/FTP、VNC、RDP、序列埠、網頁與本機終端，全部在同一個視窗裡。

用 Swift + SwiftUI 寫成，沒有 Electron；連線密碼收在本機加密保險箱，並附一支 CLI 讓腳本與 AI agent 反過來驅動它。

**[📖 入門指南](docs/getting-started.md)** · **[⬇️ 下載最新版](../../releases/latest)**

---

## 功能

**連線**
- SSH（多層跳板 `ssh -J` 鏈、gateway failover）、Mosh（斷網續連）、Telnet、Rlogin、序列埠（RS-232）
- VNC、RDP（NLA/CredSSP、跨螢幕、剪貼簿含檔案）、FTP/FTPS
- **遠端桌面輸入擷取**：點進畫面即接管鍵盤與滑鼠（⌃⌥ 放開），送的是實體鍵，所以組字交給遠端自己的輸入法；⌥⌘V／⌥⌘C 讓中文也能雙向貼上
- 網頁分頁，可指定走某個 SSH 連線的 SOCKS 隧道看內網頁面
- 本機終端分頁

**組織**
- 巢狀資料夾、顏色標籤、標記、備註、側邊欄搜尋
- 共用憑證物件，沿資料夾路徑往上繼承
- 密碼管理器參照（`op://`、`cmd:…`）——連線時才取，不落地
- 連線範本 + replacement token、自動化任務（連上自動執行、Expect/Send）

**終端**
- 分割窗格、MultiExec 廣播輸入、巨集、Session log、scrollback 搜尋
- SFTP 面板（Quick Look、chmod、隱藏檔、拖放上傳）
- ZMODEM 雙向傳檔（`rz`/`sz`）、貼上截圖自動上傳到遠端
- X11 forwarding（走 remote forward，需 XQuartz）

**工具**
- SSH 金鑰產生器（ed25519 / ECDSA）
- 網路工具：Wake-on-LAN、埠掃描、DNS 查詢
- Bonjour 網路探索、連線健康監測、遠端資源監視
- 從 `~/.ssh/config`、PuTTY `.reg`、RDCMan `.rdg` 匯入

**自動化**
- `macmoba` CLI + Unix 控制通道（list-tabs / open / open-url / send / read-screen / notify）
- AI agent hooks（Claude Code、Codex）：完成或需要授權時分頁亮燈與系統通知

---

## 安裝

從 [Releases](../../releases/latest) 下載 DMG。已經 Developer ID 簽名 + Apple 公證。

需求：**macOS 14+**、**Apple Silicon**。詳見[入門指南](docs/getting-started.md)。

---

## 從原始碼建置

RDP 需要先建置內含的 FreeRDP（產物不進版控，約 14 MB）：

發佈新版（建置 → 公證 → 簽 appcast → 開 GitHub release → 驗證 feed）：

```bash
# 先改 make-app.sh 裡的 VERSION，提交，然後：
./make-app.sh --release
```

```bash
./scripts/build-freerdp.sh   # 一次性，產生 Vendor/FreeRDP
./scripts/build-mosh.sh      # Mosh 連線需要（GPLv3，獨立執行檔）
```

```bash
swift build -c release      # 建置
swift test                  # 測試（部分整合測試需要 TestSupport/ssh-server.js）
./make-app.sh               # 打包 MacMoba.app（簽名，有憑證就用 Developer ID）
./make-app.sh --notarize    # 打包 + 公證 + 產生 DMG
```

測試套件約 750 項。需要外部服務的整合測試在服務未啟動時會自動略過：

```bash
cd TestSupport && npm install && node ssh-server.js   # 本機 SSH/SFTP 測試伺服器
```

---

## 安全性

- 保險箱：scrypt（N=16384, r=8, p=1）+ AES-256-GCM，主密碼不落地
- 密碼管理器參照在連線當下才解析成明文，用完即丟，不寫入保險箱
- Host key 釘選（known_hosts）；金鑰**變更**一律單獨警告，不受批次信任影響
- 控制通道 socket 0600 + 每次啟動換發 token
- Session log 為明文，畫面上出現的機密會寫入（檔案 0600、資料夾 0700）

## 已知限制

- 僅 arm64（內建 FreeRDP 靜態庫）
- 不支援 RSA 金鑰、ssh-agent、keyboard-interactive（2FA/OTP）——皆為上游 SwiftNIO SSH 限制
- X11 轉發需另裝 XQuartz 並開啟 TCP 監聽

---

## 授權

內含 [mosh](https://mosh.org/)（GPLv3，以獨立執行檔形式散布，授權與原始碼提供聲明隨附於 App 內）。
