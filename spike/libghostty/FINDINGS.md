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

## 1c. SSH 也做了一個(2026-09-02),並在 loopback 上量到 7.2 倍

`GhosttySSHTab`。比本機那個**還簡單**:`InMemoryTerminalSession` 本來就不知道
PTY 的存在,而 `TerminalTransport` 已經是 write/resize/close,所以沒有
`LocalProcess`、沒有 `TIOCSWINSZ`——resize 就是一個 SSH window-change。

開發機實測(alpine 容器 sshd on 2222,`{ time cat /tmp/cjk.txt ; }`,13.6MB 中文):

```
libghostty   real 0m 0.12s     -> 114 MB/s
SwiftTerm    real 0m 0.86s     ->  16 MB/s
                                   7.2 倍
```

比本機 shell 的 2.95 倍**還大**。原因是本機那條路徑兩邊都被 PTY 與
DispatchIO 綁著;走 SSH 時 SwiftTerm 仍然是**被自己的解析器綁住**
(16 MB/s,和它 23 MB/s 的天花板同一個量級),而 libghostty 沒有。

⚠️ **但這個 7.2 倍要打折看**:`time` 量的是**遠端的 `cat` 什麼時候返回**,
而走 SSH 時 `cat` 只要把 bytes 塞進 SSH 的 flow-control window 就結束了,
不必等終端機真的畫完。所以快的那一邊(0.12s)很可能**根本不是終端機在限速**,
數字被高估;慢的那一邊(0.86s)才確定是終端機在限速。

⚠️ **而且 loopback 是最快的可能連線**。真正要問的是使用者自己那台伺服器:
在**現有的一般 SSH 分頁**裡 `time cat` 一個大中文檔,
- 遠比 0.86s 慢 → 網路/遠端才是瓶頸,換終端機一點用都沒有
- 落在 0.86s 附近 → 連線比終端機快,那 libghostty 才真的有東西可拿

驗證過的還有:輸入送得到遠端、遠端 `stty size` 回報 33×124(跟 pane 相符,
代表 resize 有變成 SSH window-change 送出去)、密碼認證通過
(容器 log:`Accepted password for tester`)。

## 1d. 真實伺服器上的結果:量不到,而且不必再量了

使用者自己的伺服器,同一格連跑三次(13.6MB 中文):

```
real 0m17.051s   ->  0.80 MB/s
real  0m5.111s   ->  2.67 MB/s
real  0m7.143s   ->  1.91 MB/s
```

**同一格之內就差 3.3 倍**,比我們想分辨的 1.7 倍還大。所以先前
「2.25 是 4.08s、2.92 是 6.93s」那個比較**是雜訊,不是結果**——不能拿來
說 libghostty 比較慢,也不能拿來說比較快。

而三次都落在 0.8–2.7 MB/s,SwiftTerm 要 **16 MB/s** 才開始成為瓶頸,
中間有 6–20 倍餘裕。**在這條連線上,終端機引擎不在瓶頸裡**,量測本身
看不到它。

### 兩格對跑(正確指令,各三次)

| | 最快 | 中位數 | 最慢 |
|---|---|---|---|
| libghostty | 5.111s | 7.143s | 17.051s |
| SwiftTerm | 3.716s | 5.880s | 7.233s |

(⚠️ **這一組後來被推翻了,見下一節。** 當時 libghostty 三次裡有一次 17 秒,
於是每一項統計都輸;補到五次之後兩者中位數只差 1.3%。這一段留著,是因為它
示範了 n=3 有多容易造出假結論。)

六次全部落在 **0.8–3.7 MB/s**,而 SwiftTerm 的天花板是 16 MB/s:兩個引擎都在
等網路,誰也沒被推到極限。

### 補跑五次之後:兩者相同,先前的「比較慢」是離群值

對齊 scrollback、ghostty 那格連跑五次:

