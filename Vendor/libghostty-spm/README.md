# libghostty-spm，帶一個資源查找修正的分支

上游：<https://github.com/Lakr233/libghostty-spm>
分支點：**1.5.1**（`e6255b4`），內含 ghostty **1.3.1** 的 XCFramework
授權：MIT，見 [LICENSE](LICENSE)

**libghostty 的二進位檔沒有 vendor**：`Package.swift` 裡仍然是上游 release 的
XCFramework，由 SwiftPM 下載並驗 checksum。這裡只 fork **Swift 包裝層**，
因為只有 Swift 包裝層需要改。同時把 `GhosttyTheme` 和 `ShellCraftKit` 拿掉，
MacMoba 的實驗性 pane 只用到 `GhosttyKit` 與 `GhosttyTerminal`。

---

## 為什麼要 fork：`Bundle.module` 會讓 App 在別台機器上直接 crash

使用者在 **MacBook Air（Mac14,2）** 上開實驗性 pane，App 當場掛掉：

```
_assertionFailure
closure #1 in variable initialization expression of static NSBundle.module
TerminalController.init(configSource:theme:terminalConfiguration:)
GhosttyTerminalTab.init()
```

`GhosttyRuntimeResources` 用 `Bundle.module` 取 `Ghostty` 與 `terminfo`
兩個資源目錄。而 SwiftPM 產生的那個 accessor **只有兩個候選路徑**：

1. `Bundle.main.bundleURL` — 對一個 App 來說是 **`.app` 的根目錄**。
   那裡**不能放東西**：`codesign` 會直接拒絕，訊息是
   `unsealed contents present in the bundle root`（已實測）。
2. 編譯當下**寫死的絕對路徑** `/Users/…/.build/…/GhosttyKit_GhosttyTerminal.bundle`。

**兩個都不是 `Contents/Resources`**——而那正是打包好的 App 放 SwiftPM 資源包
的地方（`make-app.sh` 就是放在那裡，放對了）。

於是：在**編譯的那台機器上**第 2 個候選存在，一切正常；換到任何**別的 Mac**，
兩個候選都落空，accessor 呼叫的是 `fatalError` 而不是回傳 nil，
**整個行程直接死掉**。錯誤剛好在唯一不會被發現的地方是好的。

順帶一提，SwiftTerm 的 `MetalTerminalRenderer.candidateBundles()` 裡有一段
註解把同一件事描述得一模一樣，並且**刻意不用 `Bundle.module`**。
上游這個套件沒有做同樣的防護。

## 改了什麼

`Sources/GhosttyTerminal/Configuration/GhosttyRuntimeResources.swift`
一處，加一個自己的 bundle 查找：依序試
`Bundle.main.resourceURL`（＝`Contents/Resources`，真正的位置）、
`Bundle.main.bundleURL`、以及 `Bundle(for:)` 的兩個對應位置；
全部落空就回傳 `nil`，而不是把行程炸掉。

## 怎麼驗

```bash
./scripts/check-ghostty-resources.sh
```

它會在暫存目錄裡搭一個假的 `.app`（bundle 放進 `Contents/Resources`），
用一個小程式進去問路。**關鍵是它會先把 `.build` 裡那份資源包暫時改名**——
不然在編譯機上這個檢查毫無意義：舊的 accessor 會靠寫死的絕對路徑找到它、
順利通過，而那正是這個 bug 當初能出貨的原因。

## 怎麼跟上游同步

改動只有一個檔案、一個函式，原因寫在該處註解裡。升級時覆蓋上來、
重新套用那一處，然後跑上面的檢查。

若上游哪天自己改掉 `Bundle.module`（值得開一個 issue），這個 `Vendor/`
目錄就可以整個刪掉，`Package.swift` 換回版本相依即可。
