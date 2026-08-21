# 入門指南

[English](getting-started.en.md) · **繁體中文**

MacMoba 是 macOS 上的原生遠端連線工作站——把 MobaXterm 與 Royal TSX 的核心工作流搬到 Mac：SSH、Mosh、Telnet、Rlogin、SFTP/FTP、VNC、RDP、序列埠與網頁分頁都在同一個視窗裡，密碼收在本機加密保險箱，還有一支 `macmoba` CLI 讓腳本與 AI agent 反過來驅動它。

---

## 安裝

**下載 DMG（建議）**

從 [Releases](../../releases/latest) 下載最新的 `MacMoba-x.y.dmg`，打開後把 `MacMoba.app` 拖進「應用程式」。

App 已經過 **Developer ID 簽名與 Apple 公證**，第一次開啟不會跳「無法驗證開發者」的警告。若系統仍詢問，選「打開」即可。

**系統需求**

| 項目 | 需求 |
|---|---|
| macOS | 14 Sonoma 以上 |
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

### 連線範本

**一份預先填好的設定，但不含主機**——用來省掉「每加一台機器就重填同一堆欄位」。

假設同一批 VM 都是 port 22、root、走同一台跳板、連上自動跑 `cd /opt && ls`、綠色標籤、tag `vm`。把這些存成一個範本，之後新增第六台時：

**Sessions 標頭的 `+` → From Template → 選它** → 開出編輯器，**每個欄位都填好了，只有 host 是空的**。填 IP、⌘S，完成。

範本放在 **Library（⌥⌘L）→ Templates**，而且**不會出現在連線列表裡**——它不是連線，是模子。

**搭配 token 才是重點。** 範本的「連上自動執行」可以寫變數，送出當下才代入那台機器自己的值：

```bash
echo "登入 %username%@%host%:%port%"
tmux new -A -s %name%
```

可用的有 `%host%` `%port%` `%username%`（或 `%user%`）`%name%` `%group%` `%domain%` `%webURL%`。大小寫不分；認不得的 token 原樣保留，不會壞掉。所以**一份範本可以罩住整個機群**，而不是每台各寫一份腳本。

> 只想共用**帳號密碼**的話，用**群組憑證**更直接（右鍵資料夾 → Group Credential，子資料夾沿路徑往上繼承）。範本解決的是「整組設定」，群組憑證解決的是「同一組帳密」。

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
macmoba open-url http://192.0.2.5:3000 --via "Jumphost"   # 開網頁分頁，走某個 SSH 的 SOCKS 隧道
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

## 遠端桌面的鍵盤與滑鼠

**點進 VNC 畫面就會擷取輸入**（VMware／Parallels 的作法）：

- 鍵盤全部送給遠端——包括 **⌃Space**，所以可以直接切換**遠端**的輸入法（🌐 鍵做不到：macOS 把它攔在系統層，App 收不到）
- 滑鼠與本機游標脫鉤，移動量直接驅動遠端游標，**不會停在視窗邊緣**
- **按一下 ⌃⌥ 再放開**解除擷取。單獨按修飾鍵對任何程式都沒有意義，所以這個手勢不會跟遠端搶東西
- Esc 一律原樣送給遠端，不參與解除——遠端若是 vim 或 Claude Code 這類會用到 Esc 的程式，不會被誤觸

第一次擷取會要求**輔助使用**權限——那是抑制本機系統快捷鍵（⌘Tab、Spotlight）唯一的途徑。**拒絕也能用**，只是那些鍵會留在本機。授權後要重新啟動 MacMoba。

不想要這個行為就到 **Session → Capture Input on Click** 關掉。

輸入法方面另有一點：MacMoba 送給遠端的一律是**實體鍵**（經 ASCII 鍵盤配置翻譯），不受本機選了什麼輸入法影響——組字是遠端那台自己的事。

### 剪貼簿

英數字兩個方向都自動同步，照常用 ⌘C／⌘V。**中文與其他非 Latin-1 字元不行**——那是 VNC 協定本身的限制，它的剪貼簿訊息只能承載 Latin-1。兩個補救各走不同的路：

