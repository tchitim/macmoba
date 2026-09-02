# SwiftTerm，帶 CJK 快路徑的分支

上游：<https://github.com/migueldeicaza/SwiftTerm>
分支點：**1.15.0**（`dd2fb8ac5b861e7bf617c872895e338f38165648`）
授權：MIT，見 [LICENSE](LICENSE)

原本是一般的 SPM 版本相依。改成放進 `Vendor/` 是因為要改的地方在
`Terminal.handlePrint` 的逐字元迴圈裡，**那條路徑沒有任何對外的鉤子**——
不動原始碼就沒有第二種做法。

`Package.swift` 是重寫過的精簡版：只留 library 與測試，拿掉 Termcast、
fuzzer 與文件目標，順帶把 `swift-argument-parser` 和 `swift-docc-plugin`
一起移出相依圖（MacMoba 從來沒用到它們產出的任何東西）。

---

## 改了什麼

動機是量出來的，不是猜的。MacMoba 的 `TerminalThroughputBenchmark`
（release build）顯示 CJK 的解析速度是 **11.8 MB/s**，而純 ASCII 是
51.2 MB/s；換算成**每字元**是 5.3M 對 53.6M，**慢 10.1 倍**。

原因在 `handlePrint`：ASCII 那條路走到 `insertCharacter` 就 `continue`，
而多位元組那條在**每一個字元**上多做了一次 heap 配置（`var x: [UInt8]`）、
一次 `Character` 建構、一次 unicodeScalars 走訪，然後掉進 ASCII 直接跳過的
整段 grapheme 組合判斷——包含把**前一格**重建成 `Character` 來檢查 ZWJ。
`columnWidth` 另外還做了一次 `rune.properties.generalCategory` 查表。

兩處修改：

1. **`Utilities.swift`** — 新增 `UnicodeUtil.isStandaloneWideCJK(_:)`，
   並讓 `columnWidth` 對這些區段直接回傳 2，跳過 Unicode 屬性查詢與 bisearch。
2. **`Terminal.swift`** — `ReadingBuffer` 加上 `peek`；`handlePrint` 對
   「獨立的東亞寬字元」直接從預看的位元組組出 scalar 並寫入，略過上述全部。
   唯一仍需走一般路徑的情況是**前一格以 ZWJ 結尾**（連接子會把這個字拉進
   前一個 grapheme cluster），改用 `isSimpleRune` 判斷——一個裸的 ZWJ 寬度為 0，
   永遠不會自己佔一格，所以只有存著整個 cluster 的格子才可能以它結尾。

結果：**11.8 → 31.9 MB/s（2.7 倍）**，每字元 5.3M → 14.2M。
ASCII 與帶色輸出的數字沒有變化。

## 範圍不是用眼睛決定的

`Tests/SwiftTermTests/CJKFastPathVerification.swift` 會走過這些區段裡的
**全部 39,615 個 scalar**，逐一驗證三件事：寬度確實是 2；沒有 combining
class、不是 emoji modifier／variation selector／ZWJ／regional indicator；
而且不會和前一個字元合併成同一個 grapheme cluster。

第一次跑就抓到兩個真的錯誤，都已經從範圍裡挖掉：

- **U+302A–302F** 是漢字聲調符號，**有 combining class**
- **U+303F、U+3040、U+3097、U+3098** 寬度是 **1，不是 2**

所以 `isStandaloneWideCJK` 的區段是有缺口的。那些缺口是量出來的，
改動範圍前請先讓這個測試通過。

## 怎麼重跑驗證

```bash
cd Vendor/SwiftTerm
swift test                                   # 全部：451 + 57 項
swift test --filter CJKFastPathVerification  # 只跑範圍驗證
```

上游全套測試在改動後仍然全過（含 `UnicodeTests`、`ReflowTests`、
`ScreenTests`、`FuzzerTests`）。

## 怎麼跟上游同步

改動集中在兩個檔案、三個位置，全部有註解標示原因：

- `Sources/SwiftTerm/Utilities.swift` — `isStandaloneWideCJK`，與 `columnWidth` 的提前返回
- `Sources/SwiftTerm/Terminal.swift` — `ReadingBuffer.peek`、`previousCellCanJoin`、`handlePrint` 的快路徑

升級時把新版覆蓋上來、重新套用這三處，然後跑上面的測試。
若上游哪天自己做了同樣的最佳化，這個 `Vendor/` 目錄就可以整個刪掉，
`Package.swift` 換回版本相依即可。
