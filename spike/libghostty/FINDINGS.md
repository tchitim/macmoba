# 換成 libghostty:量出來的結果與擋路的東西

分支 `libghostty-spike`。量測日期 2026-09-02,ghostty `3c1ef5b`(main,**沒有 tag**)。

先講結論:**解析速度贏很多,但今天換不了**,因為 libghostty 還沒有算繪。

---

## 1. 解析速度:快 10 到 28 倍

同一台機器、同樣三種 payload、同樣 120×40。
SwiftTerm 走 release build;libghostty-vt 走 `-Doptimize=ReleaseFast`。

| payload | SwiftTerm(core) | libghostty-vt | 倍數 |
|---|---|---|---|
| 純 ASCII | 52.3 MB/s | **1,220 MB/s** | 23× |
| 帶色 ANSI | 27.6 MB/s | **270 MB/s** | 9.8× |
| CJK | 31.9 MB/s | **870 MB/s** | 27× |

CJK 那一格的 31.9 已經是**我們自己最佳化過**之後的數字;沒最佳化前是 11.8,
對 libghostty 是 **74 倍**。

**比較是公平的。** 一開始 SwiftTerm 的數字走的是 `TerminalView.feed`(有 view),
而 libghostty 走的是 `ghostty_terminal_vt_write`(沒有 view)。補測了 SwiftTerm
不帶 view 的 core 路徑,結果 52.3 對 50.9、27.6 對 27.2、31.9 對 31.3——
**view 幾乎不花錢,慢的是 core 本身**。所以上表兩邊都是 core 對 core。

**而且驗證過真的有做事。** 1,220 MB/s 這種數字要先懷疑是不是延後處理或吞掉了。
`ghostty-verify.c` 餵 45 行進 40 列的螢幕,再用 formatter 把畫面讀回來:
捲動正確、最後一行是 `line-44` / `INFO row-44` / `第 44 行:連線成功`,
CJK 完整。數字可信。

（過程中我自己的驗證程式先寫錯過一次——在把換行改成 `\0` **之後**才 `strstr`,
所以只搜到第一行,三個都報 NO。是驗證器的 bug,不是 libghostty 的。）

## 1b. 實驗性 pane:MacBook Air 實測通過(2026-09-02)

使用者在 **MacBook Air(Mac14,2)** 上開得起來、**沒有 crash**。

這一項要在**別台機器**上驗才有意義:原本的 crash 正是「只有編譯的那台機器
找得到資源包」造成的(見 `Vendor/libghostty-spm/README.md`),在開發機上
**永遠測不出來**。所以 MBA 這一次通過,才是那個修正真正被證明的地方。

開發機(Mac mini)上另外確認過的:開啟不 crash、shell 的 tty 回報 33×124
(跟 pane 相符,不是 80×24 的預設值)、鍵盤輸入進得去、14MB 中文 `cat`
進去之後 shell 仍然有反應。

⏳ **還沒有的是「快不快」的主觀結論**——那才是決定要不要真的換的依據。

## 2. 擋路的:libghostty 沒有算繪

`include/ghostty/vt/render.h` 有 33KB,但看內容全部是
`ghostty_render_state_row_iterator_*`、`ghostty_render_state_row_cells_*` 這類
**取出要畫什麼的迭代器**,含 dirty row。**沒有任何 Metal 或 OpenGL 介面。**
Mitchell 自己寫的規劃裡,「給我們一個 OpenGL 或 Metal surface,剩下我們處理」
是**之後**的 lib,和輸入處理、GTK widget、Swift framework 一起排在後面。

現在拿得到的是:VT 解析與終端狀態、screen/grid、selection、search、OSC、
Kitty graphics。拿不到的是:**一個能放進視窗的 view**。

## 3. 所以「換掉 SwiftTerm」實際上是什麼工程

MacMoba 用 SwiftTerm 的地方遠不只解析:

- `TerminalView` 這個 NSView 本身——算繪、游標、捲動、字型度量、主題、Metal 開關
- `LocalProcessTerminalView`——本機 shell 的 PTY
- 選取(滑鼠拖曳 UI、`getSelection`、`selectAll`)、搜尋、無障礙、輸入法

換成 libghostty 等於**自己寫一個終端機 NSView**:CoreText 或 Metal 算繪器、
游標、選取互動、捲動、IME、a11y,然後把 MacMoba 這邊所有掛在 SwiftTerm view 上的
東西重接一遍——ZMODEM、session log、⌘F 搜尋、廣播輸入、first-responder 那一串
(v2.24/2.25 才剛修好的)、六種配色主題。

這是**以週計**的工程,不是一個 session,而且中途每一項都是回歸風險。
所以這個分支**沒有可測試的 DMG**——硬做一個出來只會是個比現在差很多的終端機。

## 4. 建議

1. **先不要換。** 效能差距是真的,但 31.9 MB/s 對真實 SSH 連線已經綽綽有餘;
   會痛的只有本機 shell `cat` 大檔。用**週**去換一個使用者感覺不到的加速,
   同時把三十幾項已驗收的行為全部推回未驗證,不划算。
2. **等 `libghostty-render` 和 Swift framework。** 那才是真正省工的時刻——
   到時候換的是「算繪 + 解析」一整塊,而不是自己補一個算繪器。
   順帶一提 libghostty-vt 有 **Apple universal xcframework** 的 build target,
   之後接進 SwiftPM 會很乾淨,對 Intel 支援那一項也有幫助。
3. **真的想現在拿到好處,先量 Metal。** ROADMAP 裡那一項還開著:
   我們自己的 GPU 算繪路徑到底有沒有用,目前**完全沒有數字**
   (`testDrawTime` 走 `cacheDisplay`,強制 CoreGraphics)。
   畫面的成本比解析更接近使用者感受,而且不用換掉任何東西。

## 怎麼重跑

```bash
brew install zig          # 0.16,會拉 llvm@21,約 1.7GB
./spike/libghostty/build.sh
```

沒有 tag 可以釘,所以腳本會印出 ghostty 的 commit——引用數字時請一起記下來。