| 想做的事 | 按鍵 | 怎麼辦到的 |
|---|---|---|
| 把本機的中文貼到遠端 | **⌥⌘V** | 逐字打進去，用 X11 的 Unicode keysym |
| 把遠端的內容抄回本機 | **⌥⌘C** | 走**同一台機器的 SSH 連線**執行 `pbpaste`（Linux 試 `xclip`／`xsel`） |

⌥⌘C 需要保險箱裡有一條指向**同一個 host** 的 SSH 連線；找不到時它會告訴你現有的 SSH 連線指向哪些 host，方便你對齊。這兩個組合鍵**不會轉發給遠端**，所以擷取輸入時照樣能用。

---

## 傳檔

**SFTP 面板**（工具列的資料夾鈕）：雙欄瀏覽、拖放上傳、拖出到 Finder 下載、Quick Look、chmod。

**拖到終端機畫面**：SSH 分頁會出現兩個落區——左半 **Upload via SFTP**（上傳到面板目前的目錄），右半 **Send via ZMODEM**。

**ZMODEM**（遠端需 `lrzsz`）：

```bash
# 下載：在遠端跑，MacMoba 自動接手，存到 ~/Downloads
sz report.log

# 上傳：Session → Send File (ZMODEM)…
# 不必自己先跑 rz，MacMoba 會替你起；若你已經跑了，它會偵測到並跳過
```

`rz` 收到的檔案會落在**執行它時所在的目錄**。

---

## 自動更新

MacMoba 使用 [Sparkle](https://sparkle-project.org/)：預設每天檢查一次，有新版時詢問你是否下載，下載後驗證 EdDSA 簽章與 Developer ID 簽名，再替換並重新啟動。

手動檢查：選單 **MacMoba → Check for Updates…**

---

## 工作階段還原

關閉 App 時開著的分頁會被記住，下次啟動自動重新連線（可在**設定 → General** 關閉）。**分割版面也會一起還原**——三個 shell 配一個遠端桌面，回來還是那個樣子；期間被刪掉的連線只是少掉那一格，其餘照舊。Mac 從睡眠喚醒後，睡眠期間斷掉的終端會自動重連；沒斷的則保持原狀，不會丟掉你的 scrollback。

連線斷掉時，那個分頁會停在「Connection closed」：**Return 重新連線**、**Esc 關掉它**（分割狀態下只關那一格）。

**目前無法還原遠端行程的執行狀態**——重新連線是一條新的 SSH 連線。要讓工作留在遠端，請搭配 `tmux`／`screen`，或改用 Mosh 連線。

---

## 下一步

- **⌘K** 快速連線：直接輸入 `user@host:port`，不用先建立連線
- **⇧⌘0** 總覽：所有視窗的連線縮圖一覽
- **⌥⌘I** 檢閱器：單擊看連線資訊與可達性，雙擊才連線
- **⌥⌘L** Library：管理巨集、共用憑證、**連線範本**（見上面「連線範本」）
- **Tools 選單**：SSH 金鑰產生器、網路工具（Wake-on-LAN／掃埠／DNS）、信任主機管理

---

## 已知限制

- **僅 arm64**：Intel Mac 無法執行
- **不支援 RSA 金鑰**：底層 SwiftNIO SSH 只支援 ed25519 / ECDSA，請用 `ssh-keygen -t ed25519`
- **不支援 ssh-agent 與 keyboard-interactive（2FA/OTP）**：上游函式庫尚未提供
- **X11 轉發**需安裝 XQuartz 並開啟 TCP 監聽（`defaults write org.xquartz.X11 nolisten_tcp -bool false`，之後重登入）。底層 SwiftNIO SSH 沒有原生 x11 channel，MacMoba 改用等效的 remote forward：請伺服器把 `localhost:600N` 的連線送回這台 Mac，並自動設好遠端的 `DISPLAY`
- **Session log 是明文**：畫面上出現的機密都會寫進去（檔案 0600）
- **VNC 剪貼簿只能傳 Latin-1**：協定本身的限制，中文過不去；改用 ⌥⌘V／⌥⌘C（見上面「剪貼簿」）
- **隧道只能掛在 SSH 或 Mosh 連線上**：隧道是一條 SSH channel，遠端桌面與序列埠承載不了，所以選單裡不會列出它們