| | 中位數 | 平均 | 最快 | 最慢 |
|---|---|---|---|---|
| ghostty(先前 n=3) | 7.143 | 9.768 | 5.111 | **17.051** |
| ghostty(n=5) | **5.956** | 5.650 | 3.333 | 6.891 |
| SwiftTerm(n=3) | **5.880** | 5.610 | 3.716 | 7.233 |

**中位數差 1.013 倍、平均差 1.007 倍——也就是沒有差別。**

先前那個「libghostty 慢 1.7 倍」**完全是單一次 17 秒撐出來的**。在一個自己
就抖 2 倍以上的分佈裡取三個點,足以造出一個看起來像結論的東西。樣本補到五次
就消失了。

**這也正好證實了原本的預期**:連線只給 2.3 MB/s,而兩個引擎的下限是
16 MB/s——它們整段時間都在等網路,所以量出來當然一樣。終端機引擎在這條
連線上不影響任何事,不是「影響很小」,是**測不到,因為它根本不在瓶頸裡**。

⚠️ 教訓記在這裡:**n=3 配上 2–3 倍的自然抖動,足以憑空生出一個 1.7 倍的
「結果」**。我當時應該先要求更多樣本再解讀,而不是先解讀再加註「樣本很少」。

### 最終:五對五,置換檢定 p = 0.92

| | 中位數 | 平均 | 標準差 | 範圍 |
|---|---|---|---|---|
| ghostty | 5.956 | 5.650 | 1.384 | 3.333–6.891 |
| SwiftTerm | 5.459 | 5.729 | 1.544 | 3.540–7.305 |

中位數說 ghostty 慢 9%,平均說 ghostty 快 1.4%——**兩個統計量方向相反**,
本身就是「沒有效應」的徵狀。

置換檢定(252 種分組全枚舉,平均差 0.079s):**p = 0.92**。
隨機把這十個數字分成兩組,有 92% 的機會得到更大的差距。**兩組無法區分。**

吞吐 2.3 對 2.5 MB/s,而兩個引擎的下限都是 16 MB/s。**問題到此結束**:
在這條連線上換終端機引擎的效果是零,而且是可以量到「確實是零」的那種零,
不是「太小量不到」。

### 一個量測上的教訓(我自己犯的)

中途我給了兩次錯的指令:

```sh
{ time cat cjk-big.txt ; } 2>&1 | grep real     # 錯
```

管線把 **stdout 接走了**,終端機根本沒畫任何東西——量到的是「`cat` 讀檔
餵給 `grep`」。使用者跑出 0.017s 才發現不對。正確的是把 **stderr** 導開、
讓 stdout 留在終端機:

```sh
for i in 1 2 3; do { time cat cjk-big.txt ; } 2>> /tmp/t; done; grep real /tmp/t
```

要量終端機,就必須讓輸出真的走進終端機——這聽起來像廢話,但它偽裝成一個
看起來很合理的指令,而且產生的數字漂亮到不會讓人起疑。

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

0. **SSH 這條路更明確:不換。** 本機 shell 那 2.95 倍是在「沒有東西擋著」的
   條件下量到的;一接上真實網路,連線本身只給 0.8–2.7 MB/s,而且抖動 3.3 倍。
   SwiftTerm 在那之上還有 6–20 倍餘裕,所以**換引擎在 SSH 上的收益是 0**——
   不是「小」,是量不到。而 SSH 分頁又正好是 session log、⌘F、MultiExec、
   ZMODEM、狀態列、on-connect、SFTP 連動全部住的地方,代價最高、收益最低。

1. **不要換。**(實測之後這條從「先不要」變成「不要」。)端到端只有 2.95 倍,
   而且 0.604s 對 0.205s——**兩邊都在一秒內跑完 14MB 中文**,那不是任何人
   日常會踩到的量。真正的原因是上表:管線在 68 MB/s 封頂,解析器再快也用不到,
   所以換引擎能拿到的最好結果就是這 3 倍,其中一大半這輪的 CJK 快路徑已經拿到了。
   剩下的那一小段,代價是自己寫一個終端機 view、外加把 session logging、⌘F、
   廣播、ZMODEM、六套主題全部重接一遍。不划算。
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
