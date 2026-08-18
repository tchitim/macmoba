# 入門指南

MacMoba 是 macOS 上的原生遠端連線工作站——把 MobaXterm 與 Royal TSX 的核心工作流搬到 Mac：SSH、Mosh、Telnet、Rlogin、SFTP/FTP、VNC、RDP、序列埠與網頁分頁都在同一個視窗裡，密碼收在本機加密保險箱，還有一支 `macmoba` CLI 讓腳本與 AI agent 反過來驅動它。

---

## 安裝

**下載 DMG（建議）**

從 [Releases](../../releases/latest) 下載最新的 `MacMoba-x.y.dmg`，打開後把 `MacMoba.app` 拖進「應用程式」。

App 已經過 **Developer ID 簽名與 Apple 公證**，第一次開啟不會跳「無法驗證開發者」的警告。若系統仍詢問，選「打開」即可。

**系統需求**

| 項目 | 需求 |
|---|---|
| macOS | 13 Ventura 以上 |
| 處理器 | **Apple Silicon（arm64）** |
| 磁碟 | 約 40 MB |

> ⚠️ 目前只提供 arm64 版本。內建的 FreeRDP 靜態程式庫是照 Apple Silicon 編譯的，Intel Mac 無法執行。

---

## 驗證安裝

第一次啟動會看到**保險箱建立畫面**：

1. 設定一組**主密碼**——它用 scrypt + AES-256-GCM 保護你所有的連線設定與密碼，**忘記就無法復原**。
2. 若這台 Mac 有 Touch ID，可勾選「Remember in Keychain for Touch ID unlock」，之後用指紋解鎖。
3. 解鎖後會看到主視窗：左側是連線側邊欄，右側是分頁區。

保險箱檔案在 `~/Library/Application Support/MacMoba/vault.json`，權限 0600。

---

## 第一條連線

1. 側邊欄 **Sessions** 標頭的 **+** → **New Session…**
2. **General** 分類填名稱、主機、埠；**Login** 分類填帳號與密碼（或選私鑰檔）
3. **⌘S** 儲存，然後**雙擊**該連線就會連上

第一次連到一台新主機時會出現 host key 確認。如果你正一次開整個資料夾，可勾選 **「Also trust other new hosts for the next 2 minutes」**，同一批的新主機就只問這一次——**但金鑰「變更」的主機永遠會單獨警告**，那是中間人攻擊的訊號。

### 資料夾與繼承

連線可以放進巢狀資料夾，用斜線表示層級：

```
Production/Linux
Production/Windows
```

也可以在資料夾上按右鍵 → **New Subfolder…** 直接建立。資料夾右鍵的 **Group Credential** 可以指定一組共用登入，子資料夾**沿路徑往上繼承**（最近的祖先優先），所以一組憑證可以罩住整個專案。

### 密碼管理器

密碼欄除了填字面密碼，也可以填**參照**，連線當下才去取，**不會存進保險箱**：

```
op://Personal/my-server/password     # 1Password CLI
cmd:security find-generic-password -w -s my-server   # 鑰匙圈、pass、keepassxc-cli…
```

1Password 需要先安裝 `op` CLI 並在 1Password 設定 → Developer 開啟「Integrate with 1Password CLI」。

---

## CLI 設定

App 內附一支 `macmoba`，讓終端機、腳本或遠端的 AI agent 驅動 MacMoba。建立一個 alias 或 symlink：

```bash
ln -s /Applications/MacMoba.app/Contents/Resources/bin/macmoba /usr/local/bin/macmoba
```

常用指令：

```bash
macmoba list-tabs                          # 列出所有分頁與狀態
macmoba open "web-server"                  # 開啟已存的連線
macmoba open-url http://10.0.0.5:3000 --via "Jumphost"   # 開網頁分頁，走某個 SSH 的 SOCKS 隧道
macmoba send --tab 0 'uptime\n'            # 對某個分頁打字（\n = Enter）
macmoba read-screen --tab 0 --lines 30     # 讀回畫面內容
macmoba notify --title "部署完成"           # 跳出通知
```

控制通道是 `~/Library/Application Support/MacMoba/control.sock`（0600），每次啟動換發一組 token，只有本機這個使用者能存取。

### AI agent 整合

若你在 MacMoba 的本機終端分頁裡跑 Claude Code：

```bash
macmoba hooks install claude    # 併入 ~/.claude/settings.json（會先備份）
macmoba hooks install codex     # 印出 config.toml 片段讓你自己貼
```

裝好之後，agent「完成」或「需要授權」時，該分頁會亮藍點；App 在背景則跳系統通知，點一下直接跳到那個分頁。

遠端主機上跑的 agent 摸不到本機 socket，但 MacMoba 會偵測終端鈴聲（BEL）與「長時間靜默後恢復輸出」，同樣會亮燈提醒；**⌥⌘U** 可以循環跳到下一個等你處理的分頁。

---

## 自動更新

MacMoba 使用 [Sparkle](https://sparkle-project.org/)：預設每天檢查一次，有新版時詢問你是否下載，下載後驗證 EdDSA 簽章與 Developer ID 簽名，再替換並重新啟動。

手動檢查：選單 **MacMoba → Check for Updates…**

---

## 工作階段還原

關閉 App 時開著的分頁會被記住，下次啟動自動重新連線（可在**設定 → General** 關閉）。Mac 從睡眠喚醒後，睡眠期間斷掉的終端會自動重連；沒斷的則保持原狀，不會丟掉你的 scrollback。

**目前無法還原遠端行程的執行狀態**——重新連線是一條新的 SSH 連線。要讓工作留在遠端，請搭配 `tmux`／`screen`，或改用 Mosh 連線。

---

## 下一步

- **⌘K** 快速連線：直接輸入 `user@host:port`，不用先建立連線
- **⇧⌘0** 總覽：所有視窗的連線縮圖一覽
- **⌥⌘I** 檢閱器：單擊看連線資訊與可達性，雙擊才連線
- **⌥⌘L** Library：管理巨集、共用憑證、連線範本
- **Tools 選單**：SSH 金鑰產生器、網路工具（Wake-on-LAN／掃埠／DNS）、信任主機管理

---

## 已知限制

- **僅 arm64**：Intel Mac 無法執行
- **不支援 RSA 金鑰**：底層 SwiftNIO SSH 只支援 ed25519 / ECDSA，請用 `ssh-keygen -t ed25519`
- **不支援 ssh-agent 與 keyboard-interactive（2FA/OTP）**：上游函式庫尚未提供
- **X11 轉發**需另外安裝 XQuartz，並開啟 TCP 監聽
- **Session log 是明文**：畫面上出現的機密都會寫進去（檔案 0600）
