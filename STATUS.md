# MacMoba 專案狀態

最後更新：2026-09-01 · 版本 **v2.20** · 測試 **783 項全過**
（**自簽憑證的網頁分頁修好了,真正的原因是 ATS,而且它「不可被覆蓋」**。2.19 的 log 是決定性的:`exceptionsSet=true`、`offered` 與 `stored` 指紋相同、`action=accept`、`failingURL` 就是剛剛接受的那台主機(不是登入轉址過去的 oauth),然後**還是 -1202**。也就是說釘選、時機、credential 三件事全都是對的。真兇是 **App Transport Security**,而不明顯的關鍵是:**ATS 的拒絕沒辦法從 authentication challenge 覆蓋**——challenge 照樣送到、credential 照樣被接受、頁面照樣失敗,所以從外面看起來就像「按了信任完全沒用」。**我先前判斷「不是 ATS」是錯的**:那幾輪測試全部連的是 `127.0.0.1` 和 `192.168.88.10`,而 **ATS 對 IP 位址根本不生效**,所以那些測試從頭到尾都在 ATS 管不到的地方跑。改用真正的主機名稱(`sslip.io`)重測,一次就重現:同一個頁面,裸執行檔(沒有 Info.plist 就沒有 ATS)載入成功,放進 app bundle 就失敗、兩次 challenge 之後 -1202,**跟使用者的 log 一模一樣**;加上 `NSAllowsArbitraryLoadsInWebContent` 之後立刻載入成功。用 `InWebContent` 而不是 `NSAllowsArbitraryLoads`:只豁免網頁內容,App 自己的網路請求仍受 ATS 管;而真正在保護這些分頁的是 `web_certs.json` 的每主機憑證釘選,完全不受影響,憑證換掉一樣會擋。）
（**每個 release 開始有自己的 changelog**。以前每一版的 GitHub release notes 都是同一段安裝說明,看不出版本之間差在哪。現在改成從 `CHANGELOG.md` 抓對應版本的段落,**而且找不到該版本的段落就拒絕發佈**——會被忘記的 release notes 就是沒有人會寫的 release notes。同一段文字也會產生 Sparkle 的 release notes 檔,所以 App 內更新對話框看到的跟 GitHub 上是同一份,不會走鐘。）
（**憑證問題的診斷進度**。2.18 的 log 給了決定性資訊:`stored` 和 `offered` 指紋**完全相同**、`action=accept`、我們當場回 `.useCredential`,**然後 WebKit 還是回 -1202**。所以釘選是成功的、回答也夠快,是這張憑證被 WebKit 二次否決。本機用真的自簽伺服器把能想到的差異全部試過——名稱不符、CA 簽發的憑證鏈、SOCKS proxy、per-identifier 持久 data store、app bundle 的 ATS、非 loopback 位址——**每一種都成功載入**,所以無法在本機重現。2.19 做兩件事:把已釘選憑證的瑕疵用 `SecTrustSetExceptions` 正式標記為「使用者已接受」再交回去(交回一個評估仍然失敗的 trust,本來就是被二次拒絕的標準原因);以及記下**究竟是哪一個網址失敗**——如果 -1202 是發生在一個從來沒出現過 challenge 的主機上(例如登入會轉址到的 `oauth-openshift.apps…`),那就是完全不同的問題。）
（**2.17 之後連問都不問了,所以停止臆測、改成記錄**。兩個版本猜錯兩次(2.16 卡在 challenge 裡等使用者;2.17 改成兩段式之後反而完全不跳對話框),而這個專案自己的教訓就是——**症狀在 UI、原因在框架層時,把狀態印出來比推理快**。2.18 把每一次 challenge 的完整狀態寫進 os_log:host:port、systemTrusted、offered/stored 指紋、選到的 action、是否已有對話框在等、對話框結果、是否釘選並重新載入,以及 provisional navigation 失敗的 domain/code。查看:`log show --predicate 'subsystem == "dev.macmoba.tls"' --last 10m --info`。過程中排除掉一個看似很合理的假設:2.17 把「取憑證鏈」搬到「評估信任」之前,懷疑 `SecTrustCopyCertificateChain` 未評估前會回 nil 而走進不詢問的 `.decline` 分支——實測**評估前就拿得到憑證鏈**,所以不是這個原因,沒有當成答案發出去。另外對話框現在會先 `NSApp.activate`,並在狀態列寫明正在等憑證決定——一個沒人看見的憑證提示,體感就是「它就是不會動」）
（**2.16 的憑證信任按了沒有用——原因是「讓使用者思考」這件事本身**。對話框有跳、按了 Trust、頁面照樣是同一個錯誤。用一台本機自簽 HTTPS 伺服器把整條路徑重現出來後,答案很乾脆:**WKWebView 的 challenge 必須「當下」回答**。實測回答延遲 0.0 秒→載入成功;延遲 **0.2 秒→整個 navigation 就死了**(不是報錯,是永遠不會完成)。而 2.16 正是在 challenge callback 裡面直接 `NSAlert.runModal()`,等使用者讀完再回答——那個等待本身就是 bug。**這也解釋了為什麼它看起來像「按了完全沒反應」**。改成兩段式:**先立刻拒絕這一次連線,之後才問,答應就釘選並重新載入**;重新載入時已經有釘選,可以當場回答 `.useCredential`,頁面就開了(本機實測 challenge #1/#2 拒絕 → 釘選 → #3/#4 立即接受 → LOADED OK)。決策表移進 Core 的 `WebCertificateTrust.action(systemTrusted:stored:offered:)`,因為**每一個分支都必須是能當場送出的答案**——把這條規則寫成型別,比寫在註解裡可靠。另外 WebKit 一次 navigation 會發好幾個 challenge,所以加了 pending 旗標,否則同一台伺服器會疊出好幾個一模一樣的對話框;我們自己主動取消而產生的 `NSURLErrorCancelled` 也不再被當成載入失敗顯示出來。5 個新測試,共 783 項）
（**Web 分頁現在能連自簽憑證的內部主控台**。這個分頁存在的理由就是 OpenShift console、Cockpit、交換器管理介面這類東西,而它們**幾乎都是自簽或私有 CA**——WKWebView 直接拒絕,沒有任何通融的辦法。**做法不是「忽略 TLS 錯誤」**:那等於把這個分頁永遠變成未驗證通道。改用這個專案已經對 SSH host key 和 RDP 憑證做過的同一筆交易——**先讓系統正常驗證,只有系統說不行時才顯示指紋、釘選一次,之後安靜通過;而釘選過的憑證若改變,永遠不會被放行**。指紋用 `openssl x509 -fingerprint -sha256` 和「鑰匙圈存取」的格式(冒號分隔大寫十六進位),因為給使用者看指紋的唯一理由就是讓他去跟伺服器對照,一個還要先轉換格式的格式等於沒給。存在 `web_certs.json`,並加進「Trusted Hosts」管理視窗可以撤銷。順手修掉一個**同類 bug**:那裡選擇 store 的地方原本是 `kind == .ssh ? sshStore : rdpStore`,新增第三種就會被默默送去 RDP store——撤銷了錯的釘選,而真正那筆還留著。改成 exhaustive switch,讓編譯器接手。`TLSTrust`,6 測試）
（**「複製大量文字會停頓」——量測與讀原始碼把它定位到算繪,不是複製**。基準測試顯示取出選取文字約 **4 ms**,不論選 1,000 行還是 10,000 行都一樣,所以**停頓不在複製這個動作上**。真正的原因在 SwiftTerm 原始碼裡:CoreGraphics 路徑的 `selectionChanged` 直接設 `needsDisplay = true`——**整個 view 重畫**,而拖曳選取時每一次滑鼠移動都會觸發一次。實測重畫 1200×800 是 7.2 ms/幀,2560×1440 是 **22.4 ms/幀**,後者超出 16.7 ms 的 60fps 預算,那就是停頓的來源。另外讀原始碼也**排除了**「copy on select」的嫌疑:它只掛在 `mouseUp`,不是每次拖曳都寫剪貼簿。**結論是不需要 libghostty**:SwiftTerm 自己就有 Metal 算繪器,只標記髒掉的列而不是整頁重畫,而我們從來沒有開過它。新增設定「GPU rendering」（`TerminalDefaults.usesMetalRenderer`,2 測試）。**預設關閉**——這是換算繪器,會配置 MTKView、每次換視窗要重新綁定,GPU pipeline 建不起來時 SwiftTerm 自己會退回 CoreGraphics;預設關閉表示這裡真的有 bug 時,受影響的只有主動要求它的人。**但它會即時套用到已開啟的分頁**（與 scrollback 相反）:換算繪器不會丟掉任何一行或任何選取,而能夠在拖曳當下開關比較,正是這個設定存在的意義）
（**量 libghostty 這件事,量出了一個不相干但更重要的缺陷:scrollback 只有 500 行**。基準測試裡 `selectAll` 不論餵多少行都只選到約 500 行——那是 SwiftTerm 的預設,而我們從來沒有設過它。**那是終端機元件的預設值,不是連線管理器的**:500 行是一份 build log 的幾秒鐘,而長時間連線的人第一件事就是往回捲得比那更遠。改成預設 **10,000 行**,並在設定裡可調（500–100,000,`TerminalDefaults`,4 測試）。緩衝區是隨輸出成長而非預先配置,所以閒置的分頁不會因此多花記憶體;上限是刻意的——一格二十萬行是數百 MB,一整片這種分頁就是被系統終止的原因。**設定改動不追溯既有連線**:縮小它會丟掉使用者眼前還看得到的 scrollback,那不是一個偏好設定該做的事）
（**終端機效能實測(2026-08-21)**——起因是「要不要換 libghostty」,而**沒有量測到的問題不值得重寫**。`TerminalThroughputBenchmark`（預設略過,`MACMOBA_BENCH=1` 才跑）量的是 App 實際出貨的那顆引擎。這台 M 系列 Mac 上:**解析** plain 5.4 MB/s、帶色 4.7 MB/s、**中文只有 1.9 MB/s**;**整頁重畫** 1200×800 為 7.2ms（約 139fps 天花板）、2560×1440 為 22.4ms（**45fps,低於 60**）。**兩個要老實講的限制**:①`cacheDisplay` 走的是點陣圖路徑,與螢幕上的實際重畫不同,而後者通常只重畫髒掉的列,所以 22ms 是**最壞情況**而非日常;②讀取 scrollback 的那條路在無視窗環境下拿不到 scroll-invariant lines,量不到,**所以那項刻意不報數字**——一個很快得到的空緩衝區,比沒有數字更糟）
（**異質分割專案完成（v1.99→v2.13）**:分割樹的葉子從「就是終端機」變成 `PaneContent`,假葉子消失,四種內容可任意混用,版面會被還原。**回頭看,這個專案的 bug 分成兩類,而它們需要完全不同的對付方式**:①**語意漂移**（五個）——`panes` 從「所有格子」變成「終端機格子」、`vnc` 從「這是 VNC 分頁」變成「樹裡有 VNC」,型別一個字沒動,編譯器一個都抓不到,只能靠使用者實測一個一個浮出來;②**視圖歸屬**（黑屏,修了四次）——前三次都在推理、都沒中,第四次加診斷、一次命中。**教訓不是「要多寫測試」**（純邏輯的部分本來就有 763 個測試在守,而這兩類 bug 沒有一個是純邏輯出錯）,而是:**重構改變一個名字的意思時,要把所有呼叫點當成新程式碼重讀一遍**;以及**症狀在畫面上、原因在框架裡時,不要猜,把當下狀態印出來**）
（**使用者實機驗收通過（2026-08-21, v2.13）**。 **VNC 黑屏的真正成因,由診斷直接指出來**:`container: bounds 713×931 · superview yes · window none` 配上 `frames received: 58`——**有父視圖、尺寸正確、連線活著、影格一直來,卻不在任何視窗裡**。兩個 SwiftUI representable 在搶同一個實體畫面:新分頁建立時把它移到自己的 host（當下還沒進視窗）,接著**正在被拆除的舊分頁**跑了一次 `updateNSView`,又把它搶回一個永遠不會進視窗的 host。**誰最後呼叫誰贏,而輸的那個可能正是螢幕上的那個。** 先前三次修的都是下游症狀,所以都沒中。修法是一條規則:**永遠不要把還在畫面上的東西,搬進一個不在畫面上的 host**（`SurfaceHosting.attach`）——沒有視窗的 host 不是「即將取得」就是「即將被丟棄」,從那裡分辨不出來,而拒絕搬動在前者只是等下一輪、在後者則救了整個工作階段。配一道保險:host 改用 `SurfaceHostView`,**自己**在進入視窗時回報,不必等 SwiftUI 的更新時機。VNC／RDP／Web **三者共用同一條規則**——這正是 2.09 學到卻沒推廣的那個教訓,這次一次推到底）
（**VNC 黑屏第三次:改成重建 view,而不是設法喚醒它**（2.10 的補觸發無效——使用者實測仍黑）。**RoyalVNC 自己給過答案**:畫面尺寸改變時它的作法是「view 在建構時就綁定了一個 framebuffer,與其去戳舊的,不如**建一個新的**」（`VNCTab.didResizeFramebuffer` 的既有註解）。搬動視窗階層是同一類問題——display link 也是建構期綁定的——所以同樣的答案適用。改成:重新掛載後**重建 framebuffer view**（需要記住 `framebuffer`,先前沒有留）。**順帶堵住一個必然的坑**:新 view 是空的,要等伺服器下一幀才會有畫面,而遠端桌面靜止時那可能很久,看起來就跟這個 bug 一模一樣——所以裝好後立刻把手上這一幀推給它。**三次都是同一個回報,三個不同的層次**:容器被拔走 → 沒人重畫 → 喚不醒就換掉）
（**解散分割後 VNC 仍黑屏,但切到別的分頁再回來就好**（使用者實測 2.09）。**「切回來就好」正是答案**:容器早就接對了,是**沒有人重畫**。RoyalVNC 只在 `viewDidMoveToWindow` 裡建立 display link,而且要求當下**已經有 window**（`VNCCAFramebufferView.swift:145,164`）——重新掛載的過程會先把它移除,重新進入視窗的時機卻不保證再觸發一次,於是連線照送影格、沒有人把它畫上去。切分頁強迫了一次 layout,才把它救回來。修法:掛載完成後在下一個 runloop **明確再要求一次**（`viewDidMoveToWindow()` + `needsDisplay`）。2.09 把「容器被拔走」修好了,這一版修的是它留下的第二個症狀——**同一個回報裡其實藏了兩個 bug**,第一個修完才看得見第二個）
（**解散分割後 VNC 一片黑**（使用者實測 2.08 抓到;分頁狀態燈是綠的,連線還活著,只是畫面沒了）。`VNCHostView.makeNSView` **直接把共用的 container 交給 SwiftUI 當自己的 view**——單一分頁時沒事,但把那一格搬進新分頁時,SwiftUI 會建一個新的 representable,而**舊的那個在拆除時把 container 從新階層裡拔了出來**,於是連線照舊在畫,只是畫到不存在的地方。**這個病 Web 分頁早就治過**（`WebViewHost.attach` 的註解:「一個 web view,它屬於當下在畫面上的那個容器」）,只是 VNC 與 RDP 沒跟上。兩者都改成同一個規則:SwiftUI 擁有一個普通的 host view,那唯一的實體畫面則被**搬進當下在畫面上的那個 host**。**教訓**:同一份修法在別處已經寫下、還附了說明,卻沒有推廣到同型的另外兩處——那不是沒學到,是學到之後沒有掃過去）
（**分割時邊框壓住最左欄的字**（使用者截圖:提示符前面那個 `[` 被綠色焦點框吃掉）。廣播邊框與焦點邊框都是**畫在 pane 上面的疊層**,而終端機填滿整個框架,於是那 2–4 pt 直接蓋在第一欄字元上。修法不是把邊框畫細,而是**給它自己的空間**——分割時內容內縮 4pt,邊框框住的是那圈留白。遠端桌面那格同理）
（**分割版面現在會被還原**（使用者要求）。先前只存一份頂層 session id 清單,所以三個 shell 配一個遠端桌面,重開後變成四個互不相干的分頁——**每天早上手動排回去,正是連線管理器該消滅的工作**。新增 `PaneLayout`（可 Codable 的遞迴樹,8 測試）:存的**只有 session id,絕不是連線**——還原的每一格都是重新撥號,跟從側邊欄開一樣。**修剪規則是重點**:期間被刪掉的連線只該賠上它那一格,不該賠上整個版面,所以剩一邊的分割會**收合**而不是留下空洞;而一整個分頁只剩空格時**不還原**——那會生出一個你打不了字也沒要求過的分頁。向後相容兩個方向都顧到:讀得懂舊的扁平清單,也繼續寫一份舊格式,所以降版不會失去工作區。存檔時機也補齊——分割、併入、解散、關閉某一格都會即時存,不再只有開關分頁才存）
（**異質分割:使用者實機驗收通過（2026-08-20, v2.06）**——SSH 與 VNC 同框、任一側可關可拆、標題與徽章跟著聚焦的那一格。 **`▦n` 徽章消失**（使用者實測 2.05 抓到）。`title` 開頭有三行早期返回:`if let vnc { return vnc.title }`——寫於 `vnc` 還代表「這個分頁**就是**一個 VNC 分頁」的年代。改成從樹推導之後,它的意思變成「樹裡有沒有 VNC 葉子」,於是**只要分割裡有一格是遠端桌面,整個分頁就用那格的標題並跳過徽章**。三行純屬殘留:下面的 `focusedContent?.title` 本來就涵蓋所有種類。`snapshotView` 與 `aggregateState` 有同樣的殘留,一併改成看**目前聚焦的那一格**——Overview 的縮圖現在也會顯示你最後在看的那一格,而不是永遠優先遠端桌面。**這是同源的第五個 bug**,而它們全都不是新寫的程式碼出錯,是**舊呼叫點的語意在型別不變的情況下悄悄改變**）
（**分頁右鍵選單**（使用者要求）:`Break Apart into Tabs`（超過一格時才出現）與 `Close Tab`。理由很直接——**`▦n` 那個徽章就長在分頁 chip 上**,手會在那裡找解散分割的方法。這是同一個功能的第三個入口（Session 選單、分割選單、分頁右鍵）,而三個都不是多餘的:它們對應三種不同的尋找路徑——「從選單列找功能」「從做出分割的地方找反操作」「從看到分割的地方按右鍵」）
（**解散分割:功能本來就有,但等於沒有**（使用者要求「加功能解散分割,變成 4 個 tab」——那正是既有的 `ungroupPanes`）。**兩個問題各修各的**:①**找不到**——它只在 Session 選單裡叫「Move Panes to Separate Tabs」,而人會去找「怎麼取消分割」的地方是**做出分割的那個選單**。分割選單底下加「Break Apart into Tabs」。②**只搬終端機**——遠端桌面那格會被留下,而它正是你想分出去的東西之一。`detach`／`adopting` 改成吃 `PaneContent`,`ungroupPanes` 走**所有葉子**。Session 選單那項的啟用條件也從 `panes.count`（終端機數）改成 `paneCount`（格子數）——**又一個沿用舊語意的呼叫點**,型別相同所以編譯器抓不到）
（**「Move Open Tab Here」還停在舊語意**（使用者實測 2.02:新開 SSH 可以分割進 VNC 分頁,但**把已經開著的 SSH 分頁併進來不行**）。`mergeTab` 的守衛要求**兩邊都有終端機**,而它的註解還在解釋一個已經不存在的世界——「VNC 分頁把真正的內容放在樹外面,併進來只會拿到假葉子」。現在整棵樹就是內容,所以守衛改成 `canSplit`（兩邊都要有樹:只有本機 shell 與純檔案瀏覽器沒有）,`merge` 也改成接收**整棵子樹**而不是一份終端機清單——`panes` 那個參數本身就是舊模型的殘留。連線跟著葉子走,不再屬於它出生的那個分頁）
（**第三步:遠端桌面真正住進分割樹,假葉子徹底消失**（使用者要求:先開 VNC 也要能分割出 SSH）。VNC/RDP/Web 分頁原本是「假終端機葉子 + 分頁層級屬性」,所以它們**不能被分割**。現在三個 init 都直接把自己放進樹裡（`root = .leaf(.vnc(tab))`）,`vnc/rdp/web` 三個屬性改成**從樹推導**——一個分頁可以同時有 shell 和桌面,「這個分頁的 VNC」就不該是另一個存放真相的地方。**關鍵是把 `isSinglePane` 這個被混用的旗標拆成兩個**:`hasTerminalPanes`（log／搜尋／ZMODEM／傳輸／廣播真正需要的:有沒有東西在搬位元組）與 `canSplit`（能不能在旁邊放一格）。29 個呼叫點逐一歸位——它們過去**碰巧**都成立,只因為當時每個葉子都是終端機。`focusedPane` 也改成焦點在遠端桌面時回傳 nil,而不是默默交出另一格;`panes` 的註解從「⚠️ 小心假葉子」改成陳述事實,因為那個陷阱不存在了）
（**關掉 SSH 只剩 VNC 後,分頁標題與圖示仍是 SSH**（使用者實測 2.00 抓到）。又是同一個根源:標題取自 `focusedPane`（**只認終端機**）,終端機關掉後變 nil,退回分頁建立時的 `config.name`;圖示也只看分頁層級的 `vnc/rdp`,樹裡的葉子它不看。新增 `focusedContent`——**目前聚焦的那一格,不管它裝什麼**——標題與圖示都改讀它。**這是第三個同源的 bug**（前兩個:關閉判斷、格子計數）,而它們有同一個教訓:**把型別變誠實之後,舊語意的呼叫點會靜靜地錯下去**,因為 `panes` 從「所有格子」變成「終端機格子」時,型別沒變、編譯器不會抓）
（**關掉 SSH 那一格,VNC 也一起關掉**（使用者實測 1.99 抓到）。`closePane` 用 `panes.count > 1` 判斷「是不是最後一格」,而 `panes` **只算終端機**——一個 SSH 配一個 VNC 時它等於 1,於是關閉被拒絕,上層退回「關整個分頁」,VNC 陪葬。改成用 `paneCount`（所有葉子）;`detach`、分頁標題的 `▦n`、pane 外框的顯示條件也一併改。**這正是重構沒做完的那一半的代價**:型別已經誠實了,但**沿用舊語意的呼叫點還沒跟上**——`panes` 現在的意思是「終端機」,任何拿它當「格子數」用的地方都錯了）
（**分割窗格支援異質 session**（使用者要求:一邊 VNC 一邊 SSH）。**根因是型別在說謊**:分割樹的葉子原本就是 `TerminalTab`,所以 VNC/RDP/Web 分頁必須在樹裡塞一個**永不連線的假終端機**才能讓 `root` 非 optional——那個假葉子在型別上完全看不出來,程式裡的註解自承「好幾個 bug 都來自沒先檢查 `isSinglePane`」。**分兩步做,第一步刻意零行為改變**:葉子改成 `PaneContent` 列舉、只有 `.terminal` 一種,755 測試全綠才進第二步——重構與行為改動混在一起,出事時就分不清是哪個造成的。第二步加入 `.vnc/.rdp/.web`,**編譯器立刻列出所有沒處理的地方**（那正是把型別變誠實的用處）。`PaneContent.terminal` 回傳 optional,所以打字、log、搜尋、ZMODEM、廣播這些「搬位元組」的功能**在構造上就跳過非終端機葉子**,不是靠記得去檢查。分割選單解除過濾,只留下 serial 例外（一個埠一條連線）。分頁的連線狀態改成彙總**所有**葉子。**仍未做（第三步）**:焦點在非終端機葉子時,`focusedPane` 仍會退回第一個終端機——log/搜尋因此可能作用在你沒在看的那一格）
（**「按了 Health 看不出有什麼不同,尤其資料夾收起來時」**——三個都是真的缺口。①**資料夾收合時把成員的燈藏光了**,而那正是最需要一眼看出有沒有東西掛掉的時候:收合的資料夾現在顯示**彙總標記**（`GroupHealth`,5 測試）。規則刻意不對稱:**有東西掛掉才值得一個紅點加數字**,全部正常給一個安靜的綠點,而「什麼都還沒測」**不給任何標記**——一整排灰點是雜訊,而一個代表「沒有資訊」的燈號,只會教人學會忽略燈號。②**按鈕的開啟狀態不明顯**:工具列顯示文字標籤後,SwiftUI 的凹陷樣式讀不出「開著」,改成開啟時圖示轉綠。③**按下去沒有回饋**:第一次掃描落地前畫面幾乎不變,資料夾收著時更是完全不變,所以現在會跳橫幅說明「開始監測 N 台、每 15 秒一次」或「沒有可直接探測的主機」）
（**「側邊欄資料夾收合不了——剛剛不行,現在又可以」**。間歇性正是線索:當時**輸入還在擷取狀態**。擷取期間本機游標是停住且隱藏的,滑鼠移動只驅動遠端指標,所以那一下點擊實際上落在 VNC 畫面裡、被轉發給遠端,側邊欄根本沒收到;按 ⌃⌥ 放開後就恢復。**程式沒有錯,錯的是它不說話**——提示膠囊 3 秒後淡出,之後使用者無從得知自己仍在擷取狀態,App 看起來像壞了而不是像忙著。改成淡出後留一個**常駐的小鎖徽章**（hover 顯示解除方式）。同一個原則第三次出現在這個功能上:**功能「沒反應」時若無法從畫面判斷是正常還是故障,那本身就是設計問題**）
（**這一輪（v1.66→v1.96）的驗收清單全部清空**:VNC 輸入擷取、剪貼簿四個方向、Overview 縮圖、注意力脈衝與系統通知、CLI 對真分頁、Auto 主題、群組儀表板與跳板健康檢測、ZMODEM 雙向、X11 forwarding、隧道載體過濾、斷線後 Esc 關閉分頁——全部由使用者實機驗收通過。**回頭看,這一輪十幾個真 bug 有一個共同點:症狀出現的地方幾乎從來不是病灶所在**——剪貼簿不通是鍵盤焦點壞了、瀏覽器複製不了是 VNC 擷取沒解除、「打一個 a 出兩個」是 optional chaining 把兩種 nil 壓成一種、「游標永遠是箭頭」是自己畫的那顆停格。每一個都是靠**把當下狀態直接印出來給使用者複製回來**才夾到的,不是靠讀程式碼猜出來的;凡是靠猜下的結論,後來幾乎都被推翻（「Apple 不送剪貼簿」「伺服器只送同一顆游標」兩條都錯,已在文中就地更正））
（**ZMODEM 雙向:使用者實機驗收通過（2026-08-20, v1.96）**——下載存進 `~/Downloads`、上傳成功。 **ZMODEM 上傳:先手動跑 `rz` 反而會卡死**（使用者實測撞到,**而且是我的測試步驟寫錯**——叫他先跑 `rz`）。`beginSend` 本來就會**自己在遠端打 `rz`**（MobaXterm 的作法:你只管送）,所以當一個 `rz` 已經在等時,那句 `rz\r` 會被當成**傳輸資料**餵給它,兩端一起卡住。**下載方向使用者已驗收通過**（`sz` → 檔案正確存進 `~/Downloads`）。修法:`ZModem.receiverIsWaiting` 辨認 **ZRINIT**（frame type `B01`,`rz` 等待時會不斷重送),與下載的 ZRQINIT（`B00`）分開——閒置期間看到它就記住「遠端已有接收端」,送檔時便跳過那句 `rz`。**記住而不吃掉**:在傳輸真正開始前那仍然是終端輸出。3 個新測試,含「ZRQINIT 不可誤判為等待中的接收端」。文件補上正確用法與 `rz` 的落地目錄）
（**使用者實機驗收通過（2026-08-20, v1.95）**。 **斷線後按 Esc 關掉分頁**（使用者要求;Enter 重連本來就有）。規則抽到 Core 的 `DeadTerminalKey`（4 測試）,**判斷的是整串按鍵位元組,不是「有沒有包含 0x1b」**——方向鍵與功能鍵送出的第一個位元組正是 Escape（`ESC [ A`）,用 contains 判斷的話,任何人按上鍵找上一個指令都會把分頁關掉,測試專門盯著這件事。關閉走既有的 `WindowState.closePane(_:in:)`:分割狀態下只關那一格,剩最後一格時才關整個分頁——那正是「關掉這個」在只剩一格時的意思。斷線覆蓋層的提示也從「or press Return」改成 **「Return to reconnect · Esc to close」**,兩條出路都寫在你需要它們時會看的地方）
（**隧道的「Via session」列出了不可能承載它的連線**（使用者發現）。隧道就是一條 SSH channel,所以載體必須會說 SSH——遠端桌面、序列埠、網頁不管機器多通都不行。選單先前用 `ForEach(app.data.sessions)` 列出**全部**;更隱蔽的是 `load()` 在新建時預設 `app.data.sessions.first`——**任何種類的第一條**,可能是 VNC 或序列埠,於是新隧道一開始就指向一個永遠啟動不了的載體。規則抽到 Core 的 `TunnelHosts`（5 測試,**Mosh 算數**:它的設定本來就是一組 SSH 登入,那正是 mosh 啟動的方式,所以 forward 會沿用同一組憑證與跳板鏈）。另外處理**舊資料**:先前存下、指向不合格連線的隧道,開啟編輯器時會把該欄清空而不是顯示一個空選單配著失效的 id——Save 會保持禁用直到重選,總比讓人以為它還有效好。連線編輯器的「Via jump host」本來就已經過濾了,這次只補上隧道這一處）
（**「自選主題沒有變」——不是 bug,是標示不清**。使用者實測時眼前多半是 VNC 分頁,而主題只作用在**終端機**:遠端桌面顯示的是對方的畫面、網頁有自己的樣式、側邊欄與視窗跟隨**系統**外觀。切到終端機分頁再選 GitHub Light 就當場變白,路徑本來就是好的（Auto 那次文字顏色也有跟著變,證明 `installColors` 確實有跑,不是 SwiftUI 背景層的錯覺）。**沒有程式缺陷要修,但這個誤會值得花一行字避免**:設定裡的主題選單下方補上作用範圍說明——一個功能的「沒反應」若無法從畫面上判斷是否正常,那本身就是設計問題）
（**使用者實機驗收通過（2026-08-19, v1.92）**:遠端→本機中文正常。 **⌥⌘C 的兩個實機問題**。①**「找不到 SSH 連線」但明明有**:比對是照 host 字串做的,而同一台機器在兩條連線裡往往寫法不同（`mac-mini.local` 對 `mac-mini`）。加上**第一個標籤**的比對,並刻意**排除純位址**——`192.0.2.10` 的第一個標籤是 `192`,那會match到半個網段。錯誤訊息也改成明講「找的是哪個 host、現有的 SSH 連線指向哪些 host」,因為要修的正是那個差異。②**中文全變成 `?`**:`pbpaste` 會照 locale 的編碼輸出,而 exec 通道沒有 TTY、通常也沒有 locale,於是非 ASCII 全被替換成問號。指令改成 `LC_ALL=en_US.UTF-8 pbpaste`。兩者都有測試盯著）
（**遠端→本機剪貼簿:繞過 VNC,走同一台機器的 SSH**。診斷已經證實 macOS 的 VNC 伺服器**一次都沒送過** `ServerCutText`（`received from server: 0`,`recent lines` 裡沒有任何 `Receiving Clipboard Text`）,而協定也沒有「去問遠端選取內容」這種訊息——所以這個方向在 VNC 裡是死路。**但那台機器通常另有一條路**:會在某台機器上開遠端桌面的人,幾乎都在同一台機器上有 shell。`RemoteShellMatch`（5 測試）**依 host 比對**挑出保險箱裡指向同一台機器的 SSH 連線（不是依名稱——桌面連線與 shell 連線描述同一台機器,卻幾乎不會同名;且只有能跑指令的種類才算候選,VNC／web／serial 一律排除）,再用既有的 `SSHConnection.runCommand` 跑 `pbpaste`（Linux 退回 `xclip`／`xsel`）,結果寫進本機剪貼簿。入口 **⌥⌘C**,與 ⌥⌘V 一樣**保留不轉發**,所以擷取輸入時照樣可用）
（**使用者實機驗收通過（2026-08-19, v1.90）**:MBA→Mac mini 中英文皆可貼上。 **⌥⌘V 有送出按鍵卻打不出字:修飾鍵還壓著**。診斷把它釘死了——`last ⌘/⌥ chord seen by the monitor: keyCode 9 → "v" · command true option true · desktop found true` 加上 `keys sent: 9`,證明快捷鍵確實觸發、也確實送出 9 個鍵;但使用者截圖顯示遠端「跳到別的地方、一個字也沒有」。原因:按 ⌥⌘V 的當下 ⌘⌥ 是**實體按下**的,RoyalVNC 已透過 `flagsChanged` 把「Command 按下」送給遠端,我們吞掉的只有 V 那一下——於是逐字送出的 `h e l l o` 在遠端變成 **⌘H ⌘E ⌘L**,一連串選單快捷鍵。修法:打字前先對遠端送出所有修飾鍵的 keyUp（左右兩側都送）,使用者放手時實體事件自然會再同步回來。**這份診斷還意外證實了 1.85 的必要性**:報告是從選單觸發的,而它抓到 `key window: none · app active: false`——選單追蹤期間真的沒有 key window,所以先前只查 `keyWindow` 的寫法必然失敗）
（**VNC 輸入這條線全部驗收通過（2026-08-19, v1.88）**:⌃⌥ 解除、Esc 完全交給遠端（cmux 裡的 Claude Code 照常用 Esc Esc）、切分頁後點擊／打字／瀏覽器複製都正常、⌥⌘V 中文貼上正常。**清掉兩處過時註解**——刪掉 Escape 分支時把它的說明留在原地,底下卻是不相干的程式碼,那是最會誤導人的一種註解）
（**Esc Esc 選項整個移除**（使用者要求）:只剩 ⌃⌥ 一種解除手勢。連帶刪掉 `DoubleEscapeRelease` 與它的 6 個測試（沒有使用者的程式碼留著只會誤導後來的人）、選單開關、以及 `handleKey` 裡的 Escape 特例分支——**Escape 現在完全不被攔截**,原樣走 RoyalVNC 的 keycode 路徑送給遠端。**踩到一個自己造成的坑**:刪除區塊時把夾在中間的 `RelativePointer` 一起切掉了,編譯即刻報錯、補回;測試數 739→730 是移除那 6 個 Escape 手勢測試加上重算的結果）
（**使用者實機驗收通過（2026-08-19, v1.86）**:瀏覽器分頁複製正常。 **擷取會活得比它的桌面久,結果吃掉整個 App 的點擊**——使用者回報「瀏覽器分頁複製不了文字」。追下去發現:切換分頁時 SwiftUI 會把 VNC 的 view 移出視窗,但**沒有任何東西解除擷取**（目前只有視窗／App 失焦才解除）。擷取生效期間,監控器會把**所有**滑鼠按下事件吞掉轉給遠端——包括你點在網頁上的那一下,網頁因此拿不到焦點、選不了字,⌘C 自然沒東西可複製。修法是自癒式的:每個事件進來時,若 `isGrabbed` 但 `grabbedView?.window == nil`,立即解除。比在切換分頁的地方補呼叫更可靠——view 因為任何理由離開視窗都算數,不必窮舉那些理由）
（**使用者實機驗收通過（2026-08-19, v1.85）**：中文可打、可貼。 **「no remote desktop in this window」——遠端桌面明明就在畫面上**。`focusedFramebufferView` 只看 `NSApp.keyWindow`,而**選單動作執行的當下 keyWindow 可能是 nil**（選單追蹤尚未完全結束）,多視窗時也會找錯窗。改成:焦點優先,接著依序找 keyWindow → mainWindow → 所有可見視窗。這同時解釋了 ⌥⌘V「never used」:鍵盤那條路的判斷式同樣以它為前提,找不到就整個跳過）
（**解除擷取的手勢改成 ⌃⌥,Esc Esc 降為選項**——使用者實機撞到我當初就提出的衝突:遠端跑 Claude Code 時,**Esc Esc 會觸發它的「回到上一個訊息」**。這是設計上的必然:我們**刻意把兩下 Esc 都轉發給遠端**（否則遠端就永遠收不到 Esc）,所以只要遠端也把 Esc Esc 當快捷鍵,就一定會一起觸發。當初使用者在 ⌃⌥／⌃⌘／雙 Esc 之間選了雙 Esc,理由充分——但代價現在具體化了。`ModifierChordRelease`（4 測試）:**按住 ⌃⌥ 再放開**即解除,**手勢在放開時才完成**所以不需要計時器、也不會在你還在猶豫時誤觸;中途按下任何鍵即取消（⌃⌥ 加字母是遠端該收到的快捷鍵,不是半成品手勢）。**單獨按修飾鍵對任何程式都沒有意義,所以這個手勢在構造上不可能與遠端衝突**——這正是 VMware／Parallels 都選修飾鍵組合的原因。Esc Esc 保留為 Session 選單裡的選項,畫面上的提示文字跟著設定走）
（**⌥⌘V 逐字貼上:使用者實機驗收通過（2026-08-19, v1.82）**——中文成功貼進遠端的文字編輯器,證實 X11 Unicode keysym（`0x01000000 + 碼位`）這條路是對的。 **更正一個我下錯的結論**:1.81 記載「macOS 的 VNC 伺服器不理會標準的 `ClientCutText`」——**是錯的**。使用者在 1.82 之後回報**英文可以貼**,證明那條路一直是通的;先前看起來失效,真正的原因是**焦點壞掉**（擷取吞掉點擊 → `makeFirstResponder` 沒被呼叫 → ⌘V 根本沒送到遠端）。當時我把「症狀出現在剪貼簿」誤讀成「原因在剪貼簿」,而且在有替代解釋的情況下就下了結論。**中文不行則是真的協定限制**,診斷直接印出來:`local clipboard survives Latin-1: NO — cannot be sent by RFB`。所以 ⌥⌘V 的逐字輸入仍然是必要的,只是它的定位從「唯一的貼上方式」變成「非 Latin-1 文字的貼上方式」）
（**⌥⌘V 沒反應,而且挖出一個擷取功能造成的潛在破壞**。所有按鍵處理都以「first responder 是 VNC 畫面」為前提,而 RoyalVNC 原本是靠它自己 `handleMouseDown` 裡的 `makeFirstResponder(self)` 取得焦點的——**但擷取功能把那一下點擊吞掉了**（`return nil`）。後果:點過側邊欄再點回畫面,焦點就再也回不去,**鍵盤整個不通**,⌥⌘V 只是第一個被注意到的症狀。兩處修:①擷取時自己呼叫 `window.makeFirstResponder(view)`;②⌥⌘V 的判斷移到焦點守衛**之前**,並改用「在視窗裡找 framebuffer view」——一個要焦點剛好正確才會動的貼上不算貼上（同 Escape 的道理）。診斷報告加一行「上次 ⌥⌘V 送出幾個鍵」,以便分辨「沒觸發」與「送了但遠端沒吃」）
（**剪貼簿定案:改用「打字」把本機內容送進遠端**。診斷把路徑釘死了:`sent to server: 14`——監控器有發現複製、`ClientCutText` 有排入佇列,而佇列確實會被排出寫進 socket(`VNCConnection+Send.swift:58`);`local clipboard survives Latin-1: yes`——內容也不是編碼問題。加上**使用者實測「原生 Screen Sharing 貼得上去」**,結論只剩一個:**macOS 的 VNC 伺服器不理會標準的 ClientCutText**,Apple 自家 App 走的是私有擴充。那條路我們接不上。**替代方案**:`RemoteTyping.keysyms(for:)` 把文字轉成 X11 keysym 逐字送出——關鍵是非 ASCII 要用 **Unicode keysym 範圍(`0x01000000 + 碼位`)**,而不是把碼位直接當 keysym（RoyalVNC 自己那條就是後者,會落進舊的 keysym 表打出別的字元;7 個測試盯著這件事,含中文與 emoji）。所以**中文也能貼**,反而比協定原本的 Latin-1 剪貼簿能做的更多。入口 **⌥⌘V**,刻意**不轉發給遠端**（遠端永遠收不到這個組合鍵）,這樣擷取輸入時仍然可用——那正是選單碰不到的時候。逐鍵間隔 6ms:合成按鍵走的是與實體鍵盤相同的路徑,整批塞進同一個 frame 會被丟掉或亂序。
**同時更正一項先前的錯誤結論**:游標診斷這次回報 `24×18, hotspot 12,9`,與先前的 `28×40, hotspot 5,5` **不同**——所以伺服器**確實會送不同形狀**,先前「永遠只送同一顆箭頭」的判斷是錯的,已從已知限制中撤回）
（**剪貼簿:一半修好了,另一半找到疑似根因**。使用者實測 1.79:**Mac mini→MBA 通了**（⌘ 組合鍵翻譯的功勞——證實先前那個洞是真的）,**MBA→Mac mini 仍然不通**。往送出那條路讀,`ClientCutText.swift` 第一行就是:`text.data(using: .isoLatin1) ?? .init()`——**RFB 的標準剪貼簿訊息只能承載 Latin-1**,中文轉不過去就變成 `.init()`,也就是**送出一個空訊息**,遠端剪貼簿被設成空的,貼上自然沒反應。Unicode 要靠 **extended clipboard** pseudo-encoding,而那個在 RoyalVNC 是明擺著的 TODO（`VNCConnection.orderedEncodingTypes` 裡註解掉的那行）。**尚待使用者確認**:用純 ASCII 文字測 MBA→Mac mini——若 ASCII 可以、中文不行,即證實。診斷報告新增一行直接顯示「本機剪貼簿內容能否通過 Latin-1」,並換上自己的 `VNCLogger` 收集函式庫的剪貼簿日誌（`logDebug` 是無條件呼叫的,過濾在 logger 內部,所以這麼做零成本、也不必開任何設定）。若證實,可行的補救是「以模擬按鍵把文字打進遠端」,而不是等 extended clipboard）
（**剪貼簿兩個方向都不通**（使用者實機回報:MBA→Mac mini 貼不上,Mac mini→MBA 也抄不回來,擷取狀態下也一樣）。排除的:RoyalVNC 的剪貼簿計時器**有**編進來（`VNCClipboardMonitor` 整段被 `#if !canImport(FoundationEssentials)` 包住,實測本工具鏈認不得 FoundationEssentials,所以是編進去的）、連上時確實會 `startMonitoringClipboard()`、收到 `ServerCutText` 會直接寫進 `NSPasteboard.general`。**兩個方向同時失效**指向一個共同上游:**⌘ 組合鍵根本沒送到遠端**——那正是先前修正**刻意留下的洞**:未擷取時 ⌘C/⌘V 仍走 RoyalVNC 的 `charactersIgnoringModifiers`,一樣會被速成輸入法改寫。補上:凡是遠端桌面取得焦點時,⌘/⌃/⌥ 組合一律經 ASCII 配置翻譯後由我們送。**這樣不會搶走自家選單快捷鍵**——理由是那個狀態下 RoyalVNC 本來就用 `performKeyEquivalent` 把 ⌘ 組合吃掉並轉發（見其 `handlePerformKeyEquivalent`）,所以 ⌘C 早就不屬於 MacMoba 的選單了,我們只是讓送出去的東西是對的。**尚未證實**——若補完仍不通,下一步用滑鼠右鍵選單的拷貝/貼上把按鍵完全排除,以判定是不是剪貼簿訊息本身沒流動）
（**使用者實機驗收通過（2026-08-19, v1.78）**。 **Overview 只有目前這一頁有縮圖**（使用者實機回報,其餘全是大圖示）。成因:一次只有一個分頁在視窗裡,SwiftUI 會把其他分頁的 view 移出階層,`snapshot()` 的 `view.window != nil` 因此失敗。兩處修:①**遠端桌面根本不需要視窗**——畫面存在 `layer.contents` 裡,view 被移出階層也還在,所以 VNC/RDP 改成不看 `window`;②**終端機在被切走的那一刻先拍一張存起來**（`WindowState.selectedTabID.didSet` 裡對 `oldValue` 呼叫 `cacheSnapshot()`——那是它的 view 還在視窗裡的最後一刻,晚一步 SwiftUI 就撤掉了）,Overview 拿不到即時畫面時就用上一張。**仍然沒有縮圖的情形**:開機還原後從未被點開過的分頁——它從來沒有被畫出來過,沒有東西可拍）
（**使用者實機驗收通過（2026-08-19, v1.77）**：脈衝清楚可見。**尚未回報的部分**:系統通知與點擊跳轉、⌥⌘U 循環。 **注意力藍點改成雷達式脈衝**——使用者實機回報「有看到藍點,但不是很顯眼」。一排分頁裡的靜止小點確實容易漏掉。改成**實心點外圈向外擴散淡出**（1.1 秒循環）;關鍵取捨:**底下那顆點全程保持實心**,因為它是狀態指示,一個只有在對的瞬間才讀得到的狀態比安靜的狀態更糟。**尊重「減少動態」系統設定**:開啟時不做動畫,改為靜態光暈——不該把一個永遠在動的視窗塞給明確要求減少動態的人）
（**VNC 輸入擷取:使用者實機驗收通過（2026-08-19, v1.76）**——移動手感與 Esc Esc 解除都正常。定案的組合是:鍵盤送**實體鍵**（不受本機輸入法影響）+ 點進畫面即擷取 + 指標與硬體脫鉤由移動量驅動、**整段期間真游標不動**（每次移動都 warp 會壞掉手感,試過並撤回）+ 連按兩下 Esc 或長按 Esc 一秒解除 + 失焦暫停、回來自動恢復）
（**游標形狀不變 = 伺服器端行為,查證結束**。使用者用內建診斷做了決定性的三次取樣：連線時 `updates: 8` → 過一陣子仍 `8` → 再過一陣子 `12`,**但 `last cursor` 三次完全相同（28×40, 32bpp, hotspot 5,5）**。所以伺服器**持續在送**游標更新（數字會長）,**送的卻永遠是同一顆箭頭**——既不是「Apple 不送」,也不是「解碼失敗」,更不是「我畫的沒更新」。macOS Screen Sharing 就是不回報形狀變化,客戶端忠實畫出收到的東西;**擷取與未擷取表現一致**,所以不是擷取造成的。**（後續推翻:見 1.81——伺服器其實會送不同形狀）**。診斷用的計數器與 Session 選單項目保留——這種「什麼都沒發生」的回報,沒有它就無法回答）
（**診斷給了答案,兩件事一起修**。使用者跑 1.75 的診斷：`cursor updates received: 15 / empty: 0 / last cursor: 28×40, 32 bpp, hotspot 5,5`——**伺服器有送、也解得出來**,所以前面兩個猜測（Apple 不送、解碼全透明）都被排除,真相是第三種：**我畫的那顆沒跟著更新**。1.71 與 1.74 其實是同一個病:畫上去的游標**停在擷取當下那一顆**,只是起始值一個剛好是 I 字形、一個是箭頭,看起來像兩個不同的 bug。改成**推送**：`didUpdateCursor` 一到就直接更新畫上去的圖（`RemotePointerSession.updateCursor`）,不再於每次滑鼠移動時去讀 `view.currentCursor`——因為形狀是**遠端**決定何時變的（滑過文字框、縮放視窗）,那跟這邊滑鼠動的時機根本不是同一回事。**② Esc Esc 失效**（使用者回報）：擷取期間指標也被抓住、選單列碰不到,所以那是唯一的出路,**一個依賴其他狀態正確才成立的出路不算出路**。三處補強：①Escape 移到 `handleKey` 最前面,**不再先問 first responder 是誰**;②視窗 0.5s→**0.75s**（兩次刻意的敲鍵比雙擊慢,原本的窗口太緊）;③新增**長按 Escape 1 秒**也放開（靠 auto-repeat 判定,3 個新測試））
（**回到 1.71 的移動模型,改修那顆畫錯的游標**——使用者實測 1.73：「還是不可控。**第一版最準確,只是是文字輸入符號**」。結論很清楚：**每次移動都 warp 就是手感的元兇**（1.72 引入、1.73 只是把抑制區間關掉,治標）。所以移動回到不 warp 的版本：游標與硬體脫鉤、隱藏、只有畫上去的那顆會動;真游標整段期間**完全不動**,只在解除擷取時 warp 一次（那一次仍需要抑制區間=0）。**I 字形的成因假設**：`NSImageView` 之前設 `.scaleNone`,而 Retina 游標的**像素數大於 points**——`image.size` 是「該畫多大」,不是點陣大小;不縮放就等於把 2x 點陣塞進 1x 的 frame,只有左上角一小條進得去,看起來就是一條直線。系統自己畫 NSCursor 會正確處理,所以未鎖定時是好的。改成 `.scaleProportionallyUpOrDown`。**已由使用者實測證實**：1.74 之後畫出來的是正確的箭頭——也就是說 1.71 看到的「I 字形」根本就是**被裁掉的箭頭**。**後續確認的既有行為（非回歸）**：游標形狀不會跟著遠端變（移到文字框不變 I 字形）——**未擷取時也一樣**,所以那是 RoyalVNC／伺服器端本來就有的行為（`VNCCursor.nsCursor` 在 `isEmpty` 或 `cgImage` 解不出來時一律退回 `.arrow`,見 `VNCCursor+NSCursor.swift:12-18`）,擷取模式只是忠實重現它。要讓形狀跟著變得另外查解碼那條路,屬獨立議題）
（使用者兩個回饋：①**「移動有時跳很快、沒有之前好控制」**——`CGWarpMouseCursorPosition` 會啟動**本機事件抑制區間**（預設 0.25 秒,存在的理由是不讓 warp 跟手打架）,那段期間 macOS 把滑鼠移動**丟掉**;因為 1.72 每個事件都 warp,等於一直活在抑制期裡 → 停頓後一次補上,就是「跳」。修法：`CGEventSource.localEventsSuppressionInterval = 0`。再加一道保險：**單一事件位移超過遠端螢幕一半就丟棄**（`RelativePointer.move`,3 個新測試）——沒有任何手部動作能在兩次滑鼠回報之間跨越半個螢幕,會產生那種數字的只有「游標在我們底下被搬走」,放一個進去指標就飛到對面。②**「MBA 有其他 App 彈出就把 active window 帶走」**——失焦解除擷取是必要的安全設計（不能讓 grab 跟著使用者到別的 App）,但代價是處理完彈窗要重新點一次。改成**暫停而非解除**：記住那個 pane,回到 MacMoba 且它仍在最前面時**自動恢復擷取**;使用者自己按 Esc Esc 解除的則清掉記憶、不會自己回來）
（**自己畫遠端游標是錯的路,整層拿掉**——使用者實測 1.71：點進去後游標變成 **I 字形**,**連在遠端桌布上也是**（這一問把「遠端當下真的是文字游標」的可能性排除掉了）,但位置與移動都正確。查不出 `view.currentCursor` 為何是 I-beam,而**與其繼續猜哪一層抓錯圖,不如讓這層不存在**：游標仍與硬體脫鉤（移動量照樣是相對的),但**不隱藏**它,改成每次移動把真游標 `CGWarpMouseCursorPosition` 到追蹤位置。脫鉤狀態下 warp **不產生硬體移動量**,所以不會回授進 delta;而畫出來的就是 RoyalVNC 原本那顆游標——**與未鎖定時看到的必然是同一顆**,因為根本是同一個東西。刪掉 `RemoteCursorView` 與 hotSpot／Retina 尺寸換算那些沒有把握的座標數學。**教訓**：功能對了但畫面錯,先問「這層能不能不要存在」,再去 debug 它）
（**滑鼠改成真·相對模式**（使用者要求）。原本的「撞邊界推回去」只擋住游標逃走,遠端游標仍會**卡在視窗邊緣**。現在 `CGAssociateMouseAndMouseCursorPosition(0)` 把本機游標與硬體脫鉤——游標停著不動、滑鼠照樣回報移動量——移動量除以 `scaleRatio` 換算成遠端像素,驅動一顆活在**遠端螢幕座標**裡的指標（`RelativePointer`,6 測試）。**位置不逐次取整**:縮放後的桌面每個事件只有零點幾個像素,每次都四捨五入會把慢速移動整個丟掉（有測試守著）。**必須自己畫遠端游標**:VNC 上看到的游標其實是**本機 NSCursor**——RoyalVNC 把 cursor pseudo-encoding 寫死在 `VNCConnection.swift:110`,不可設定,所以伺服器不會把游標畫進 framebuffer;隱藏本機游標後遠端就沒游標可看,因此用 `currentCursor.image` + `hotSpot` 疊一個 `NSImageView`（`hitTest` 回 nil,否則它就在指標底下、會吃掉每一次點擊）。點擊/滾輪也改由我們送（`mouseButtonDown/Up`、`mouseWheel`）——游標既已凍結,函式庫再也讀不到正確位置。**踩到的坑**:游標脫鉤後 tracking area 不再產生 mouseMoved,必須 `window.acceptsMouseMovedEvents = true`,否則指標整個凍住。解除擷取時把真游標 warp 到遠端游標所在位置,不會瞬移回原點。座標轉換每次都要翻一次 y:`contentRect` 用左上原點（RoyalVNC 對點擊的映射就是這樣算的）,NSView 自己是左下原點）
（**修 1.69 的「打一個 a 出兩個 a」**——使用者實機一秒抓到。是我 1.69 重構時寫的一行：`self?.handle(event) ?? event`。`handle()` 回傳 `nil` 的語意是「已送給遠端,吞掉這個事件」,但 optional chaining 會把「self 已釋放」與「已處理」壓成同一個 `nil`,`?? event` 於是把我們剛送出去的鍵**又放行回責任鏈**,RoyalVNC 的 view 再送一次。改成 `guard let self else { return event }` 兩段式解包。1.68 沒有這個問題（當時是 static 函式、沒有 weak self）——**是重構引入的回歸,不是原始設計的缺陷**）
（**輸入擷取（VMware/Parallels 式 grab）**——承上：使用者在 MBA 用 🌐 切輸入法,到了遠端就沒用。**fn/🌐 這條路是死的**:macOS 把它攔在系統層、App 收不到那個事件,而遠端 Mac 的 🌐 綁的是它自己的實體鍵盤,VNC 協定也沒有對應 keysym。所以改成擷取輸入:**點進 VNC 畫面即鎖定**（使用者選 VMware 行為），鎖定期間 ⌃Space／⌘Tab／Spotlight 等本機快捷鍵改送遠端——**這就順帶解決了切遠端輸入法**。**解鎖用連按兩下 Esc**（使用者拍板）:關鍵設計是**每一下 Esc 都照常送給遠端**、第二下才額外解鎖,所以 vim／取消組字／退出全螢幕不受影響（代價:解鎖時遠端會收到兩個 Esc,無害）。反過來把第一下 Esc 壓住等 500ms 觀望,會讓每一個 Esc 都變慢——不採用。`DoubleEscapeRelease` 純狀態機 6 測試（含「連按一串只解鎖一次,不會來回切」「慢按一下再快按一下仍算數」）。**滑鼠鎖定用邊界推回**（`PointerClamp` 4 測試,`maxX/maxY` 在矩形外所以要停在前一格,否則每次移動都會重複 warp）:真·相對模式要隱藏本機游標,但**遠端游標正是本機 NSCursor**（RoyalVNC 的 `didUpdateCursor`）,隱藏它遠端就沒有游標可看,得自己畫一顆——先不做。**抑制本機系統快捷鍵需要輔助使用權限**（唯一途徑是 `PushSymbolicHotKeyMode(kHIHotKeyModeAllDisabled)`）:第一次鎖定時詢問**一次**就不再問——沒授權時擷取仍然有效（游標照樣被釘住、本機輸入法照樣不插手），只是 ⌃Space 到不了遠端。安全設計:失去 key window／App 失焦一律自動解鎖（否則 grab 會跟著你到別的 App,鍵盤看起來像壞掉）；Session 選單可整個關掉擷取。**實機待驗**）
（**本機輸入法決定了遠端收到什麼鍵**——使用者實機回報：MBA 用「速成」輸入法連 Mac mini 的 Screen Sharing，Mac mini 上的 OpenVanilla 速成就組不出字；MBA 切回 ABC 就正常。**根因在 RoyalVNC**：`VNCCAFramebufferView.swift:518` 用 `event.charactersIgnoringModifiers` 查 keysym，而那個值是**經由目前輸入源解析**的——選了倉頡系輸入法，同一顆鍵回報的就不再是 `a`。查不到對照就整顆丟掉（log「Ignoring unconvertable key press」）；就算查得到，非 ASCII 字元走的是 `VNCKeyCode.swift:165` 把 Unicode 值**直接當 keysym 送**（X11 的 Unicode keysym 要加 `0x01000000` 前綴，所以那是垃圾）。兩條路都讓遠端的輸入法收不到能組字的按鍵。**修法（就是 Screen Sharing 的做法）**：遠端桌面要的是**實體鍵**，由遠端自己的輸入法組字。新增 `ASCIIKeyboard.character(forKeyCode:shift:capsLock:)`——經 `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` + `UCKeyTranslate` 翻譯，**完全不看目前輸入源**（實測：輸入源是 OpenVanilla 時仍回 `a`/`A`、`1`/`!`）；`RemoteKeyPolicy.sendsPhysicalKey` 決定接管範圍（純邏輯可測）：只接管無 ⌘/⌃/⌥/function 的可列印 ASCII，其餘（方向鍵、F 鍵、Return、Esc）留給 RoyalVNC 既有的 **keycode** 對照表——那條路本來就與輸入源無關。攔截點用 local event monitor（`VNCKeyboardBridge`）：它在事件送進視窗**之前**執行，所以同時杜絕本機輸入法在一個它根本打不進去的畫面上開組字視窗。9 個新測試（含「合成字元一律拒送」與「⌘ 組合不接管，否則會吃掉自家選單快捷鍵」）。**實機待驗**）
（**兩個「畫面沒更新」的算繪缺陷**。①**Overview 對 VNC／RDP 的縮圖是空白的**（使用者問「screen sharing 會有縮圖嗎」時查出來的）：遠端桌面每一幀是直接指定 `layer.contents`（RoyalVNC `VNCCAFramebufferView.swift:540`、`RDPTab.swift:953`），**沒有 `draw(_:)`**，而 `cacheDisplay` 只會重播 `draw(_:)`——所以縮圖只有終端機分頁有。修法：VNC/RDP 走新的 `framebufferImage(in:)`，往下走 layer 樹取出那張 CGImage（`CFGetTypeID` 判型，因為 `as? CGImage` 對 CF 型別永遠成立），終端機維持原路徑。**Web 分頁待驗**：WKWebView 跨行程 layer-hosted，正解是非同步 `takeSnapshot`。②**換主題後殘留舊畫面**（使用者截圖：舊版面的文字碎片留在原位）：SwiftTerm 的 macOS 繪製路徑把 dirty rect **清成透明**、只填有明確背景色的儲存格，預設背景的儲存格靠 **`layer.backgroundColor` 透出來**（`AppleTerminalView.swift:1298` 註解）——而 `nativeBackgroundColor` 的 setter 不碰 layer，只有 `setupOptions()` 會。修法：`apply(to:)` 補上 layer 背景、把 `installColors`（它才會清屬性快取）移到最後、並整片 `setNeedsDisplay`。**誠實記錄**：殘影是否完全根治未經確認——使用者當下 skip 了，碎片位置對應的是「檔案面板還開著時」的舊版面，也可能另有版面變動未觸發重繪的成因）
（使用者兩個回饋:①**儀表板沒有關閉鈕**——點了資料夾就回不去空白檢閱器,補上 ✕。②**「跳板後看不出通還是不通」**——⑂ 只說明「不歸這台 Mac 測」,但使用者要知道的是「它活著嗎」。所以改成 **⑂ + 燈號**（灰=尚未檢查、綠/紅=上次經跳板檢查的結果），並在儀表板加 **Check via Jump Host** 按鈕。**為何按需而非輪詢**:每次跳板檢測是一次完整 SSH 登入,背景每 15 秒對 5 台做等於狂打跳板認證（該環境還有 PSM，更可能觸發鎖定），所以按鈕觸發、**逐台循序**執行。共用邏輯 `AppState.probeViaJumpChain`（開 `RemoteDesktopRoute` 成功即為可達證明），Inspector 的 Check 與儀表板按鈕走同一支）
（承 1.64：使用者回報修好後儀表板顯示「0 up · 0 down」——五台全在跳板後時,兩個零讀起來像「測不到」而不是「不歸我測」。改成只在有可直接探測的成員時才顯示 up/down,並加上「n via jump host」統計）
（**修一個會誤導人的錯誤紅燈**——使用者截圖顯示資料夾儀表板把 5 台 VM 全報「down」,但那些機器連得好好的。原因:健康監測用 `ReachabilityProbe` **從這台 Mac 直連** `10.x`,完全沒看 session 的 `proxyJump`——而那些 VM 只在跳板的網段上定址,從這裡當然打不通。**一個錯的紅燈比沒有燈更糟**:它跟真的停機長得一模一樣。修法:①`SessionConfig.isDirectlyProbeable` 純邏輯（有跳板就不可直接探測,3 測試）②背景輪詢**跳過**跳板 session,側邊欄與儀表板改顯示分支圖示 + tooltip「Reached through a jump host — not polled from this Mac」③Inspector 的 **Check 鈕改成真的走跳板鏈**（`RemoteDesktopRoute.open` 成功即證明可達）——手動觸發才付得起一次 SSH 登入的成本,這正是背景輪詢不做、而按鈕做的分工）
（**Auto 主題:使用者實機驗收通過（2026-08-19）**——系統切換淺／深色時終端即時跟著換、scrollback 完整保留;固定主題不受影響。 **放棄 macOS 13、底線升到 14**，換到 `onKeyPress` 得以完成兩件事：**①側邊欄 type-select**（在側邊欄打字直接跳到連線，Finder 文法）——`TypeSelect` 純邏輯 10 測試：快速連打組成前綴、**停頓 1 秒後重新開始**（否則一分鐘後打的字會接續舊前綴而配不到東西）、**單鍵重複則循環**走訪所有同開頭的項目（Finder 行為）、大小寫不分；只吃無修飾鍵的可見字元，⌘/⌃/⌥ 組合與方向鍵、空白鍵行為不受影響。**②健康監測的可發現性**：使用者回報「工具列沒看到 ❤️」——8 顆工具列圖示在窄視窗會被收進 `»`，而且圖示本身無法「查找」。`HealthMonitor` 從每視窗一份改由 `AppState` 持有（它本來就是掃 vault 的主機，與視窗無關），**View 選單加入「Health Monitoring」開關**；群組儀表板在監測關閉時不再一片空白，改顯示「Health monitoring is off」+ 就地開啟按鈕——這正是我自己在 UX 計劃裡寫的原則「什麼都不做時要說明原因」先前沒做到的地方） · **已公開發佈：https://github.com/tchitim/macmoba**
（**`./make-app.sh --release` 一行出版**：建置 → 簽名 → 公證 → staple → 產 DMG → 用 keychain 裡的 EdDSA 私鑰簽 appcast → 開 GitHub release 上傳 → **最後自己 curl feed URL 確認新版真的被提供**（appcast 沒上去的 release 是無聲失效，所以用查的不用猜）。守門：working tree 不乾淨拒跑（tag 必須對得上程式碼）、tag 已存在拒跑。`.release/` 保留最近兩版 DMG，Sparkle 據此自動產生 delta（實測 1.60→1.61 只要 18KB，不必重抓 12MB）。**端到端實測**：把 1.60 裝到隔離位置執行 → App 自動跳出 Software Update → 安裝後 bundle 變 1.61 且 process 換新 PID（真的重啟）。**踩到的坑**：zsh 的 glob 在無相符檔案時會中止腳本（bash 不會），要用 `(N)` null-glob；Sparkle 重啟 App 時**不繼承環境變數**，隔離測試的 instance 重啟後會改用正式資料目錄）
（**開源 + Sparkle 自動更新**（對齊 cmux 的做法——實地查證 cmux 用的就是 Sparkle：`SUFeedURL` 指向 GitHub Releases 的 appcast.xml、`SUPublicEDKey` 驗簽、每日檢查）。**公開前消毒**：內網 IP／主機名／`op://` vault 項目名／AD 主機 CN 全部代換成 RFC 5737 TEST-NET 與 example.* 範例值（7 個檔案、80+ 處），測試假密碼也換掉（原值是使用者真實密碼的前綴）;`.gitignore` 排除 414MB DMG、1.6GB .build、可由 `scripts/build-freerdp.sh` 重現的 14MB FreeRDP 產物 → 實際入庫 228 檔 / 2.3MB。**Sparkle 整合**：framework 內含 XPC services 與 Updater.app,`make-app.sh` 由內而外逐一簽名（否則 `--verify --strict` 與公證會拒收）;EdDSA 私鑰存 login keychain **永不進 repo**;`SUAutomaticallyUpdate=false`——更新會在有 SSH 連線進行中抽換 App,一律先問。文件：README + `docs/getting-started.md`（照 cmux getting-started 的結構寫,zh-TW））
（**一次信任整批新主機**：開一個資料夾的十台機器＝十次 host key 詢問（每台 key 本來就不同,協定上正確,但實務上沒人真的逐台比對指紋——同一個 TOFU 決定按十次）。首次連線的對話框加勾選框「**Also trust other new hosts for the next 2 minutes**」,勾了之後同一批的**首次**金鑰自動信任並照常釘選。**安全界線寫進純邏輯並測到底**（`TrustBurstPolicy`,6 測試）：**金鑰「變更」的主機永遠不受 burst 影響、一律單獨詢問**——那正是 MITM 訊號,`allowsAutoTrust(isChangedKey:)` 從建構上拒絕;窗口過期即失效、可提前關閉、只有「首次金鑰且使用者按了信任」才會開啟。信任結果照樣進 known_hosts,Tools → Trusted Hosts… 可稽核）
（**資料夾成為真實物件 + New Subfolder 選單**：v1.51 的巢狀資料夾是「從 session 的 group 路徑推導」的,所以**空資料夾不存在**——`New Subfolder…` 建完會立刻消失,這是不做 schema 就無解的。因此 `VaultData` 新增 `folders: [String]`（optional decode,舊 vault／匯出檔照樣開,已補 2 個相容測試）。UI：資料夾右鍵 **New Subfolder…**、Sessions 標頭 + 選單 **New Folder…**（頂層）,建完自動展開祖先鏈並選中新資料夾。`GroupTree.displayRows(groups:folders:)` 合併「推導的」與「明確建立的」資料夾（同名不重複）;`GroupTree.childPath` 處理命名（trim、拒空、**名稱裡的 `/` 換成空白**,否則會靜默多開一層）。`renameGroup` 連 folders 一起搬子樹;`disbandGroup` 改為連**子資料夾與子樹 session**一起解散,並清掉該子樹的 groupCredentials（否則同名資料夾重建時會沿用到舊憑證）。7 個新 GroupTree 測試 + 2 個 vault 相容測試）
（**修 1.56 實機 crash**：使用者按 macOS 原生視窗分頁列的「+」→ App 秒退。crash report 指得很明確:`NSTabBarNewTabButton mouseDown:` → `_makeNewWindowInTab` → SwiftUI 建新視窗 → `ToolbarBridge.preferencesDidChange` → **`NSToolbar _insertNewItemWithItemIdentifier:…propertyListRepresentation:` 拋 NSException**——那是「還原可自訂工具列存檔設定」的專用路徑,即 v1.46 (P2-8) 加的 `.toolbar(id: "main")`（defaults 裡確實存著 `NSToolbar Configuration main`）。**兩處一起修**：①`NSWindow.allowsAutomaticWindowTabbing = false`——MacMoba 本來就有自己的分頁列,原生視窗分頁是疊在上面的第二排無關分頁,而且正是 crash 入口;②**P2-8 可自訂工具列還原成一般 `.toolbar`**（8 個 item id 移除）,把易碎的 propertyList 路徑整個移出 App。**驗證（AX 選單為 ground truth）**：修復前 Window 選單有 `[Show Previous Tab][Show Next Tab][Move Tab to New Window][Merge All Windows]`,修復後**四項全消失**→「+」按鈕不可能出現→crash 路徑不可達;⌘N 改為開出**真正的第二個視窗**（修復前它建的是分頁,回報只有 1 個視窗——正好反證 crash 成因）。**誠實記錄**：P2-8「可自訂工具列」是我自己在打磨批次加的、非使用者要求,既然它會炸就撤掉;要恢復需改走 AppKit NSToolbarDelegate,不能用 SwiftUI 的橋接）
（cmux agent hooks 對齊：**`macmoba hooks install claude`** 自動把 Notification+Stop hook 併入 `~/.claude/settings.json`（絕對路徑指令、時間戳備份、冪等、uninstall 只移除自己的條目、外來設定與使用者既有 hook 原樣保留——5 個 CLI 子程序測試逐項驗檔案內容）；codex 印 TOML 片段不代改。**`agent-event`** 指令：hook 的 stdin JSON 自動抽 message、`MACMOBA_TAB`（本機終端已注入,連同 `MACMOBA_CLI`）定位分頁 → 本機分頁 attention 藍點 + app 背景時系統通知（點擊跳分頁）、前景時 banner。**邊界**：遠端 agent 的 hook 摸不到本機 socket——BEL 偵測（v1.52）已覆蓋,要精準語意可在遠端 hook 裡 `ssh 回來呼叫 macmoba`。**本輪抓到的險 bug**：`homeDirectoryForCurrentUser` **無視 $HOME 環境變數**,測試手動重現時把 hooks 寫進了開發者真實的 settings.json（立即 uninstall 復原、原始備份保留）——CLI 已改為 $HOME 優先,測試隔離自此成立）
（cmux browser-surface 對齊：CLI 加 **`open-url <url> [--via <ssh-session名>]`**——agent 可開任意網頁分頁，`--via` 指定走哪個 SSH session 的 SOCKS 隧道（看內網頁,cmux 沒有的能力）；裸網域自動補 https；vault 未解鎖/跳板不存在都明確報錯。**E2E 實證**（隔離 app + AX 解鎖 + CLI）：open-url 兩個 URL → `list-tabs` ground truth 回兩個 `"kind":"web"` 分頁、壞 --via exit 1）
（cmux 對齊②（三項全部完成；**send／read-screen 對真分頁已於 2026-08-19 由使用者實機驗收通過**）：**`macmoba` CLI + 控制 socket**——app 聽 `~/Library/Application Support/MacMoba/control.sock`（0600 + 每次啟動換發 0600 token，壞 token 拒收），行分隔 JSON。指令：`ping`/`list-tabs`（index/title/kind/state/attention）/`open <session名>`/`send --tab <n|標題> <text>`（`\n`=Return）/`read-screen --tab … [--lines N]`/`set-status`（顯示在 pane 狀態列）/`notify`（banner）。CLI 零依賴（純 Darwin socket，134KB），bundle 在 `Contents/Resources/bin/macmoba`（已簽名；建議 alias）。**驗證**：Core ControlServer 7 測試（真 socket：round-trip/壞 token/malformed/同連線多請求/stop 清 socket）+ **CLI↔隔離 app 實跑 E2E**（ping 回版本、list-tabs、notify、壞 token exit 1、權限皆 0600）。`send`/`read-screen` 驗到路由層（底層 write/dumpScrollback 為既有已測路徑），對真 tab 的 live 驗證待使用者實機。**抓到兩個真 bug**：product 名 `macmoba` 與 `MacMoba` 在**不分大小寫的 APFS 上互相覆蓋** .build 產物（app binary 被 CLI 蓋掉！）→ product 改名 `macmoba-cli`、bundle 時再改回；AF_UNIX socket 路徑 104 字元上限（CLI 與 server 都會撞）→ CLI 明確報錯，正式路徑 ~60 字元安全）
（cmux 對齊③：**圖片貼上→遠端**——SSH/Mosh pane 按 ⌘V 且剪貼簿是「純圖片」（截圖；有文字時文字優先）→ PNG 經該 session 自己的 SFTP 通道（同憑證同跳板鏈）上傳到遠端 `~/.macmoba/paste-<ts>.png` → **路徑打進 prompt**（不送 Return，使用者繼續對 agent 組句）。`RemotePasteUpload`（Core）+ 2 個 ground-truth 整合測試：**對真 SFTP server 上傳 4KB 二進位 payload，讀回磁碟 byte-for-byte 一致**、EEXIST 目錄不擋路。狀態列顯示上傳進度/結果。TIFF→PNG 自動轉（NSBitmapImageRep）。調試插曲：cmux 注入的 NODE_OPTIONS 指向已消失暫存檔害 test server 起不來——test 腳本現用 `NODE_OPTIONS=` 清空啟動）
（cmux 對齊①：**pane 注意力通知**——`AttentionDetector` 純狀態機（11 測試）偵測 **BEL**（Claude Code 完成/提問會響鈴）與**靜默 ≥30s 後恢復輸出**；關鍵細節：OSC/DCS 字串序列以 BEL 結尾（改視窗標題就是），內建最小 escape 解析器把「終結符 BEL」和「真鈴聲」分開，且狀態跨 chunk 保持。正在被凝視的 pane（app active + key window + firstResponder）不標記；觸發 → 分頁 chip 藍點；app 背景時發 macOS 通知（UserNotifications，點擊啟動 app 並跳到該 pane）；聚焦 pane 即清除；**⌥⌘U** Jump to Attention 循環跳下一個待處理分頁（Session 選單）。**使用者實機驗收通過（2026-08-20）**：通知權限、點通知跳轉、⌥⌘U 循環皆正常）
（v1.51：**巢狀 group 資料夾**（Royal TSX 樹狀）——`Production/Linux` 斜線路徑慣例：資料模型零改動（group 仍是一個字串，舊 vault 直接相容，RDCMan 匯入本來就產這種路徑）。`GroupTree` 純函式（rows/ancestors/contains/rename，8 測試）：側邊欄樹狀縮排、隱含父資料夾、收合藏子樹、計數含子孫；**憑證繼承沿路徑往上找**（`Production/Linux` 沒設就用 `Production` 的，最近者勝，+3 測試）；rename 帶子樹搬遷（含 groupCredentials 鍵遷移）；Connect All／資料夾儀表板含整個子樹；搜尋時自動展開並顯示祖先鏈。已知限制：空資料夾不存在——資料夾由成員 session 的路徑推導，要新資料夾就把 session 的 Group 設成新路徑）
（**op:// 1Password 整合已由使用者在真實環境端到端驗收**：credential op:// 參照 → 1Password 授權 → RHEL9 Jumphost 多跳 → web-server 登入成功。調試過程修掉兩個真問題並各自出貨：**v1.49** SecretResolver 60s timeout + stdin null（op 等授權/輸入時從「無限卡住」變明確錯誤）；**v1.50** SecretReference 引號容錯——從 shell 範例複製參照必帶引號（實測使用者就存成 `"op://…"` 整串當字面密碼送去 SSH），parse 現在剝除外層成對引號（含 macOS 彎引號）後再判定，非參照的字面密碼原封不動。+6 測試）
（v1.48：密碼欄「眼睛」顯示鈕——session/credential 編輯器 5 個已存密碼欄可切換明文檢視，順帶能核對 op:// 參照貼對了沒；輸入新密碼的欄位（vault 主密碼、金鑰 passphrase）維持純隱藏。UX 改造 P0–P2 見 v1.44–1.47）

---

## 目前狀態一句話

功能面已達成 MobaXterm 核心對應功能，全部用實機 UI 驅動測過；
App 已 **Developer ID 簽名 + Apple 公證 + staple 票據**，
`MacMoba-0.4.dmg` 可直接散佈到任何 Mac，不跳警告。

**`MacMoba-0.5.dmg` 已簽名 + 公證 + staple（app 與 DMG 都有票據）**，
內含 0.4 之後的全部新功能：複製貼上強化、Macros、多視窗、VNC、RDP。
RDP 已對真的 Windows AD server 驗證過（連線／畫面／滑鼠／鍵盤全通）。

⚠️ **只有 arm64**：FreeRDP 靜態庫是照本機架構編的，Intel Mac 跑不動。
要支援 Intel 得做 universal build（連 OpenSSL 也要 x86_64 版）。

---

## 建置 / 簽名

| 項目 | 狀態 |
|---|---|
| `./make-app.sh` | ✅ 自動用 Developer ID 簽名（hardened runtime + timestamp） |
| 簽名身分 | `Developer ID Application: Chi Tim Hsieh (VSNKF3DX58)`，2031/08/07 到期 |
| 憑證鏈 | ✅ Developer ID → Developer ID CA → Apple Root CA |
| `./make-app.sh --dmg` | ✅ 產出 `MacMoba-0.5.dmg`（8.6MB，含 /Applications 捷徑，已簽名、掛載驗證過） |
| `./make-app.sh --adhoc` | ✅ 強制 ad-hoc（開發用） |
| `./make-app.sh --notarize` | ✅ 已跑過並通過。**現在會先公證並 staple app，再打包 DMG，最後公證 DMG**——這樣拖出來的 app 自己帶票據，離線也不會被擋（之前只 staple DMG，拖出來的 app 得靠連線檢查） |
| Gatekeeper | ✅ `accepted — Notarized Developer ID`（app 與 DMG 皆已 staple 票據） |

### 待辦

無。憑證、簽名、DMG、公證、staple、私鑰 .p12 備份全部完成。
以後改版只要 `./make-app.sh --notarize` 一行。

---

## 功能驗證狀態

「實測」＝用滑鼠/鍵盤真的操作 UI，並用檔案系統或 network 驗證結果，不是只看截圖。

| 功能 | 狀態 |
|---|---|
| Vault 建立 / 解鎖 / 鎖定 | ✅ 實測 |
| 本機終端分頁（⌘T） | ⚠️ 已實作，UI 未實測（視窗焦點問題中止） |
| Quick Connect（⌘K，user@host:port 不存檔直連） | ⚠️ 已實作，UI 未實測 |
| 匯入 ~/.ssh/config | ⚠️ UI 未實測；解析器有 4 項單元測試（含萬用字元、`=` 分隔、去重、預設 user） |
| Touch ID 解鎖 | ⚠️ 程式碼完成（正式簽名走 keychain biometry ACL），未實測（需生物辨識） |
| Session 建立 / 編輯 / 連線 | ✅ 實測 |
| Session 分組（拖放 / 選單 / Connect All） | ✅ 實測 |
| 終端分頁、resize、TCP keepalive | ✅ 實測 |
| 斷線重連（Return 或按鈕） | ✅ 實測 |
| 分割畫面（⌘D / ⇧⌘D / ⌥⌘W、50/50 重排） | ✅ 實測 |
| MultiExec 廣播 | ✅ 實測（一次輸入兩個 pane 同時出現） |
| 搜尋 scrollback（⌘F / ⌘G） | ✅ 實測（命中數、清單、上下筆） |
| 字體大小 ⌘+/⌘-/⌘0 | ✅ 實測（⌘+ 放大、⌘0 復原，截圖比對） |
| Host key 首次信任 / pin / mismatch 拒絕 | ✅ 實測 + 單元測試 |
| SFTP 瀏覽 / 上傳 / 下載 / 改名 / 刪除 | ✅ 實測 |
| SFTP 拖放（三方向） | ✅ 實測（見下方 NSTableView 說明） |
| SFTP Edit Locally 自動回傳 | ✅ 實測（改本機檔 → 遠端跟著變） |
| Tunnel -L | ✅ 實測（localhost:18080 拿到與直連相同的 SSH banner） |
| 終端配色主題（6 種） | ⚠️ 已實作，UI 未實測（選單/設定都可切） |
| 設定視窗 ⌘, （主題／字級／log 路徑） | ⚠️ 主題與字級 UI 未實測；copy/paste 與 macro 確認四個開關已實測 |
| 本機終端分頁 ⌘T | ⚠️ 已實作，UI 未實測 |
| Quick Connect ⌘K | ⚠️ 已實作，UI 未實測 |
| 匯入 ~/.ssh/config | ⚠️ UI 未實測；解析器 4 項單元測試 |
| 終端通知（bell） | ⚠️ 已實作，UI 未實測（背景才發、5 秒節流） |
| SOCKS5 (-D) | ✅ 整合測試（真握手 + domain CONNECT + echo 往返） |
| Session logging（⇧⌘L） | ✅ 實測（scrollback + live 都進 log，使用者確認）；escape 過濾另有 6 項單元測試 |
| Dynamic forwarding -D（SOCKS5） | ✅ 整合測試（真 SOCKS5 握手 + domain CONNECT + echo 往返） |
| ProxyJump 跳板機 | ✅ 整合測試（透過 bastion 開第二段 SSH，互動 echo 驗證） |
| Tunnel -R | ✅ 實測（UI 開關啟動後，連 server:28080 拿到 SSH banner；關掉後 port 關閉） |
| 傳輸狀態面板（速度/取消） | ✅ 實測（40MB 下載顯示 Done · 41.9 MB、Clear 可清；內容 byte-identical。取消另有單元測試） |
| 選取即複製 | ✅ 實測（SSH pane 與本機終端都測；拖曳放開後 `pbpaste` 拿到選取內容；開關關掉後 `pbpaste` 不變，但 ⌘C 仍可複製＝證明選取真的存在） |
| 右鍵／中鍵貼上 | ✅ 實測（本機終端右鍵貼上後按 Enter，`/tmp` 檔案內容為證；中鍵同樣；SSH pane 由測試 server echo 回來為證） |
| 貼上右鍵選單（開關關掉時） | ✅ 實測（Copy/Paste/Paste as One Line/Select All，點 Paste as One Line 後檔案內容確認併行成功） |
| 多行／控制字元貼上確認 | ✅ 實測（3 行跳確認、Paste 三行都執行、Paste as One Line 併成一行、Cancel 什麼都沒送出；含 ESC 的剪貼簿也會攔，預覽把 ESC 顯示成 `␣`）；判定邏輯另有 10 項單元測試 |
| ⇧⌘V 併成一行貼上 | ✅ 實測（不跳確認，直接併行貼上） |
| 設定的三個 copy/paste 開關 | ✅ 實測（切換即生效，重開 app 後仍記得） |
| Macros 建立 / 編輯 / 排序 | ✅ 實測（sidebar + 建立、右鍵 Move Up 換位後 ⌃⌘n 跟著重新編號、Move Down 在最後一列正確 disabled） |
| Macros 執行（雙擊 / ⌃⌘n / Macros 選單） | ✅ 實測（本機終端 `/tmp` 檔案為證；SSH pane 由測試 server echo 回來為證） |
| Macros 多行 | ✅ 實測（編輯器裡 Return 是換行不是存檔；兩行各自執行，檔案內容 A\nB） |
| Macros 不按 Enter（sendReturn off） | ✅ 實測（指令停在 prompt 上沒執行，圖示也不同） |
| Macros 存進加密 vault | ✅ 實測（重開 app 後三個 macro 與順序都還在；`grep` vault.json 找不到明文指令） |
| Macros 錯誤守門 | ✅ 實測（沒開分頁→「Open a terminal tab first」；連線失敗的 pane→「needs a connected terminal」，不會誤觸 Return 重連） |
| Macros 跟 MultiExec 一起用 | ✅ 實測（兩條真連線並排：廣播關→只有聚焦 pane 收到；廣播開→兩個 pane 都收到） |
| Macros 廣播確認視窗 | ✅ 實測（列出兩台 host＋指令預覽；Cancel 什麼都沒送、Run 兩邊都跑；sendReturn 關掉時改成「Type … into 2 sessions」且按鈕不是紅的；廣播關或只有一條連線時不跳） |
| 「Don't ask again」與設定開關 | ✅ 實測（勾了之後下一次直接執行，設定裡的 toggle 也變成 off；再打開確認視窗就回來了） |
| 多視窗（⌘N） | ✅ 實測（第二個視窗共用 vault／sessions／macros，但分頁各自獨立；⌘T 只加到聚焦的那個視窗） |
| 多視窗 × MultiExec | ✅ 實測（在視窗 B 打字，視窗 A 的另一條連線也收到——測試 server echo 為證） |
| 關視窗會斷線 | ✅ 實測（`lsof` 連線數 2→1、本機 shell 1→0，另一個視窗的連線不受影響） |
| 鎖定 vault 跨視窗 | ✅ 實測（在其中一個視窗按 Lock，兩個視窗都回到解鎖畫面，連線數 2→0） |
| 側邊欄寬度上限 | ✅ 實測（拖到底會停在 300pt；開分頁後內容不再位移；⌘N 新視窗也正常） |
| VNC 內建分頁 | ✅ 實測（自製 RFB 3.8 測試 server 送四色象限，畫面顏色/方位完全相符；tab 標題顯示 320×240＝來自 ServerInit） |
| VNC 認證與協商 | ✅ 實測（server log 收到 VNCAuth 回應、SetPixelFormat bpp=32、SetEncodings 依我們的偏好順序 1,16,6,5,4,2,0） |
| VNC 滑鼠／鍵盤 | ✅ 實測（點紅色象限→server 收到 PointerEvent x=79 y=59；打大寫 Z→收到 Shift_L + 0x5a，含放開事件） |
| **VNC 走 SSH 通道** | ✅ 實測（`lsof` 顯示連到 VNC server 的是 **node ssh-server**，MacMoba 只連 2299——證明流量真的走 direct-tcpip，不是直連） |
| dylib 嵌入與簽名 | ✅ 實測（`Contents/Frameworks/libRoyalVNCKit.dylib`，rpath 正確，`codesign --verify --strict` 通過並列出 nested code） |
| RDP 內建分頁 | ✅ **對真的 Windows AD server 實測**（透過 MBA 的 `ssh -R` 反向通道到 192.0.2.70）：NLA/CredSSP 通過、桌面完整顯示（Active Directory Users and Computers、工作列、example.local 樹狀圖），分頁標題 832×814、狀態燈綠 |
| RDP 滑鼠 | ✅ 實測（點工作列的開始鈕→開始選單真的展開） |
| RDP 鍵盤 | ✅ 實測（在開始選單打字→Windows 搜尋框出現 "notepad"；Esc 也能關掉選單） |
| RDP 修飾鍵／快捷鍵 | ✅ 實測（⌃V、⌃A、⌃C 都會到 Windows；⌘ 對應到 Windows 鍵，⌘R 開得了「執行」對話框） |
| RDP 動態解析度 | ✅ 實測（視窗從 732×714 拉到 1132×864，Windows 真的重新排版——桌布露出來、工作列變長，不是拉伸縮放） |
| RDP 剪貼簿 Mac→Windows | ✅ 實測（Mac 複製 → 在「執行」對話框 ⌃V 貼出 `MACMOBA-PASTE-PROOF-4242`） |
| RDP 剪貼簿 Windows→Mac | ✅ 實測（Windows 端 ⌃A ⌃C → `pbpaste` 從 sentinel 變成 Windows 上的字，log 也記到 server offered 4 formats） |
| RDP 剪貼簿圖片 Mac→Windows | ✅ 實測（Mac 上放一張 200×120 洋紅 PNG → Windows 小畫家 ⌃V 貼出同一張圖） |
| RDP 剪貼簿圖片 Windows→Mac | ✅ 實測（小畫家 ⌃A ⌃C → Mac 剪貼簿從純文字變成 TIFF picture 567KB） |
| RDP 在「沒有 Homebrew」的環境 | ✅ 實測（`OPENSSL_MODULES=/nonexistent` 啟動，模擬乾淨的 Mac，NLA 照樣過、桌面照樣出來——證明不再依賴 OpenSSL 的 legacy provider） |
| 每種連線不同圖示 | ✅ 實測（側邊欄：SSH `terminal`／VNC `display`／RDP `macwindow.on.rectangle`，並各有顏色；分頁 chip 也帶圖示） |
| RDP 畫面改用 layer contents | ✅ 實測（改成 `layer.contents = CGImage` 之後畫面正常、輸入座標仍正確；連續 4 輪「複製檔案＋改視窗大小」沒有崩） |
| RDP 剪貼簿檔案 Windows→Mac | ✅ 實測（Explorer 複製 `api_cert.pem` → Mac 剪貼簿先出現 file promise，背景抓完換成真的 file URL；Finder ⌘V 貼出 1482 bytes 的檔案，內容是完整 PEM） |
| RDP 剪貼簿檔案 Mac→Windows | ✅ 實測（Mac 複製檔案 → log 記到 `files=1` → Windows Explorer ⌃V 貼出 `mac-origin`，33 bytes 與來源完全一致） |
| RDP 資料夾分享（drive redirection） | ✅ 實測（session 編輯器 Folders 加 `/tmp/MacShare` → Windows「本機」出現「重新導向的磁碟機」MacShare on TimodeMac-mini，看得到 Mac 上的檔案；再從 Windows 寫檔到 `\\tsclient\MacShare`，Mac 端 `cat` 得到 `written-by-windows`——雙向都通） |
| RDP 憑證確認 | ✅ 實測（真 server 的 CN `WIN-EXAMPLE.example.local` 與 SHA-256 指紋都正確顯示） |
| 開 .rdp 檔（CyberArk PSM） | ✅ **使用者實機連上了**（PSM 192.0.2.241，憑證 CN `psm-host.example.com`）：檔案解析、`server port`、token 放 username、`alternate shell` 路由、空密碼全部走通 |
| FTP / FTPS 分頁 | ✅ 實測（vsftpd 容器）：13 項 interop 測試（登入、錯密碼被拒、列目錄、二進位往返、上傳/下載、進度、mkdir/rename/遞迴刪除、連續 12 輪指令不失步），再用 UI 實際按「New Folder」→ **進容器 `ls` 確認資料夾真的在** |
| MultiExec 選擇性廣播 | ✅ 實測（伺服器端記錄每個 shell 收到的位元組）：關/開/排除一個/在被排除的裡面打字，四種情況的收件者都對 |
| 雙欄面板選取／右鍵選單 | ✅ 實測（合成點擊＋伺服器檔案系統對答案）：單擊 6/6、⇧-click 多選、**雙擊進資料夾**、右鍵改名與刪除都真的生效 |
| 雙欄同步（Sync →／←） | ⚠️ **邏輯已對真伺服器實測**（4 項：整棵樹複製後**第二次跑複製 0 個**、只傳改過的那一個、對面多出來的檔案不會被刪、反向從伺服器拉回來）；UI 按鈕同樣沒點過 |
| 雙欄傳輸（Transfer，⇧⌘T） | ⚠️ **邏輯已對真伺服器實測**（9 項 interop：上傳、下載、資料夾、二進位往返、Skip/Replace/Replace All/Skip All 各自對檔案內容的影響——伺服器那側是直接讀檔案系統對答案），**但 SwiftUI 面板本身沒點過**：那台 Mac 螢幕鎖著（`CGSSessionScreenIsLocked: 1`），視窗不在 accessibility tree 裡、合成的點擊也不會落下 |
| **Web 分頁（走 SSH jumphost）** | ✅ 實測（`.web` session 走 DynamicForward SOCKS5）：這台 Mac **連不到** `192.0.2.99`（curl 直連失敗），MacMoba 卻把頁面load 出來了，而 bastion 自己的 log 記到 `forward:192.0.2.99:8099`——證明流量真的穿過 SSH。另有反例對照：同一個網址不掛 jumphost 就永遠轉圈。網址列輸入（server 收到 `/typed-in-the-address-bar`）、關分頁後 SSH 連線歸零（不漏 tunnel）都驗過 |
| Web 分頁的「直連警告」 | ✅ 實測：macOS 對 **loopback 與本機同網段** 一律略過 proxy（用會記錄的 SOCKS proxy 量出來的：hostname 走 proxy、公網 IP 走 proxy、**離網段的 192.0.2.99 走 proxy**，但 127.0.0.1 與自己網段的 192.0.2.10 直連）。`matchDomains`／`allowFailover` 都改不掉。所以改成照實說：工具列變橘色 `not via bastion`，底下寫明「這頁沒有走 tunnel」，而不是掛著假的 via 標籤 |
| **Web 分頁：網頁自己的複製按鈕** | ✅ 實測（真實原因：`http://` 加 IP **不是 secure context**，所以 `navigator.clipboard` 根本是 undefined，Langfuse 那種「複製 API key」的按鈕按了完全沒反應、也不報錯。量過：loopback 反而算 secure，`192.168.x` 就不算）。做法是注入 bridge 把 `writeText` 接到 NSPasteboard。實測：剪貼簿從 sentinel 變成 `sk-lf-COPY-BRIDGE-PROOF-4242`，網頁自己的 promise 也 `resolved`（所以站方的「已複製」提示照樣會跑）。**只接寫入不接讀取**——不然任何網頁都能偷看 Mac 剪貼簿。另有 6 項自動測試（真的 WebKit 跑 JS），故意把 script 改壞會有 5 項失敗 |
| Web 分頁：手動選字 ⌘C | ✅ 實測（雙擊選到 `BRIDGE`，⌘C 之後 `pbpaste` 就是它）——這條路本來就沒壞 |
| **Web 分頁：重型 SPA 很慢的真正原因** | ✅ 量出來的：原本用 `nonPersistent()` 資料存放區＝**完全沒有快取**，每開一次分頁就把整包 JS 重新從 tunnel 拉一遍。實測（server 端記錄每個 request 的 If-None-Match）：非持久化 → 第二次仍然整包 6MB 重下；改成 **每個 session 各自的持久化 store**（`WKWebsiteDataStore(forIdentifier:)`，識別碼由 session id 推出來，見 `WebDataStoreID`）→ 第二次帶 `If-None-Match` 拿到 304。這正好解釋「Langfuse 正常、LangFlow 很慢」：後者的 bundle 大得多。副作用：cookie／登入狀態現在會留著（跟一般瀏覽器一樣），各 session 之間仍互相隔離 |
| Web 分頁：tunnel 本身的速度 | ✅ 對照 OpenSSH `ssh -D` 打同一台 server 量過：20MB bulk（加 30ms 延遲）我們 0.15s / OpenSSH 0.40s；60 個小檔並發 6 條，兩邊都 0.13s。**tunnel 不是瓶頸**——一開始我以為是，那是誤判 |
| 半關閉（EOF）沒有轉送 | ✅ 修掉（`GlueHandler.userInboundEventTriggered`）：兩端都開 `allowRemoteHalfClosure`，對方送 CHANNEL_EOF 時 NIO 只發 `inputClosed`、不發 `channelInactive`，舊碼把它吞掉，於是「用關閉連線來表示 body 結束」的回應永遠不會結束。用 `MM_EOF_ONLY=1` 讓測試 server 只送 EOF 不送 CLOSE 才驗得出來：舊碼卡滿 8 秒 timeout，新碼 21ms 過。另有一個不需要 server 的 EmbeddedChannel 單元測試 |
| **連 macOS 螢幕共享（Screen Sharing）** | ✅ 對這台 Mac 的 Screen Sharing 實測：它只提供 Apple 自家的認證型別（30/33/35/36），**沒有**傳統 VNC 密碼認證，而 MacMoba 走的是 type 30（Apple Remote Desktop，Diffie-Hellman）。用**故意造假的帳號**測：程式被要求 `appleRemoteDesktop` 憑證（`requiresUsername=true`，所以帳號有帶出去），server 回「Authentication or authorization failure」——代表 RFB 003.889 握手與 DH 金鑰交換都走完了，只是密碼不對。填真的 macOS 帳號密碼即可連上。測試用 `MM_VNC_PROBE=1` 開啟（需要本機打開螢幕共享） |
| **VNC 剪貼簿（雙向）** | ✅ 實測（自己寫的 RFB 3.8 測試 server，`TestSupport/vnc-server.py`，會把收到的東西寫進 log）：Mac 上複製 → server 收到 `ClientCutText: MAC-COPIED-THIS-4242`；server 送 `ServerCutText` → Mac 的 `NSPasteboard` 真的變成那段字。限制：RFB 的 cut-text **只有純文字**（沒有圖片／檔案，不像我們的 RDP）。另注意：一連上去就會把 Mac 當下的剪貼簿推給對方 |
| VNC 真・全螢幕 | ✅ 已有：**⌃⇧⌘F**（View → Full Screen Session），`canFocusRemoteDesktop` 涵蓋 VNC 與 RDP，會把側邊欄與分頁列一起收起來 |
| **VNC 的 ⌘V／⌘C 送到對面** | ✅ 修掉並實測（測試 RFB server 記錄 KeyEvent keysym）：原本用 `forwardKeyboardShortcutsIfNotInUseLocally`，RoyalVNCKit 的 `handlePerformKeyEquivalent` 直接 return false，⌘V 被本機 Edit ▸ Paste 吃掉。**實測舊版只送出 3 個事件**：Cmd↓ v↓ Cmd↑——**少了 v↑**，等於在對面留一個按住不放的鍵。改成 `forwardKeyboardShortcutsEvenIfInUseLocally` 之後，⌘V 與 ⌘C 都是完整的 4 個事件（Cmd↓ v↓ v↑ Cmd↑）。代價：VNC 分頁取得焦點時，⌘W 之類也會送給對面（跟 Screen Sharing 一樣）；⌘Q 與截圖鍵屬於系統 hotkey，仍留在本機 |
| **共用憑證物件 + 繼承** | ✅ 實作並實測(對真 SSH server,server 端記錄每次認證的帳號):新增 `CredentialConfig`(可重用的登入)、`SessionConfig.credentialRef`、`VaultData.credentials`／`groupCredentials`,以及純函式 `CredentialResolver`(優先序:指定憑證 > 群組預設 > session 自身欄位;憑證被刪除會安全退回自身欄位)。連線時在 `openTab`／`jumpSession`／tunnel 三處解析,**不改寫存檔**。驗證:一個 session 自身帳密**故意填錯**(WRONG-USER/WRONG-PW)但引用正確憑證,server 記到 `auth OK user=test`(用憑證的帳號登入);對照組不引用則 `auth REJECT user=WRONG-USER`。群組繼承同樣通過。14 個 resolver 單元測試 + 3 個 resolve-then-connect 整合測試 + 向後相容解碼測試。UI:側邊欄新增 Credentials 區(新增/編輯/刪除)、session 編輯器的 Login 選擇器(Custom／Inherit from group／具名憑證,選了就隱藏內嵌欄位)、群組右鍵設定預設憑證。**限制**:螢幕鎖住無法用合成點擊實際驅動 UI,但登入行為已用真 server 的認證 log 證實 |
| **每連線 notes／顏色／標籤 + 側邊欄搜尋** | ✅ 實作並實機驗證:`SessionConfig` 新增 `notes`／`color`／`tags`(皆 optional,向後相容;舊 vault 照開)、`SessionColor` 固定色盤(10 色含 none,帶 hex/rgb)、`SessionSearch`(跨 name/host/user/group/tags/notes/webURL 的大小寫不敏感比對 + 標籤正規化去重)。側邊欄:session 列左側顯示顏色圓點、名稱後接標籤 chip(超過一個顯示 +N)、Sessions 區頂端加搜尋框。編輯器新增 Organize 區(色盤 swatch、Tags 逗號分隔、Notes)。**實機驗證**:載入含顏色/標籤/notes 的 vault → 側邊欄正確顯示紅/橘/綠/藍圓點與 `web +1`／`db +1`／`sandbox` chip;搜尋「postgres」(只存在於某台的 tag)→ 列表只剩 prod-db-01、空群組 Staging 自動隱藏;開編輯器 → Organize 區正確帶出紅色 swatch 選中、tags `web, eu-west`、notes 全對。14 個 SessionSearch/SessionColor 單元測試(含 round-trip 與向後相容解碼) |
| **開機還原 + 睡眠自動重連** | ✅ 實作;開機還原**實機驗過**:開兩個 session(alpha/bravo)→ `defaults` 顯示 `openSessionIDs = (r1, r2)` → 關 app → 重開 → **兩個分頁自動回來並重連**(綠燈 + Welcome to smoke-server)。設計:`AppState.saveOpenWorkspace()` 只在使用者開/關分頁時寫入(鎖 vault 不清單子);`WorkspaceRestore.restorableIDs`(保留順序、去重、濾掉已刪的 session)決定要開哪些;解鎖後只在**主視窗、每次啟動一次**還原(避免 re-unlock 疊分頁)。本機 shell 不存(id 不在 vault)。睡眠重連:`AppState` 註冊 `NSWorkspace.willSleep/didWake`——睡前快照 connected 的 terminal pane,醒來等 1.5s(讓死 socket 浮現為 closed)只重連那些掉線的(存活的不動、不丟 scrollback);`WakeReconnectPolicy.shouldReconnect`(睡前有連 && 使用者沒關過)有單元測試。兩者各有 Settings 開關(預設開)。**限制**:沒辦法真的讓這台 Mac 睡著來端到端測 wake(會中斷自動化);重連動作用的 `connect()` 跟「還原時自動重連」「按 Enter 重連」是同一條、已驗證的路徑,決策邏輯另有單元測試。分割/群組版面還原成獨立分頁(v1 只還原頂層 session,不還原 split 佈局)|
| **自動化任務:連上自動跑指令** | ✅ 實作並用真 SSH server 的 shell 接收 log 驗證:`SessionConfig.onConnectCommands`(多行,每行一條指令,terminal 類型才有,向後相容)、`OnConnectScript.keystrokes`(換行正規化成 CR、補結尾 CR、空白回傳空字串,有單元測試)。連線成功後由 `TerminalTab` **直接送給該連線**(不廣播),延遲 0.5s 讓 banner/prompt 先出;每次連線都會跑(含睡眠/掉線重連,讓 session 回到原本的目錄/tail/tmux);並用 `connection === connectionAtSend` 守門,快速重連不會把舊指令打進新 shell。**實機驗證**:session 設 `echo MACMOBA-ONCONNECT-PROOF\nwhoami` → 一連上,server 的 shell 接收 log 記到 `shell1:"echo MACMOBA-ONCONNECT-PROOF\rwhoami\r"`——兩條指令自動打進 shell、各以 CR 結尾,沒有任何手動輸入;終端畫面也回顯出來。編輯器新增「On connect」區(僅 SSH/Mosh/Telnet)|
| **連線範本 + replacement token** | ✅ 實作並實機驗證(真 server 的 shell 接收 log + UI 驅動):`TokenExpander.expand`(支援 `%host% %port% %username%/%user% %name% %group% %domain% %webURL%`,大小寫不敏感、未知 token 原樣保留、孤立的 `%` 不會壞),`VaultData.templates`(獨立清單,不進連線列表,向後相容)。on-connect 指令送出前先 expand token,所以範本的腳本會代入每台自己的值。**Token 實測**:session 的 on-connect 寫 `echo TOKENPROOF %username%@%host%:%port%` → server shell 收到 `echo TOKENPROOF test@127.0.0.1:2299\r`——token 被展開,不是字面值。**範本實測**:側邊欄新增 Templates 區;雙擊範本「SSH box」→ 開出編輯器,已帶入範本的 port 2299/username root/SSH、名稱「SSH box copy」、**host 留空**待填。Sessions 標題的 `+` 改成 split 按鈕(點=新增、選單=從範本建立);範本用 SessionEditView 的 template 模式(host 可空)編輯。11 個 TokenExpander/templates 單元測試 |
| **多層跳板 + gateway failover** | ✅ 實作並用**三台真 SSH server 的 forward log**驗證:`JumpChain.resolve`(沿 proxyJump 展開整條鏈、外層先連、防迴圈與深度上限)、`GatewayFailover.candidates`(主位址優先、解析 host/host:port/IPv6、去重)、`SessionConfig.fallbackHosts`。核心 `connectParentChain` 把 `connectParentViaJump` 疊起來(SSH over SSH over SSH),連 SSH 終端、SFTP、mosh bootstrap、以及 tunnels/VNC/RDP/Web 的 forward 全部走這條;failover 放在共用的 `connectParent`(只在 TCP 連不上時換下一個位址,認證失敗不換),所以每種連線都受惠。順帶修掉一個舊的清理不對稱:關掉 target 現在會沿鏈把每一台 bastion 都收掉。**多層跳板實測**:target(2407)← hop2(2406)← hop1(2299),SFTP 走鏈連上 → **hop1 的 log 記到 `forward:127.0.0.1:2406`、hop2 記到 `forward:127.0.0.1:2407`**——流量真的依序穿過兩台 bastion,不是直連;而且列到的是 target 專屬的檔案。**failover 實測**:主機故意設死埠(59999)+ fallback `127.0.0.1:2299` → 連上 fallback 出現 banner;無 fallback 的死主機則正常失敗。編輯器新增 Fallback hosts 欄位;多層跳板不需 UI(jump 本身再設 jump 即成鏈)。15 個 JumpChain/GatewayFailover 單元 + 4 個整合測試,既有單跳測試也全過(refactor 無回歸)|
| **密碼管理器整合(op:// / cmd:)** | ✅ 實作並用真 SSH server 端到端驗證:密碼欄位可填**外部參照**,連線時才即時取得,vault 只存參照不存明碼。`op://Vault/item/field` → 跑 1Password CLI `op read`;`cmd:<指令>` → 跑任意指令取密碼(涵蓋 Keychain `security`、`pass`、`keepassxc-cli`、LastPass `lpass` 等,一個機制通吃)。`SecretReference`(分類 literal/onePassword/command,產生要跑的 argv,純函式測過)、`SecretResolver`(async 跑 subprocess、去尾換行、保留內部空白、失敗回報 stderr)。接進 SSH 終端、SFTP、mosh、Telnet 閘道、以及 VNC/RDP/Web 的 SSH 閘道鏈與 VNC/RDP 目標密碼。**端到端實測**:session 密碼存 `cmd:printf secret`(是參照,不是字面)→ 解析成 `secret`(測試 server 的真密碼)→ **登入成功、出現 banner**;字面字串「cmd:printf secret」則不可能通過。另有去尾換行、內部空白保留、失敗指令丟錯等邊界測試。編輯器密碼欄下方加了說明。13 個 SecretReference/SecretResolver 測試(6 純函式 + 7 含真 subprocess 與真連線)|
| **SFTP 進階:chmod / Quick Look / 隱藏檔** | ✅ 實作;chmod 對真 SFTP server **端到端驗證(讀實體檔案 mode)**:`FileMode`(八進位 parse、`octalString`、`ls -l` 式 symbolic 含 setuid/setgid/sticky,7 單元測試)、SFTP `SETSTAT`(只送 0o7777 權限位,保留檔案型別)。`setPermissions(0o600)` → **磁碟上的檔案真的變 600**(FileManager 讀出)且重新 list 也回報 600;chmod 不動檔案型別。隱藏檔:瀏覽器加 eye 開關,`resort` 過濾點檔(記住偏好);Quick Look:右鍵 → 下載暫存檔 → `qlmanage -p`(跟 Finder 空白鍵同一個預覽)。chmod 走 `RemoteFileService` 協定(SFTP 支援、FTP 預設丟 unsupported,UI 用 `supportsPermissions` 隱藏選項)。右鍵選單新增 Quick Look / Permissions…;權限對話框即時顯示 `644 = rw-r--r--`。9 個 FileMode/chmod 測試(7 純函式 + 2 對真 server)|
| **Overview / Dashboard 縮圖總覽** | ✅ 實作;空狀態實機驗過,填滿狀態受限於環境:跨所有視窗的連線總覽——每張卡片有縮圖(把 tab 的 NSView 用 `cacheDisplay` 截圖,背景 tab 未 layout 時退回大圖示)、名稱、目標、狀態燈(綠連上/黃連線中/紅斷開),點卡片把該視窗帶到前面並選中該 tab。`SessionTab.snapshot()`／`snapshotView`、`AppState.focus(tab:)`／`WindowState.focus(_:)`。入口:工具列 square.grid 按鈕 + View → Overview(**⇧⌘0**)。**驗證**:Overview sheet 在實機正確顯示(標題、Refresh/Done、adaptive grid、「No open connections」空狀態)。**限制**:這次要截「有連線的卡片」時,合成解鎖一直失敗(開發機正被使用、視窗一直移動、鍵入落點跑掉、vault 反覆跳 Wrong master password),所以填滿狀態沒截到;grid 是標準 SwiftUI 疊在已測過的 `allTabs`/`aggregateState`/`title` 上,cards 用 AppKit `cacheDisplay`。無新增單元測試(純 UI)|
| **Bonjour 網路探索** | ✅ 實作並**端到端驗證(自己廣播真服務再抓到)**:`BonjourServiceKind`(`_ssh._tcp`/`_sftp-ssh._tcp`→SSH、`_rfb._tcp`→VNC、`_rdp._tcp`→RDP、`_telnet`/`_ftp`,含類型↔SessionKind 對應)、`DiscoveredService.makeSession()`、`BonjourBrowser`(NetService,主 runloop 解析出 host+port)。**端到端實測**:用 `dns-sd -R` 廣播一個獨特名稱的 `_ssh._tcp`(port 2222)→ 瀏覽器約 1 秒內找到並解析出 port 2222、kind ssh、host 非空(不是等 12 秒 timeout)。UI:側邊欄 + 選單「Discover on Network…」開探索 sheet,列出找到的服務(圖示+名稱+kind+host:port),點一個 → 開編輯器帶入 host/port/protocol、留帳號密碼給使用者填。6 個測試(5 純函式 + 1 live discovery)。**UI 截圖限制**:開發機使用中、視窗被遮擋且無法可靠合成解鎖,填滿的 sheet 沒截到;但 browser 找真服務這條已用 live test 證實 |
| **Serial (RS232) 連線** | ✅ 實作並**用 pseudo-terminal 對測（雙向 byte 級驗證，免硬體）**：新的 `SessionKind.serial`（無登入、走 `TerminalTransport`，跟 SSH/Telnet 共用同一個 terminal pane）。`SerialSettings`（baud + `8N1`/`7E1`/`8O2` 格式字串，解析失敗退回 8N1）、`SerialPort.available()`（列 `/dev/cu.*` call-out 在前、`/dev/tty.*` 在後）、`SerialConnection`（`open(O_RDWR\|O_NOCTTY\|O_NONBLOCK)` → termios `cfmakeraw` + speed/CS5-8/parity/stop bits/`CLOCAL\|CREAD`、清掉 O_NONBLOCK、背景 thread 阻塞式讀）。編輯器有 Device 欄 + 從 `SerialPort.available()` 帶出的埠選單 + Baud 選單（9600…230400）+ Format 欄。**對測**：`posix_openpt`＋`grantpt`／`unlockpt`／`ptsname` 開一條 pty，SerialConnection 開 slave；master 寫 `hello-from-device` → 驗 `onData` 收到；`SerialConnection.write("ls -la")` → 從 master 讀回驗證；關閉觸發 `onExit`。4 個測試（3 設定/列舉 + 1 pty round-trip）。`SessionKindTests` 不變量把 serial 併入「無憑證」類（與 telnet/web 同列） |
| **匯入 ssh_config / PuTTY / RDCMan**（第三梯①） | ✅ 實作並用真實 fixture 對測：`SessionImporter.detect`（副檔名 + 內容 sniff）→ `parse`。**OpenSSH**：沿用既有 `SSHConfigImporter`（Host/HostName/User/Port/IdentityFile/Include + 萬用字元略過 + dedup），本梯加 **ProxyJump**→跳板欄。**PuTTY `.reg`**：解 `[…\PuTTY\Sessions\NAME]` 區塊、`%NN` 反解、`dword:` port、Protocol→kind（ssh/telnet），serial 等不映射的略過。**RDCMan `.rdg`**：XMLParser 走 group/server 樹，**巢狀群組路徑保留**（`Production/Databases`）、logonCredentials→user/domain→RDP session。統一 dedup（user@host:port）。UI：側邊欄「Import from Other Apps…」`fileImporter`（任意檔，靠內容判型）+ 結果 alert。12 個測試 |
| **連線健康監測**（第三梯②） | ✅ 實作並用真 socket 對測：`ReachabilityProbe.check`（getaddrinfo + 非阻塞 connect + `poll` timeout，回 `.up(latencyMs)`/`.down(reason)`；多位址逐一試）。`SessionConfig.reachabilityTarget`（serial/web/空 host 不檢）。App 端 `HealthMonitor`（**預設關**、可開的工具列 heart 開關、背景 sweep、bounded 併發 8、15s 週期），側邊欄每列狀態燈（綠上/紅下/灰未知，hover 顯示延遲或原因）。6 個測試：真 listener→up、port 1→refused、壞 host→resolve-down、TEST-NET-1→1s timeout、target 篩選 |
| **URI scheme quick-connect**（第三梯③） | ✅ 實作並對測：`SessionURL.parse`（ssh/sftp→ssh、mosh、telnet、ftp、vnc、rdp；user/password `%` 反解、每 scheme 預設 port、無 host 或未知 scheme 回 nil）。Info.plist 註冊 `CFBundleURLTypes`（ssh/sftp/mosh/telnet/rdp/vnc），app delegate `application(_:open:)` 既有的 pending/drain 機制加一條：非 .rdp 的 URL → `WindowState.openURL` 開 transient session。9 個測試 |
| **Expect/Send key sequences**（第三梯④） | ✅ 實作並**用 PTY 端到端對測**：`ExpectMachine`（transport 無關的 match→send 狀態機，跨 chunk 累積、逐步推進、比對後截斷 buffer 讓同一 prompt 不會滿足兩步、substring 或 regex）。`ExpectStep.parseLines`/`formatLines`（`expect => send`、`/regex/`、`\n\t\r` escape）。`SessionConfig.expectSequence`（Codable 向後相容）。TerminalTab 用 thread-safe `ExpectBox` 從 receive thread 餵、寫回同一連線；編輯器加「Expect / Send」區。11 個測試（含 PTY 假登入：master 出 `login:`→machine 送 admin→出 `Password:`→送 s3cret，全程從 SerialConnection 讀寫） |
| **Touch ID 解鎖 vault**（⑤） | ✅ 實作（既有）＋本輪搬進 Core 可測、加測試、修正過時註解。流程：勾「Remember in Keychain for Touch ID unlock」→ 主密碼存 login keychain；解鎖時先過 `LAContext.deviceOwnerAuthentication`（Touch ID／裝置密碼）再讀回、`vault.unlock`。**誠實的安全邊界（本輪實測釐清）**：真正 SE-ACL（鑰匙圈自己擋 biometry）或持久 SE key 都需要 `application-identifier`/`keychain-access-groups` entitlement，而那需要付費 provisioning profile；本 build 只有 Developer ID、沒有 profile，兩條路都回 **errSecMissingEntitlement (-34018)**（本機 probe 證實）。所以實際走的是 login-keychain item + **app 層 LA 閘門**——擋別的 app（鑰匙圈 per-item ACL），但不是密碼學上鑰匙圈強制，app 自己仍讀得到。ACL 那條保留著，未來有 profile 會自動點亮。6 個測試（隔離 service 不碰正式項）：plain store/read/delete round-trip、覆寫、缺項→notStored、biometry store 退回仍存、availability 不炸。**Touch ID 提示本身需真硬體＋人在場，無法 headless 驗** |
| **① SSH 金鑰產生器**（第四梯，對齊 MobaKeyGen） | ✅ 實作並**用真 `ssh-keygen` 對測到底**：`SSHKeyGenerator.generate` 產 ed25519 / ECDSA P-256/384/521，輸出真正的 openssh-key-v1 PEM（byte-for-byte 跟 ssh-keygen 一樣）、公鑰行、`SHA256:` 指紋；選填 passphrase 用 bcrypt KDF + aes256-ctr（重用既有 `BcryptPBKDF`）。**鐵證**：把產出的私鑰寫檔 → `ssh-keygen -y -f` 推導公鑰，四種型別都跟我們一致；`ssh-keygen -l` 指紋一致；`ssh-keygen -y -P` 收我們的加密金鑰。另有「產完再過自家 parser」round-trip。UI：選單「Generate SSH Key…」→ 選型別/註解/passphrase → 產生 → 複製公鑰 / 存私鑰（自動 chmod 600 + 存 .pub）。6 測試 |
| **② 網路工具**（第四梯，對齊 MobaXterm Tools） | ✅ 實作並用真 socket 對測：**Wake-on-LAN**（magic packet＝6×FF＋MAC×16＝102 bytes，UDP broadcast；MAC 接受 `:`/`-`/裸 hex）、**Port Scan**（重用 `ReachabilityProbe` 併發掃常見埠）、**DNS Lookup**（getaddrinfo v4/v6）。**驗證**：magic packet 打到 loopback UDP 真的收到 102 bytes、掃描只回真的開著的埠、DNS 解出 localhost。UI：選單「Network Tools…」三格面板。9 測試 |
| **③ 遠端資源監視**（第四梯，對齊 MobaXterm server monitor） | ✅ **使用者實機驗收通過（2026-08-19）**：對跳板後的 RHEL VM 開 Server Monitor，CPU／記憶體／load／uptime 都正確顯示。 實作並用真 `uptime`/`/proc` fixture 對測：`RemoteStatsProbe` 跑一次性指令（uptime + /proc/meminfo + 兩次 /proc/stat 相隔 0.4s）解析出 load average、CPU%（兩取樣 idle/total delta）、記憶體用量%（total−available）、uptime、users；相容 Linux 與 macOS/BSD（沒 /proc 就只給 load）、遇垃圾不炸。走既有 `SSHConnection.runCommand`（跟 mosh bootstrap 同一條 exec 路徑，含跳板+host key+密碼解析）。UI：側邊欄右鍵「Server Monitor…」→ CPU/記憶體進度條 + load/uptime/users，可 Refresh。10 測試（parser 全用真實輸出 fixture） |
| **④ X11 forwarding**（第四梯，對齊 MobaXterm 招牌） | ⚠️ **原生做不到、用等效方案**。**源碼實證**：NIOSSH 的 `SSHChannelType` 只有 session/direct-tcpip/forwarded-tcpip，`SSHMessages.swift:905` 對其他 channel 型別（含 x11）一律 `throw unknownPacketType`——所以 sshd 要開回來的 `x11` channel 會被解析層拒收，原生 `x11-req` 在這個 SSH stack 上不可能（跟 ssh-agent／keyboard-interactive 同級的上游限制）。**等效方案（已實作）**：X11 over remote forward——請伺服器聽 `127.0.0.1:(6000+N)` 並把連線 forward 回 Mac 的 X server，遠端 `export DISPLAY=localhost:N`；重用已測過的 `RemoteForward`。純函式部分全測：display↔port、DISPLAY 解析、`.Xauthority` 二進位 cookie 解析（真格式 fixture）、遠端 setup 指令、tunnel config（9 測試）。UI：SSH/Mosh 編輯器「X11」開關；連上自動起 forward + 送 DISPLAY，斷線收掉。**限制/未實機驗**：開發機沒裝 XQuartz（也沒 /tmp/.X11-unix），live 端到端無法在此驗；需 XQuartz 開 TCP listening（`defaults write org.xquartz.X11 nolisten_tcp -bool false`）；forward 走直連不經跳板。跟跨螢幕 RDP 同樣：純邏輯測到底，live 由使用者實機驗。**2026-08-20 使用者實機驗收通過**：MBA 裝 XQuartz 並開啟 TCP 監聽後，遠端 `xclock` 的視窗正確出現在 Mac 上 |
| **zmodem 接收 (rz)**（低價值批次，終於做） | ✅ 實作並**跟真的 lrzsz `sz` 對傳對測**：`ZModem` primitives（CRC-16/XMODEM、CRC-32、ZDLE escape、hex/binary header、position bytes——CRC 用公開 test vector `0x31C3`/`0xCBF43926` 驗）、`ZModemReceiver`（streaming 狀態機：ZRQINIT→ZRINIT、ZFILE 解檔名/大小→ZRPOS、ZDATA 子封包逐一收 + CRC 檢查、ZEOF/ZFIN，壞 CRC 送 ZRPOS 要求重傳）。**鐵證**：用 pipe 接到系統 `sz`，傳 2000 bytes（含 0x18/0x11/0x13/0x7F 需 escape 的值）→ 收到的 bytes 跟原檔**完全一致**、檔名一致。過程抓到兩個真 bug（子封包 offset 差 2、incomplete frame 重複累加子封包）都靠這個對測揪出來。終端整合：偵測到 `**\x18B00`（ZRQINIT）自動進接收模式、回應寫回連線、完成存到 ~/Downloads、不污染畫面。15 測試（10 primitives + 5 receiver 含 sz 互通） |
| **zmodem 發送 (sz)**（v1.43，補齊另一方向） | ✅ 實作並**跟真 lrzsz `rz` 對傳對測**：`ZModemSender`（狀態機：收 ZRINIT→送 ZFILE 檔名/大小、收 ZRPOS→送 ZDATA 子封包串流 + ZEOF、第二個 ZRINIT→送 ZFIN、收 ZFIN→送 "OO"；資料用 CRC-16）＋ `ZModem.dataSubpacket`/`nextHexHeader` primitives。**鐵證**：pipe 接系統 `rz -y`，送 3000 bytes → rz 寫到磁碟的檔案跟原檔**完全一致**；另有「sender↔自家 receiver」記憶體對接測試。UI：選單「Send File (ZMODEM)…」→ 選檔 → 對遠端送 `rz\r` 起接收端 → 串流，完成顯示狀態。3 測試 |
| **rlogin**（MobaXterm 對齊，補協定） | ✅ 實作並用 in-process TCP mock server 對測：`RloginProtocol`（RFC 1282 handshake `\0localuser\0remoteuser\0term/speed\0`、window-size 訊息 `0xFF 0xFF ss` + 4×uint16、first-byte ack 判定）、`RloginConnection`（NIO，走 `TerminalTransport`，跟 telnet 共用 pane；**經既有 SSH 跳板隧道** `RemoteDesktopRoute`，因為 rlogin 是明文）。`SessionKind.rlogin`（port 513、明文警告、可分割、有 username 無密碼）。**驗證**：mock server 收到的 handshake 含 localjo/root、ack 後收到 banner、pane→server 打字送達。6 測試（5 純協定 + 1 TCP round-trip） |
| **UX P0-1：Session 編輯器分類式重構**（v1.44，藍本 Royal TSX Properties） | ✅ 一張直疊到 **1190 pt** 的表單（13" 螢幕 ~900 pt，已被裁切）改為**固定 680×540** sheet：左側 170 pt 分類欄（General/Login/Connection/Automation/Display/Organize，依協定顯隱）+ 右側該分類 Form（超出自捲動）。分類欄有藍點標示非預設值的分類。**手算高度徹底刪除**（grep `sheetHeight`/`maxSheetHeight` = 0——之前每加一個欄位都要手改常數，本輪開發就改過三次）。⌘S 儲存；Esc 取消時若有未儲存編輯（跟 load 時快照比對）→ 確認對話框。Protocol picker 從 segmented（9 個塞不下）改 menu。save()/load() 欄位映射邏輯**原封不動**搬移，624 項測試全過為證 |
| **UX P0-2：per-tab 狀態列**（v1.44，藍本 MobaXterm 狀態列） | ✅ **使用者實機驗收通過（2026-08-18）**：連一台會失敗的機器 → scrollback 保持乾淨、狀態列變紅、點紅字彈出完整錯誤。 `feedStatusLine`（把「Connecting…」「ZMODEM: saved…」直接餵進終端 scrollback，會被 ⌘F 搜到、reconnect 後殘留）**16 處→0**。每個 pane 底部 22 pt 狀態列：左側常駐連線狀態（●綠/黃/紅 + user@host:port，由 `state` 直接導出——連線中/失敗/關閉訊息因此整批刪除不再印字）；**失敗變紅、點擊 popover 看完整錯誤（可選取複製）**，取代印進終端的多行 error。右側暫態訊息（mosh/ZMODEM/X11/logging），4 秒淡出、**佇列不互蓋**、hover 暫停消失。新 connect 清空佇列。**誠實修正**：計劃書寫「狀態被 session log 錄下」是錯的——logger 只錄遠端資料，feedStatusLine 從未進 log;實際傷害是 scrollback 污染+搜尋命中 |
| **UX P0-3：通知去 modal 化**（v1.44） | ✅ 視窗頂部滑入式 banner（材質膠囊、綠勾/紅三角、5 秒自動消失、點擊提早關、**佇列輪播**）。`lastError`/`infoMessage` 用 didSet 橋接進 banner 佇列——**幾十個現有呼叫點零改動**全部自動 banner 化。轉換 4 處純通知 modal：Error alert、Import alert、側邊欄 importResult alert、SFTP Error alert。**白名單盤點**：剩餘 19 個 modal 逐一分類（廣播確認/host key/RDP cert/匯出匯入決策/密碼輸入×2/貼上警告/Replace/Sync/刪除確認/各 Rename/New 輸入）全屬決策或輸入，**0 例外** |
| **UX P1-4：側邊欄瘦身 + Library 視窗**（v1.45，藍本 Royal TSX Navigation） | ✅ **使用者實機驗收通過（2026-08-18）**：⌥⌘L 開啟，三分類（巨集／憑證／範本）管理正常。 側邊欄五區→**兩區**（Sessions+Tunnels）；搜尋欄**固定置頂**不再隨列表捲走。Macros/Credentials/Templates 移入獨立 **Library 視窗**（`Window` scene，⌥⌘L——原定 ⇧⌘L 撞上 Session Log 既有快捷鍵，發現後改 ⌥⌘L）：左欄三分類含計數、右欄清單+底部新增鈕、空狀態附一句話說明；編輯 sheets 原樣搬移。**Macro 執行路徑不變**（Macros 選單 ⌃⌘1–9 早已存在，側邊欄從來不是唯一入口）；「From template」新建入口保留在 Sessions 的 + 選單。孤兒 MacroRow struct 刪除。側邊欄底部低調 Library 按鈕 |
| **UX P1-5：Inspector 面板**（v1.45，藍本 Royal TSX + Finder） | ✅ **使用者實機驗收通過（2026-08-18）**：⌥⌘I 開合、單擊看／雙擊連、notes 與 tags 就地編輯皆正常。 ⌥⌘I 開合、寬 260 pt、狀態跨啟動保存（UserDefaults）。**單擊看、雙擊連**（Finder 文法）：大圖示+名稱+協定 chip → 目標字串（monospace、可選取、一鍵複製）→ **健康卡**（綠/紅/未測 + Check 鈕，重用 ReachabilityProbe 2 秒回結果）→ 顏色 swatch／Tags／Notes **就地編輯**（0.8 秒 debounce 寫回 vault，不會一鍵一次加密寫檔）→ 快速動作（Connect/Edit…/Monitor…/Duplicate）。手排 trailing panel 而非 `.inspector`——**那要 macOS 14，本 app 支援 13**，視覺等價。未選取時空狀態提示 |
| **UX P1-6：選單重組**（v1.45，HIG Menus） | ✅ 原本 17 項擠在 File（連線/傳輸/工具/窗格四種心智）→ 四分類：**File**（New Local Terminal/Quick Connect/Open RDP/匯入匯出，6 項）、**Session** 新選單（Connect Selected ⌘↩/Disconnect/MultiExec/Session Log/Logs Folder/ZMODEM）、**Macros**（不動）、**Tools** 新選單（Generate SSH Key/Network Tools/Trusted Hosts/Library）；分割窗格五項移入 **View**。**快捷鍵全域掃描零重複**（含新增的 ⌘↩/⌥⌘I/⌥⌘L） |
| **UX P2a：桌面級打磨第一批**（v1.46） | ✅ 四項：**Settings 三分頁**（General/Terminal/Logs 圖示分頁、固定 480×360，取代單頁長表單；所有既有設定原樣搬移）。**可自訂工具列**（`.toolbar(id:)` + 8 顆穩定 id，右鍵「Customize Toolbar…」增刪排序，配置自動保存）。**空狀態雙形態**（EmptyStateView：全新 vault → Welcome + 三入口按鈕 New/Import/Discover 一鍵可達；已有 sessions → 指回側邊欄+⌘K 提示）。**終端主題 Auto**（`TerminalTheme.autoID` + `resolve(id:darkMode:)`：深色→MacMoba Dark、淺色→GitHub Light；`AppleInterfaceThemeChangedNotification` 監聽，系統切外觀時已開終端就地換色、scrollback 不失；兩個 theme picker 都加「Auto (match system)」選項）|
| **UX P2b：拖放 + a11y + 資料夾儀表板**（v1.47） | ✅ **群組儀表板使用者實機驗收通過（2026-08-18，v1.64）**：點資料夾即見成員清單與健康彙總；跳板後的成員正確標示為 ⑂ 而非誤報 down。 **檔案拖進 pane**（P2-9 部分）：拖曳懸停時 overlay 顯示落區——SSH pane 雙區「Upload via SFTP（先聚焦該 pane 再走既有 `uploadItems` 到目前目錄）/ Send via ZMODEM」，其它終端（telnet/rlogin/serial/mosh）單區 ZMODEM；zone 各自是 drop target，拖曳中直接選、不用事後對話框。**更正（2026-08-18）**：先前此處記載「SFTP 拖出到 Finder 未做」是**錯的**——`SFTPFileTable.swift` 早就以 AppKit NSTableView + `NSFilePromiseProvider` 實作了拖出下載（SwiftUI 的 `.onDrag` 無法履行 file promise 契約，所以那份清單特地做成 AppKit）。實際未做的只有 P2-12 的 type-select。**a11y**（P2-12 部分）：側邊欄健康燈 + 編輯器色票補 `accessibilityLabel`（VoiceOver 讀「Reachable (12 ms)」而非 image）；**未做**：sidebar type-select（要 macOS 14 `onKeyPress`，本 app 支援 13）。**資料夾儀表板**（P2-13）：點群組資料夾 → inspector 顯示 GroupDashboard——成員數、健康彙總 chips（n up/m down）、全成員清單（各自健康燈、單擊選取雙擊連線）、**Connect All** 一鍵開整組分頁（配 MultiExec 一個開關就緒）。群組/成員選取互斥切換 |
| FreeRDP 靜態連結 | ✅ 實測（`otool -L` 沒有任何 Homebrew dylib，OpenSSL 也是靜態 .a；binary 21MB，可散佈） |
| RDP 跨螢幕（Use all displays，⌃⇧⌘F） | ✅ **使用者在 MBA＋4K 外接雙螢幕實測**（1.2.1）：兩個螢幕都出畫面、Dock 不再蓋住 Windows 工作列、**第二個螢幕上的滑鼠點擊落點正確**。這台開發機只有一個螢幕（走螢幕共享），前後花了六個版本才收斂——每個 bug 都只在特定螢幕組合下才會出現 |

---

## 這輪修掉的真實 bug（都是實機測試才抓到的）

1. **Session 編輯器的 Password 欄位被切掉** — 加了 Group 列之後超出 sheet 固定高度，
   新 session 根本設不了密碼。
2. **Tunnel 編輯器的 Target port 被切掉** — 同一個成因（Direction radio 擠掉最後一列）。
3. **Host key 提示視窗會撞到 8 秒 timeout** — 使用者慢慢核對指紋就會連線失敗。
   會跳提示的連線改成 180 秒；壞密碼仍走 transport close 快速失敗。
4. **拒絕 host key 會卡到 timeout 才報錯** — NIOSSH 不會因驗證失敗關連線，
   現在主動關閉 transport（測試從 8 秒變 6 毫秒）。
5. **SFTP 拖放整組失效** — SwiftUI row 的手勢吃掉滑鼠事件，AppKit drag handle 收不到；
   檔案列表改用 **NSTableView** 才修好（SwiftUI 的 row 無法 vend file promise）。
6. **同時連同一台新主機會跳兩次 host key 視窗** — `NSAlert.runModal()` 會擋住 main actor，
   第二個連線來不及登記成 waiter。現在跳視窗前先重查 store。
7. **Session log 完全空白** — `logger` 主執行緒寫、SSH 執行緒讀，沒有同步，
   讀端一直看到舊的 nil。改用鎖保護的 holder；順便補上「開始記錄時先倒入
   現有 scrollback」和 log 檔權限 0600（原本 0644）。
8. **開始記錄時跳的 alert 會搶焦點** — 模態視窗讓你接著打的字進不了終端機。已移除。
9. **entitlements 用了 `$(AppIdentifierPrefix)`** — codesign 不會代換 Xcode 變數，
   字面值害 launchd 拒絕啟動（error 163）。已改成最小 entitlements。
10. **側邊欄整條變空白（使用者回報，我一開始誤判成自己拖錯分隔線）** —
    側邊欄欄寬只設了 min/ideal 沒設 max，所以可以被拖寬、也會被
    macOS 視窗還原成很寬。一旦開了終端機分頁，split view 就把欄位壓回
    大約視窗的三分之一（900pt 視窗＝300pt），但 **List 沒有跟著重新排版**，
    每一列就整條往左位移到畫面外，看起來像側邊欄空了
    （只剩最右邊的 `+` 和 `^⌘1` badge）。
    改成 `navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 300)`——
    上限就等於它會被壓到的寬度，於是「壓縮」這件事根本不會發生。
    **這個 bug 在多視窗改動之前就存在**，只是多視窗讓它更常出現。
11. **Session 編輯器的 Password 欄位又被切掉（第三次）** — 加了 protocol picker
    和通道說明文字之後又超出 sheet 固定高度。這次直接把高度加到 620 留餘裕，
    而不是剛好塞下今天的版面。
12. **VNC 分頁的狀態燈不會變** — `SessionTab` 只有幫 pane tree 裡的 TerminalTab
    訂閱 `objectWillChange`，VNC（和本機 shell）是整個分頁層級的子物件，沒人轉發，
    所以 tab chip 的燈號與標題停在舊值。加了 `childObserver` 轉發。
    本機 shell 之所以看起來沒事，只是因為它的狀態在畫面出現前就同步設好了。
13. **RDP 連不上（連續三個都是 FreeRDP 設定問題，都靠 server／client log 才找到）** —
    (a) `mm_pre_connect` 把 `FreeRDP_OrderSupport` 當 bool 設定，但它是 byte 陣列，
    set 失敗直接讓 pre-connect 整個掛掉（ERRCONNECT_PRE_CONNECT_FAILED）；
    (b) 把 rdpsnd channel 編掉之後，靜態連結的 client 仍然會去 load 這個 addin 而失敗——
    改成把 channel 編進去並連 macOS 音訊 framework（系統 framework，散佈零成本）；
    (c) 沒有宣告 RemoteFX/NSCodec，server 回 "Client doesn't support RemoteFX or NSCodec"。
14. **`CertificateCallbackPreferPEM=TRUE` 會把整份 PEM 塞進 fingerprint 參數** —
    確認視窗變成一大坨 base64。關掉就拿到正常的 SHA-256 指紋。
15. **🔴 出貨版在別台 Mac 上 NLA 直接壞掉（只有在使用者的 MBA 上才發現）** —
    OpenSSL 3 把 **MD4 與 RC4 移到 LEGACY provider**，而 NTLM 兩個都要用
    （NT hash 要 MD4）。我的開發機裝了 Homebrew openssl@3，legacy provider 找得到，
    所以「剛好」會動；沒裝 Homebrew 的 Mac 就 `SEC_E_NO_CREDENTIALS`，
    NLA 完全過不了。**在自己的機器上測永遠測不出來。**
    解法：FreeRDP 編譯時加 `-DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON
    -DWITH_INTERNAL_RC4=ON`，WinPR 就用自己的實作，不再依賴 OpenSSL provider。
    驗證方式：`OPENSSL_MODULES=/nonexistent` 啟動 app 模擬「沒有 Homebrew」的環境，
    再連真 server——修好之後照樣連得上。
16. **接真 Windows server 才抓到的四個（GUI app 專屬的坑）** —
    (a) **FreeRDP 會在 stdin 問帳密**：GUI app 沒有 terminal，read 就卡住，
    最後變成 `ERRCONNECT_CONNECT_CANCELLED`，畫面上什麼線索都沒有。
    要 `CredentialsFromStdin=FALSE` 並自己實作 `Authenticate` callback。
    (b) **滑鼠 Y 軸上下顛倒**：view 是 `isFlipped`，`convert(_:from:nil)` 已經是
    左上原點，我又翻了一次——點工作列變成點到標題列。（`draw()` 裡那次翻轉是
    給 CGImage 的底左原點用的，兩者不能混。）
    (c) **沒有 NSTrackingArea**，`mouseMoved` 永遠不會觸發，滑鼠移動送不出去。
    (d) **沒開 `FreeRDP_UnicodeInput` 能力**：server 直接忽略 unicode 鍵盤事件，
    症狀是「打字沒反應但 Esc 有用」（Esc 走 scancode 路徑）。
17. **RDP 完全收不到修飾鍵** — `flagsChanged` 根本沒實作，Ctrl/Alt/Shift/Cmd 的
    狀態從來沒送出去，所以任何快捷鍵都沒用（⌃V 一貼上就露餡）。
    另外按著修飾鍵時字母鍵必須送 **scancode** 而不是 unicode——server 是用
    實體鍵位比對 Ctrl+V 的，不是比對「會打出什麼字」。
18. **連線前就放在剪貼簿的文字不會分享出去** — 只在「變更」時才推送，
    所以連線當下已經複製好的東西要等你再複製一次才會出現在遠端。
    改成連線時先推一次。
19. **使用者回報：貼檔案到 RDP 時整個 app 崩潰** — crash report 顯示掛在
    **thread 12 / `CA::CG::Queue`，堆疊全在 Apple 的 Metal driver（AGXMetalG14G）
    與 QuartzCore 裡**，我們自己的程式碼一行都不在崩潰堆疊上。
    貼上只是觸發了一次大範圍重繪。
    我們這邊確實有一個值得修的地方：原本**每一幀都新建一個 CGImage、再
    `needsDisplay` 走 CPU backing store 讓 CoreAnimation 上傳**。
    改成 layer-backed、直接 `layer.contents = image`（RoyalVNC 的 VNC view 也是
    這樣做），並擋掉寬高為 0 的畫面。
    ⚠️ **這個崩潰我在本機重現不出來**（在對方的 M2 MacBook Air 上發生），
    所以只能說「把最可疑的那條路徑換成標準做法」，不能宣稱已修好。
20. **`NSFilePromiseProvider` 只能拖曳，不能 ⌘V** — 這是 AppKit 的限制，不是 bug。
    只有 promise 的剪貼簿，Finder 的「貼上」選單項目是**灰的**（我直接查了選單狀態），
    所以 promise 永遠不會被觸發、檔案也永遠不會傳。⌘V 要的是真的
    `NSPasteboardTypeFileURL`。這也是 FreeRDP 在 Linux 上用 FUSE 的原因。
21. **一次性的 `suppressNextPasteboardPush` 旗標會吃掉使用者真正的複製** —
    我們自己寫剪貼簿時把旗標設起來，但寫入當下已經同步了 `pasteboardCount`，
    旗標就留著，被**下一次**（使用者真的複製檔案那次）消耗掉，
    症狀是「Mac 複製檔案，Windows 完全收不到」。旗標本來就是多餘的，直接拿掉。
22. **Session 編輯器 sheet 高度不夠（第四、五次）** — 而且這個 Form **不會捲動**，
    內容超出就直接裁掉，Password 藏在按鈕列後面、滑鼠點不到。
    先改成依 protocol 算高度，但加了 Folders 區之後又不夠——
    最後把 **Password 直接搬到 Username 底下**（VNC/RDP），
    重要欄位永遠在最上面那一區，就不再受下面加了什麼影響。
23. **第二份 crash report：這次是我們自己的 bug** — 崩在
    **thread 3 `mm_thread` → `freerdp_shall_disconnect_context` →
    `WaitForSingleObjectEx`**，`x19 = 0x900000000`（commpage 保留區，
    永遠不可能合法）。也就是 **context 被 free 掉之後連線執行緒還在讀它**。
    原因：`macmoba_rdp_disconnect` 只等執行緒 **3 秒**，等不到就往下走，
    `macmoba_rdp_free` 照樣把 context free 掉。而
    **`freerdp_disconnect` 在網路已經斷掉時本來就會很慢**——正好就是
    使用者最可能按斷線的時候。crash report 裡有**兩組 `play_thread`**、
    thread 10/11/12 **堆疊全空**，都指向「正在重連／正在收尾」。
    修法是把「停掉再 free」換成 **refcount**：呼叫端與連線執行緒各持一份，
    **最後放手的那一個才做 teardown**。等待仍然有上限（否則主執行緒會被
    網路卡住），但**逾時後改成交棒，不是照樣 free**。
    WinPR 的 `CloseHandle` 對還在跑的執行緒是 detach，所以這樣是安全的。
    連帶：`userData` 從 `passUnretained` 改成 **`passRetained`** ＋ 新的
    `onRelease` callback——執行緒既然可能活得比分頁久，
    晚到的 callback 就不能打在已經釋放的 Swift 物件上。
    ✅ 這次**有測試**：`RDPLifetimeTests` 用「在 state callback 裡把連線執行緒
    卡住」來穩定製造逾時，**把修正還原後測試確實會失敗**
    （`session was torn down while the connection thread was still in it`）。
24. **使用者回報：SSH 分頁按 split，選單裡可以選 RDP，但選了是空白的** —
    分頁樹（`Node`）的葉子**只有 `TerminalTab`**，VNC/RDP 是「整個分頁」等級的
    東西，本來就進不了 pane。但 `SplitMenu` 是直接列 `app.data.sessions`
    **沒有濾掉種類**，選下去就用 RDP 的 config 建了一個 `TerminalTab`——
    於是它跑去對 **RDP 的 port 開 SSH 連線**，永遠停在 connecting，看起來就是空白。
    同一個洞有三個入口：
    (a) 「New Connection」列出所有 session；
    (b) 「Move Open Tab Here」列出所有分頁——把 RDP 分頁 merge 進來會拿到
        那個**從來沒連過的 placeholder leaf**（空白 pane），而且 source 分頁被
        移出 `tabs` 時**連線就這樣漏掉了**，沒有人去 disconnect；
    (c) `smartSplit`（⌘D）抓 `tabs.first { $0.id != tab.id }`，同樣不看種類。
    修法：加 `SessionKind.fitsInSplitPane`（只有 ssh 是 true），
    三個入口全部過濾，並且在 **model 層**（`splitFocused` / `mergeTab`）也加 guard，
    這樣以後新的 UI 路徑不會再把洞打開。⌘D 在 RDP/VNC/local 分頁上改成 **disabled**，
    而不是按了沒反應。
25. **同一類洞的其他出口：選單項目對 VNC/RDP 分頁還是亮的** — 修完 split
    之後把整排選單掃過一次。`Start Session Log` 之前的條件是
    `isLocal != false`，**沒有排除 VNC/RDP**，而那些分頁的 `focusedPane` 是
    placeholder，所以它會**幫一個永遠收不到位元組的終端開 log 檔**，
    選單還會卡在「Stop Session Log」。`Find…` / `Find Next` / `Find Previous`
    則是按了沒事（`toggleSearch` 自己有 guard），但選單看起來是可以用的。
    全部改成看 `isSinglePane`，並且在 `toggleSessionLog` / `findNext` /
    `findPrevious` 也加 model 層 guard。
    `Broadcast Input` 是 app 層級的開關，維持一直可用（先開再切分頁是合理的）。
26. **RDP 憑證每次連線都要再確認一次** — shim 對 FreeRDP 回傳 `2`（accept once），
    註解寫的是「決定權留在 Swift 這邊」，**但 Swift 從來沒有存過**，
    所以決定被記在「哪裡都沒有」。而且 `~/.config/freerdp` 根本不存在，
    等於雙方都沒記。改成存進 `rdp_certs.json`（跟 known_hosts.json 同一個目錄，
    但**分開檔案**：一邊是 TLS 憑證指紋，一邊是 SSH host key，混在同一張表遲早查錯）。
    ⚠️ key 一定要用 **session 設定裡的 host:port**，不能用 FreeRDP 實際連到的位址——
    走 SSH 通道時那是 127.0.0.1 加一個**每次都不一樣的隨機 local port**，
    拿它當 key 等於永遠都是新伺服器。
27. **把「憑證名稱不符」講成「憑證被換掉了」** — `VERIFY_CERT_FLAG_MISMATCH`
    是**主機名稱**對不上（CN 寫 localhost、你用 IP 連），不是指紋變了。
    但 UI 直接跳紅色的「憑證已變更／可能有人在冒充」。
    **用 IP 連自簽伺服器是常態**，對常態狂喊狼來了，只會訓練使用者把真正該看的
    那一次也一起按掉。現在分成三種情況：第一次見到（warning，順帶說明名稱不符很常見）、
    指紋和上次不同（critical，並列出前後兩個指紋）、已 pin 且相同（不打擾）。
28. **Retina 像素要來了又丟掉** — `requestResize` 一直有乘 `backingScaleFactor`，
    所以**跟 server 要的是對的**；但 layer 的 `contentsScale` 沒設，還是預設 1，
    CoreAnimation 就把那張 Retina 大小的圖**降回點解析度**再合成。
    等於流量照付、清晰度沒拿到。改成 `layer.contentsScale = backingScale`，
    並加 `viewDidChangeBackingProperties`（視窗拖到不同 scale 的螢幕要重算）。
    另外**連線當下**那次算尺寸原本沒乘 scale——有 disp 的 server 會在第一次
    resize 時被修正，**沒有 disp 的就一路半解析度到底**。
    ⚠️ 這台三個螢幕都是 1:1，**Retina 效果在本機看不出來**，
    所以把算式抽成 `RDPDesktopSize`（放 MacMobaCore）用單元測試涵蓋。
29. **xrdp 容器一 resize 就斷線，跟我們無關** — 每次 disp resize 都會出現
    `freerdp_bitmap_decompress_planar failed`。查證方式：
    (a) 出問題的那幾個寬度**本來就是 4 的倍數**，新舊程式算出來的數字**一模一樣**；
    (b) 把 `/sound` 拿掉重測，**照斷**。所以不是寬度取整、也不是音訊造成的。
    真 Windows AD server 之前 resize 是好的（732×714 → 1132×864）。
30. **「這個 Form 不會捲動」其實是錯的（而且我照抄了好幾次）** — 之前的註解寫
    「Form 內容超出就直接裁掉、不會捲」，加 Display 區之後我照著這個假設去
    算高度。**實際用滾輪測過：macOS 26 上它會捲**，本來被裁掉的 Folders 說明
    捲一下就看得到。所以高度只影響「不用捲就能看到多少」，**不是正確性問題**。
    註解已更正——不然下一個人會為了一個不存在的 bug 繼續加高度。
31. **RDP 固定解析度** — session 編輯器 Display 區。選 fixed 時要注意兩件事：
    (a) **不能送 `/dynamic-resolution`**，否則 server 還是可以重新協商，
        使用者指定的尺寸就白設了；
    (b) `requestResize` 要直接擋掉，改成讓 pane 縮放桌面。
    寬度一律取 4 的倍數、並夾在 640×480 以上——編輯器讓人自己打數字，
    什麼值都可能出現。
32. **全螢幕不能只呼叫 `toggleFullScreen`** — 系統的 ⌃⌘F 只是把視窗變全螢幕，
    我們的側邊欄和分頁列**還在**，遠端桌面根本沒吃到整個螢幕。所以另外做一個
    「Full Screen Session」把 chrome 一起收掉。兩個必要的細節：
    (a) 一定要監聽 **`didExitFullScreenNotification`**——使用者可以用綠燈、
        系統選單或 Spaces 手勢離開全螢幕，不走我們的指令；沒接的話側邊欄會
        一直收著，而且看不出要怎麼叫回來；
    (b) **Esc 不能拿來解除全螢幕**，那顆鍵要送給遠端桌面。
    另外：進全螢幕會改變 pane 大小 → fit-to-window 模式會送一次 disp resize，
    在 xrdp 上就直接斷線（見第 29 條）。**改成 fixed size 就活得下來**，
    實測過：同一台 xrdp，fit 進全螢幕斷線、fixed 進全螢幕沒事。
33. **`host:port` 這個 key 遇到 IPv6 會拆錯** — store 一直是用 `"\(host):\(port)"`
    當 key，寫入讀取都自己拼字串所以沒事；但要做管理 UI 就得**反過來拆**。
    用第一個冒號拆的話 `::1:22` 會變成 host `""`——列表少一筆、
    「Forget」按了也刪不掉。改成**用最後一個冒號**拆，並且 port 解析失敗就跳過
    （這個檔案在有 UI 之前是給人手動編輯的，本來就可能長得很怪）。
    有測試涵蓋 IPv6 的列出＋刪除，以及手改壞掉的 JSON。
34. **List 的 section footer 不會自動換行** — 文字太長就直接截斷成一行，
    `.fixedSize(horizontal: false, vertical: true)` **也蓋不掉**。
    最後是把說明文字縮短到跟隔壁那段差不多長。
    （順帶：`KnownHostsStore` 從 app target 搬到 MacMobaCore 才測得到——
    它本來就只有 Foundation，放在 app target 只是歷史原因。）
35. **Telnet 走既有的 terminal pane，不另開一種分頁** — `TerminalTab` 本來寫死
    `SSHConnection`，抽出 `TerminalTransport`（write / resize / close）之後，
    Telnet 直接**免費拿到 split、MultiExec、session log、搜尋**。
    協商本身寫成**沒有 socket 的純狀態機**（`TelnetNegotiator`），才測得動。
    幾個一定要處理的細節：
    (a) **IAC IAC 要收斂成一個 0xFF**，不然二進位輸出會少一個 byte；
    (b) 不認得的 option 要**明確回 WONT/DONT**，不能沉默——server 會一直等；
    (c) **同一個 option 重複協商不能再回**，否則兩邊互相確認到天荒地老；
    (d) NAWS 的寬高**本身也要 IAC escape**（255 欄的終端會提早結束 subnegotiation）；
    (e) 送出的 **CR 後面要補 NUL**（RFC 854），不然有些 server 的 Enter 時靈時不靈。
36. **測試 server 自己是壞的，看起來卻像 client 壞掉** — TTYPE 一直測不過，
    原因是我的測試 server **只送 `DO TTYPE` 就等**，從來沒送
    `SB TTYPE SEND`；client 是對的。
37. **測試會吃到別的測試留下的資料** — telnet 測試 server 的 log 是**整個行程共用、
    一直 append**，所以某個 assert 可能是被**上一個測試**的內容滿足的。
    每個測試開始前先清空。另外「server 有沒有在跑」原本是看 **log 檔在不在**——
    log 活得比 server 久，於是舊 log 會讓測試對著空氣跑，表現出來就是**時好時壞**。
    改成**真的去 connect 那個 port**。
38. **`DispatchQueue.global()` 存檔會亂序（真的 bug，不是測試問題）** —
    `KnownHostsStore` 每次變更都 async 寫檔，用的是**並行** queue：
    兩次接連的儲存**完成順序不保證**，檔案有可能停在**比較舊**的那份快照。
    對信任儲存來說就是「剛 Forget 掉的主機又回來了」。改成專用的**序列** queue。
    這是測試逼出來的——先是偶發，把測試的等待條件收緊之後才變成穩定重現。
39. **Mosh 用內附的 mosh-client 子行程，不是自己寫 SSP** — mosh 沒有 library API，
    而且 SSP 加上 AES-OCB 是它的核心；自己用 Swift 重寫等於**做一份沒人審過的
    安全協定實作**。所以編成獨立執行檔、掛在 PTY 上跑。
    ⚠️ **GPLv3**：以**獨立行程**執行（不是連結進來），並隨 app 附上 COPYING
    與書面 source offer。`make-app.sh` 也會**另外簽名** mosh-client——
    它是 bundle 裡的第二個 Mach-O，沒簽的話 `--verify --strict` 會失敗、公證也不會過。
40. **protobuf 版本要釘 21.x** — mosh 1.4.0 用的是 Abseil 之前的 protobuf C++ API，
    22 以後編不過。另外 mosh 的 configure 找不到 pkg-config 時，
    可以直接給 `protobuf_CFLAGS` / `protobuf_LIBS` 跳過——
    這樣建置機器不必為了找一個我們自己編的函式庫而去裝 pkg-config。
41. **`LocalProcess.delegate` 是 weak（真的踩到）** — 我把 delegate 建成
    **區域變數**，init 一結束就被釋放，於是 mosh-client **行程有在跑、
    畫面卻一片空白**——callback 從來沒被呼叫。
    我當初把 delegate 拆成獨立物件是為了避免循環參考，
    但 LocalProcess 本來就持弱參考，**根本沒有循環**，反而造成懸空。改成自己持有。
42. **測試容器佔用 2222，把別人的測試從 skip 變成 fail** — `OpenSSHInteropTests`
    用 127.0.0.1:2222 當它自己的 sshd，沒有就 skip。我的 mosh 容器一開在 2222，
    那些測試就「找得到 server、但帳號不對」→ 變成失敗。
    容器改到 **2223**。教訓：測試用的 port 也是共用資源。
43. **匯出的預設值就是安全策略** — 「要不要帶密碼」和「要不要加密」**不是兩個選項**：
    帶密碼就一定加密，沒有「明碼但含密碼」這條路——一個看得懂的檔案裝滿憑證，
    最後就是躺在 Downloads 或聊天室裡。另外 strip 不能只清 `password`，
    **`passphrase` 和 `keyData`（內嵌私鑰）也要清**；`keyPath` 保留，
    那是路徑不是秘密，而且留著才能在已經有金鑰的機器上直接用。
    帶密碼的匯出檔另外設 **0600**。
44. **欄位全都 optional 的格式，`{}` 也會解得出來** — 為了讓舊檔還能讀，
    每個欄位都用 `decodeIfPresent`，結果**空的 JSON 物件變成一份合法的空 archive**，
    匯入等於什麼 JSON 都收。加一個 `macmoba: "session-export"` 標記做正向辨識。
    （測試抓到的：我本來只檢查 `version > 0`，但 version 也有預設值。）
45. **`NSStackView` 會把用 frame 設定的子視圖壓扁** — NSAlert 的 accessoryView 裡放
    兩個 `NSSecureTextField`，用 NSStackView 排出來變成**兩條細縫**（它是走 auto layout 的）。
    改成普通 `NSView` 容器自己排 frame。
46. **重排的落點跟拖曳方向有關** — 先把被拖的項目移除，**後面的東西就整個左移一格**，
    所以移除前量到的 index 不能直接拿來插入。而且往右拖要落在目標**右邊**、
    往左拖落在**左邊**，不然感覺就不是「放到我指的地方」。
    邏輯抽成 `ListReorder`（放 MacMobaCore）才測得到——`WindowState` 在 app target。
    測試裡有一項是**窮舉所有 from×to 組合，確認數量和內容都沒變**：
    重排弄丟一個分頁 = 弄丟一條連線。
    重排本身只重建陣列、不碰 tab 物件，所以連線／pane／scrollback 都不受影響（已實測）。
47. **多螢幕：macOS 和 RDP 的 y 軸方向相反** — macOS 原點在主螢幕**左下**、y 往上；
    RDP 原點在主螢幕**左上**、y 往下。所以實體位置在主螢幕**上面**的螢幕，
    macOS 是正 y、RDP 要是**負** y。搞錯的話**layout 仍然合法、server 也會收**，
    只是視窗跑到錯的螢幕上——所以這段一定要有測試。
    另一個容易錯的：macOS 是用**下緣**對齊，兩個高度不同的螢幕即使都在 y=0，
    **上緣也不一樣高**（1080 vs 1024 差 56）。我自己第一版測試就寫錯了，
    是測試把我糾正回來，不是程式錯。
    做法：`RDPContainerView` 加 `sourceRect`（要顯示 framebuffer 的哪一塊），
    每個非主螢幕開一個 borderless 視窗、各自 crop；**滑鼠座標要加回自己的 offset**，
    不然每個視窗都會把點擊當成主螢幕上的座標。
    只在**全螢幕**時鋪開，離開就收回分頁。
    ⚠️ **只有一個螢幕時 `currentMonitors()` 回空陣列 → 完全退回單螢幕路徑**，
    已在真 AD server 上確認沒有回歸（log 裡不會出現 multi-monitor）。
    ⚠️ **多螢幕本身在這台驗不了**（走螢幕共享，只有一個螢幕）。
48. **使用者在 MBA 上實測多螢幕：連不上（真的 bug，log 直接指出來）** —
    送出的 layout 是
    `[0] primary {0x0-3840x2160} scale 100` / `[1] {2180x4320-3420x2224} scale 200`，
    FreeRDP 回 **`Monitor configuration has gaps!`** 然後**整個連線被拒**。
    原因：我把每個螢幕的**位移**乘上**它自己的** scale。2x 的筆電螢幕位移就被放大一倍，
    第二個螢幕跑到 y=4320，可是主螢幕只有 2160 高 → 中間開了一個大洞。
    **根本問題**：macOS 用 **點** 排列螢幕，RDP 要的是**不能有空隙的像素格**；
    混合 DPI（2x 筆電 + 1x 外接）時，**根本不存在**一個 scale 能把點座標映射成
    無縫的像素座標。
    修法：**scale 全部相同**時照原本的幾何換算（精確）；**混合 DPI** 時改成
    **貼齊排列**——保留每個螢幕在主螢幕的哪一側，但直接靠著排、不留空隙。
    空間位置變成近似的，但**近似的能連、精確的連不上**。
    另外補上 `hasGaps()` 在**送出前**自己驗一次：驗不過就回空陣列 →
    **退回單螢幕**，而不是讓連線整個失敗。
49. **我自己的舊測試把 bug 寫成了預期值** — `testMixedScaleOffsetsAreInPixelsToo`
    斷言 `secondary.x == 1512`，正是「用第二個螢幕的 scale 去乘位移」的結果。
    主螢幕是 1512pt @2x＝**3024 像素寬**，鄰居就該從 3024 開始。
    修完之後這個測試才「壞掉」——它一直在保護那個 bug。
50. **多螢幕連上了，但視窗模式下整片桌面被塞進一個分頁裡** — 使用者回報的畫面：
    分頁標題 `AD 3840×4384`（＝上下疊起來，2160+2224），**兩個螢幕的內容全部
    letterbox 進同一個 pane**，左右一大片黑，什麼都不好用。
    這是我當初的設計錯誤：離開全螢幕時把 `sourceRect` 設回 `nil`（整片桌面）。
    改成**永遠只顯示主螢幕那一塊**，其他螢幕的內容只在全螢幕時才出現在自己的視窗上。
    這樣「有開 Use all displays 的 session」在視窗模式下看起來就跟一般 session 一樣。
51. **全螢幕之後第二個螢幕是全黑（使用者實測回報）** — 三個各自獨立的原因：
    (a) **新開的 view 從來沒被餵過畫面**。`show()` 只建立 view，然後等下一張 frame。
        Windows 桌面沒在動的時候，server 可能很久都不送新的 frame ——
        看起來就跟功能壞掉一模一樣。改成把**最後一張 frame** 直接塞進去。
    (b) **monitor 和 NSScreen 用位置配對，但 monitor 陣列是排序過的**（主螢幕排最前），
        兩者順序根本不一致。我自己在註解裡還寫「順序一定一樣」——**那句是錯的**。
        改成在 `RDPMonitor` 存 `screenIndex`，明確對應回原本的螢幕。
    (c) **視窗在全螢幕動畫「之前」就建立**。macOS 進全螢幕會把主視窗搬到自己的
        Space，先建好的浮動視窗會被蓋掉或留在別的 Space。
        改成監聽 **`didEnterFullScreenNotification`** 之後才開。
52. **我假設 MacMoba 視窗一定在主螢幕上——它不一定**（使用者實測回報：
    「在第二個螢幕跑 MacMoba，進全螢幕後那個螢幕全黑，第一個螢幕什麼都沒發生」）。
    因為程式是這樣分工的：**分頁自己的 view 顯示主螢幕那塊**、
    **其他「非主螢幕」各開一個視窗**。當視窗本身就在第二個螢幕時：
    (a) 全螢幕的主視窗顯示的是**主螢幕**的內容（不是它所在螢幕的）；
    (b) 「非主螢幕」＝第二個螢幕＝**主視窗自己所在的螢幕**，於是又蓋了一個
        borderless 視窗**壓在自己身上**；
    (c) 第一個螢幕**從來沒有被分配到視窗**，所以完全沒反應。
    改成一切以「**視窗實際在哪個螢幕**」（`hostScreenIndex`）為準：
    那個螢幕留給分頁自己的 view，**其餘每個螢幕**各開一個視窗。
    測試涵蓋「不論視窗在哪個螢幕，每個螢幕都剛好被覆蓋一次」。
53. **要的桌面解析度不該超過「MacMoba 所在那個螢幕」的解析度**（使用者要求）—
    超過的部分是純浪費：畫面本來就要縮小塞進 pane，多要的像素會被丟掉，
    只換來字更小＋更多頻寬。現在依 **視窗實際所在螢幕** 的像素解析度上限來夾。
    兩個地方會超過：**fixed size**（使用者手打，本來完全沒被檢查過）、
    以及 Retina 乘 scale 之後的 fit-to-window。
    ⚠️ **跨螢幕（Use all displays）刻意不夾**——超過單一螢幕正是它的用途。
    夾完仍要維持合法（寬度 4 的倍數、不低於 640×480），有測試涵蓋。
54. **全螢幕時一個螢幕正常、另一個全黑——真正的根因**（使用者第四次回報，
    附截圖：MacMoba 視窗本身整片黑，只剩 toolbar）。前面 51/52 修掉的都是真的
    bug，但都不是這個。真正的原因在**連線之後**：
    - `usesAllDisplays` 必須是 `.fitWindow`（見 `Vault.swift`），所以跨螢幕 session
      一定會拿到 `/dynamic-resolution`，`macmoba_rdp_can_resize()` 也一定是 true。
    - 連上的當下 `handleState(CONNECTED)` 就呼叫 `requestResize(container.bounds)`，
      而 `macmoba_rdp_request_resize()` 送的 `SendMonitorLayout(disp, 1, &layout)`
      **只有一個矩形、在原點**。伺服器照做 → 桌面從 3840×4384 縮成一個 pane，
      **multimon 直接被打回單螢幕**。
    - 縮完之後，offset 不是 0 的那台螢幕（例如上下排列時 y=2160 的那台）整個
      落在 framebuffer 外面，`displayedImage` 的 intersection 是空的 → 回 nil
      → **全黑**。offset 0 的那台還在範圍內 → 「一個正常一個黑」。
    修法三層：`RDPResizePolicy.allowsDynamicResize()` 讓跨螢幕 session 既不送
    resize 也不再宣告 `/dynamic-resolution`；C 端在 `UseMultimon` 為真時直接拒收
    並寫 log（其他呼叫者的保險）；`visibleSlice()` 在切片完全落在畫面外時改回
    整張 frame——**寧可畫面比例錯也不要黑畫面**，黑畫面跟 session 死掉長得一樣。
    另外 `display-control resize to WxH` 現在會寫進 MacMoba-RDP.log，下次同類
    問題可以直接從 log 看出有沒有送出去。
55. **視窗在內建螢幕，畫面卻是外接螢幕那一塊**（使用者回報「detect wrong
    resolution」，附截圖：分頁標題 AD 3840×4384，pane 裡是 16:9 的桌面）。
    不是解析度偵測錯，是**切片挑錯螢幕**：`showPrimarySliceOnly()` 永遠拿
    primary（外接 3840×2160）的那一塊，跟視窗實際在哪台完全無關。跟 #52 同一
    個假設，只是這次出現在視窗模式的路徑上。
    順帶挖出更深的一層：螢幕原本是用 **`NSScreen.screens` 的索引** 配對的，而拔掉
    一台螢幕會讓整個陣列重新編號——連線時記下的 index 之後會指到另一台實體螢幕。
    現在 `RDPMonitor` 帶 `displayID`（`NSScreenNumber`），`RDPMonitorLayout.monitor(in:
    displayID:screenIndex:)` **先比身分再比位置**；layout 裡全部沒有 ID 時才退回
    index。配不到就回 nil → 顯示整個桌面，不會拿到別台的切片。
    另外現在會跟著跑：`NSWindow.didChangeScreenNotification`（視窗被拖到另一台）
    和 `NSApplication.didChangeScreenParametersNotification`（插拔螢幕）都會重新
    切片、重新擺跨螢幕視窗。
    ⚠️ 已連線的 session 桌面大小不會跟著變（multimon 不能只送一個矩形，見 #54），
    螢幕組合真的變了要重連才會重新談。
56. **「Use all displays」在連線當下就跨螢幕，視窗模式因此永遠是錯的解析度**
    （使用者第三次回報解析度不對）。`rdpUseAllDisplays` 的註解一直寫著「只在全螢幕
    生效」，但實作是**連線時**就把 multimon 談進去，所以一個 1000×700 的視窗拿到
    3840×4384 的桌面。#55 修的是切片挑錯螢幕，但桌面本身就不該是那個大小。
    現在：**連線一律單螢幕**（依視窗所在螢幕，走 #53 的上限），跨螢幕改成進全螢幕
    時用 display-control 動態送出**多顆 monitor 的 layout**
    （`macmoba_rdp_send_monitor_layout()`，`SendMonitorLayout(disp, N, …)`，
    N 受伺服器 caps `MaxNumMonitors` 限制，會寫進 log）；離開全螢幕再送回單顆。
    ⚠️ **舊伺服器只認連線時的 layout**（本機 xrdp 就完全不開 disp channel）。
    這種情況會 fallback 成「帶 layout 重連」——Windows session 本身還在，重連回去
    東西都在。`connectSpanning` 只允許一次，否則會無限重連。
    另外 `framebufferRect(of:in:)`：RDP 的 primary 在 (0,0)，**在它上面/左邊的螢幕
    座標是負的**，但 framebuffer 沒有負座標（原點是整個 bounding box 的左上）。
    筆電上面架一台外接螢幕就是這個情形——直接拿原座標切，外接那塊 crop 完是空的
    （黑畫面），筆電那塊會切到外接的畫面。現在一律扣掉 minX/minY。
57. **全螢幕跨螢幕時，macOS 的 Dock 蓋在 Windows 工作列上面**（使用者實機回報）。
    跨螢幕視窗用的是 `.floating`＝**level 3**，而 Dock 是 20、選單列是 24，所以
    Dock 一直畫在遠端桌面之上——偏偏 Dock 在螢幕底部，蓋到的正好是 Windows 工作列，
    兩邊都不能用。改成 `.screenSaver`（1000）。
    本機實測（單螢幕、拿同樣參數的 borderless 視窗＋截圖比對像素）：
    `.floating` 時 Dock 區域是 (245,78,255)、畫面中央是 (234,51,247)，差值就是 Dock
    的毛玻璃疊上來；`.screenSaver` 時 Dock 區域與中央**完全同色** → 上面沒東西了。
    ⚠️ 蓋掉 Dock/選單列只在 MacMoba 是前景 app 時才可接受：現在監聽
    `didResignActive` / `didBecomeActive`，切到別的 app 就把 level 降回 `.normal`，
    回來再升上去。否則 ⌘-Tab 到瀏覽器會發現整台機器被蓋住。
58. **reconnect 之後剪貼簿噴 `cliprdr_packet_format_list_new failed!`**（使用者早先
    回報，這輪查到根因並實機重現）。讀 FreeRDP 3.30.0 原始碼確認：
    短名模式下 format name 欄位只有 15 個字元，而 `"FileGroupDescriptorW"` 有 20 個，
    `Stream_Write_UTF16_String_From_UTF8()` 回負值 → `goto fail`。
    而 `useLongFormatNames` **要等 server 的 capability PDU 才會變 true**
    （`cliprdr_main.c:169`），但 `rdp->cliprdr` 在 **channel connect 當下**就有了，
    pasteboard 輪詢又是連上就開始跑——中間那段窗口送出去的 format list 必掛。
    **reconnect 才明顯**是因為那時 Mac 剪貼簿早就有東西，第一次輪詢就有檔案要 offer。
    修法：`clipboardReady`（等 MonitorReady 才准 advertise）＋ 記下 server 有沒有
    同意 long format names（`ServerCapabilities` callback），沒同意就不 offer 檔案。
    **實機重現**：本機 xrdp，把輪詢間隔暫時改成 0.02s 把窗口撐開 →
    舊行為 2 次 `cliprdr_packet_format_list_new failed!`（attach 後 8ms）；
    改完同樣條件 **0 次**。測完把 0.75s 改回來。
59. **SFTP 面板顯示的是「分頁最初那個 session」，不是「你現在在打字的那個 pane」**
    （使用者問：MultiExec 開著的時候 SFTP 面板算誰的？）。
    `sftpBrowser()` 是拿 `self.config` 建的——那只是分頁**被開起來時**的 session。
    分割到另一台機器之後，面板還在列第一台的檔案，畫面上完全沒有東西講這件事；
    廣播輸入開著的時候最危險：兩台機器一起被打字，但 **Upload 只會上傳到其中一台**。
    現在：**跟著 focus 的 pane 走**（每台機器各自一個 SFTP 連線，快取起來，
    來回切不會重連），面板頂端在「分頁裡有兩台以上機器」時會標出
    `Session名 · user@host`。
    實測（兩個 node SFTP server，HOME 各放一個獨有檔案）：focus 左邊 pane →
    `ONLY-ON-BRAVO.txt` 且標籤 `Bravo · test@127.0.0.1`；focus 右邊 → `ONLY-ON-ALPHA.txt`
    且標籤 `Alpha · …`。
60. **FTP：兩條連線的協定，難的地方全在文字上**。`FTPProtocol` 把解析拆出來單測
    （30 項）：多行回覆**只能被「同一個 code + 空白」結束**（banner 裡出現
    `230 ...` 不算，否則控制連線從此對不上）、PASV 的六個數字要**丟掉開頭的狀態碼**、
    EPSV 的分隔字元不一定是 `|`、MLSD 的 name 是**第一個空白之後全部**（名字裡可以有
    空白和分號）、cdir/pdir 要濾掉、Unix LIST 的年份省略時**比現在晚一天以上的日期
    屬於去年**（否則每年一月看十二月的檔案都變成未來）。
    連線層用 Network.framework（不必多拉依賴，TLS 是內建的）。
    **實機第一次跑就抓到一個真 bug**：`isComplete` 有可能**跟最後一塊資料一起**送來，
    我只看了資料就丟掉旗標，下一次 receive 撞到已關閉的連線 →
    `NWError 96 (No message available on STREAM)`，症狀是列目錄隨機失敗。
    現在把旗標記起來，下一次直接回 nil。
    ⚠️ 另外兩件事是刻意的：**passive-only**（active 模式要伺服器回連，
    二十年來沒有一台家用路由器允許）、**PASV 回報的位址一律忽略**，改用控制連線
    的 host——NAT 後面的伺服器會報自己的私有位址，照著連會連到自己網段的別台機器。
    **jump host 直接擋掉**：passive 每次傳輸都要一條「伺服器臨時挑的埠」的新連線，
    一個 forward 不夠，與其看起來能用然後卡住，不如講清楚。
61. **雙欄傳輸：覆蓋確認是整個功能最容易寫錯的地方**。做成 `TransferPlan` 這個
    狀態機（不碰 UI、不碰 socket）：`nextStep()` 回 transfer / ask / finished，
    `answer()` 收 Replace / Skip / Replace All / Skip All / Cancel。
    **單元測試先抓到一個真 bug**：回答 Replace 之後，我只把 index 往前推，
    那個「剛剛被批准」的檔案就被跳過去了——permission 給了卻沒寫。
    現在多一個 `approved` 欄位，答完的那件事會被明確交回來。
    其他被測試釘住的規則：「套用到全部」只影響**還沒處理的**（先前個別 Skip 掉的
    不會被追溯改成 Replace）、沒衝突的檔案在 Skip All 之下**照樣要傳**、
    alert 被連點兩下不能把下一個檔案的答案吃掉、Esc 等同 Cancel（否則傳輸會
    永遠等一個不會來的答案）。
    本機那一側也走 `RemoteFileService`（`LocalFileService`），所以兩欄是同一個
    pane view、同一套選取模型，「上傳」就只是從一個 service 複製到另一個。
    ⚠️ 選取用**檔名不是 index**：列表會重排重載，index 會悄悄指到別的檔案；
    重新載入之後還會把選取跟現有檔名取交集。
62. **排序：預設方向要跟著鍵走**。`FileSort`（14 項測試）：名稱用
    `localizedStandardCompare`（Finder 那套，會看數字，所以 file2 在 file10 前面）；
    **選日期或大小時預設是「新的／大的在前」**——沒有人排日期是為了看最舊的那個。
    幾個被測試釘住的點：伺服器沒回時間的檔案在「最新在前」時要沉到最後而不是浮到
    最上面；資料夾的 size 在 SFTP 是 block 數不是內容大小，所以照名字排；
    **排序必須是全序**（同大小的兩個檔案以名稱決勝負），否則每次重新整理列表會
    自己重排、看起來像選取跳到別行。
63. **雙欄的單擊選取時好時壞**（使用者回報）。row 上掛了 `.onTapGesture`，
    它會跟 List 自己的點擊處理**互搶**——有時 List 收到（有選取），有時被手勢吃掉
    （沒反應）。改成 `.simultaneousGesture(TapGesture(count: 2))`：List 照樣收到
    每一次點擊（選取、⌘-click、⇧-click 都正常），雙擊進資料夾同時也認得。
64. **雙欄同步（Sync →／←）**：比對兩邊的目錄樹，把缺的、大小不同的、或這一側比較新的
    複製過去，**遞迴**、**不刪除任何東西**。
    `SyncPlanner`（15 項測試）最重要的是 **2 秒容差**：SFTP 的 mtime 只有整秒，本機檔案
    有小數秒，兩台機器的時鐘也不會完全對齊——沒有容差的話同一個沒動過的檔案每次都會
    被判定「比較新」而重傳一次，永遠停不下來。
    其他規則：同大小但這邊比較舊 → 不覆蓋（那是靜悄悄的降版）；大小不同但對面比較新
    → 還是傳，但**確認視窗會告訴你有幾個會蓋掉更新的檔案**；一邊是檔案一邊是同名資料夾
    → 跳過並回報，不猜。
    實機驗證（真 SFTP server）：跑完第一次複製 2 個項目，**第二次複製 0 個**——
    這是 sync 跟「複製」的唯一差別，也是最容易寫壞的地方。
65. **開啟 .rdp 檔（CyberArk PSM）**。File ▸ Open RDP File…（⌘O），也可以在 Finder
    直接雙擊（Info.plist 加了 `CFBundleDocumentTypes`，`LSHandlerRank` 用 Alternate，
    不搶 Microsoft Remote Desktop 的預設）。
    **拿使用者真的那個 PSM 檔驗過**，而且它推翻了我原本的假設：
    - **port 是獨立的 `server port:i:` 這個 key**，不是塞在 `full address` 裡。
      只從 address 取的話會剛好連對 3389，但 PSM 換 port 就整個錯。
    - `username:s:localhost\PSM@<guid>` — token 在 username 裡，`\` 前面是 domain。
    - `alternate shell:s:PSM@<guid>` — **PSM 的路由在這裡**，丟掉的話會連上跳板然後
      停在那裡。現在會經由 FreeRDP 的 `/shell:` 送出去（C 那層多一個參數）。
    - `EnableCredSspSupport:i:0` → 不要強上 NLA，對應成 TLS。
    編碼那關也有陷阱：Windows 通常寫 UTF-16LE，而 **UTF-16 的 ASCII 位元組本身是
    合法的 UTF-8**（NUL 是合法字元），所以先試 UTF-8 會「成功」但拿到一串塞滿 NUL 的
    字串、什麼都解析不出來——要先看有沒有 NUL 再決定。（使用者這個檔案反而是 UTF-8。）
    DPAPI 加密的 `password 51:b:` **不會裝作沒看到**：會明講那是綁在原本那台 Windows
    上的、這裡解不開，然後跟使用者要密碼。RD Gateway、RemoteApp、loadbalanceinfo
    也都會逐項講清楚做不到什麼。
    ⚠️ **預設不存進 vault**：PSM 這種檔案是一次性簽發的，預設是「連一次」，
    要留下來得自己按 Save Session。
66. **空密碼被我們自己擋掉，連 TLS 都握不完**（使用者的 PSM 連不上，log 只有
    `transport_connect_tls: ERRCONNECT_CONNECT_CANCELLED`，180ms 就結束）。
    `mm_authenticate` 原本要求 **user 和 password 都非空** 才肯把憑證交出去，
    否則回 FALSE → 連線在握手中途被中止。
    **空密碼是一個憑證，不是「沒有憑證」**——而 CyberArk PSM 的 .rdp 正好是
    「username 帶一次性 token、完全沒有密碼」。該不該接受空密碼是**伺服器**要決定的，
    我們擋在前面只會得到一個看起來像網路故障的 cancelled。
    現在只有「連 user name 都沒有」才提前失敗；密碼一律照送（空的也送），
    log 會寫 `supplying credentials for … (password set/EMPTY)`。
    **查法值得記**：先寫一支 X.224 negotiation probe 直接問伺服器接受哪些安全模式
    （TLS / CredSSP / RDP 全都 SELECTED，所以不是協定挑錯）；再用 **假的 user name**
    直連（避免燒掉使用者那張一次性 token），拿到的 state 訊息
    `This server requires a username and password.` 就是我們自己印的，一眼定位。
    regression test 用本機 xrdp 容器（空密碼要能走到憑證那一步），
    **確認過改回舊碼會失敗**。
67. **雙欄面板的單擊選取根本不會作用——兇手是 row 上的手勢**（使用者回報兩次，
    我第一次「修」錯了）。第一次我把 `.onTapGesture(count: 2)` 換成
    `.simultaneousGesture(...)`，以為這樣 List 就收得到點擊——**沒有用**。
    這次實際量：**帶手勢時點 5 次，選中 0 次；把手勢拿掉，5 次全中**。
    macOS 上 `List(selection:)` 底層是 NSOutlineView，**任何 SwiftUI 手勢掛在 row 上
    都會把它要用的點擊吃掉**，`simultaneousGesture` 也一樣。
    改法：進資料夾改用 **Button（一個 chevron）**——Button 是控制項，只吃自己那一小塊，
    其餘整列還是 List 的。實測：單擊選取 6/6、⇧-click 多選顯示「3 selected」、
    點 chevron 真的進到 afolder（路徑與列表都變了）。
    ⚠️ 單欄的 SFTP 面板**不受影響**：它根本沒用 List 的 selection，是自己管
    `model.selection` 並自己畫底色，所以兩個 tap gesture 都是它自己的。
68. **雙欄面板改用真的 NSTableView（右鍵選單／改名／刪除／雙擊進資料夾）**。
    使用者要右鍵選單，同時要把雙擊進資料夾加回來——而這兩件事加上單擊選取，
    在 SwiftUI 的 List 上**湊不齊**（見 #67：手勢會把 List 要用的點擊吃掉）。
    答案其實就在專案裡：單欄的 SFTP 面板早就是 `NSViewRepresentable` 包 NSTableView，
    所以它的雙擊、選取、右鍵選單一直都好好的。雙欄照做一份
    （`TransferFileTable`，多選打開）。
    右鍵的作用對象照 macOS 慣例：**點在已選取的項目上 → 整批；點在別的地方 → 只有那一個**。
    改名先過 `FileNameCheck`（10 項測試）：空字串、`.`/`..`、含 `/`（那是移動不是改名）、
    控制字元與 NUL（NUL 會截斷 C 字串，送出去的名字跟打的不一樣）、超過 255、
    以及同資料夾撞名；前後空白只 trim 不報錯。
    刪除**本機走 Trash、遠端是永久**，確認視窗會照實講，資料夾還會講「連同裡面的東西」。
    實測（合成點擊＋進伺服器檔案系統對答案）：單擊選取 6/6、⇧-click「3 selected」、
    雙擊進 afolder（列表出現 inner.txt）、右鍵改名 `aaa.txt` → `renamed-by-menu.txt`、
    右鍵刪除 `bbb.txt` 之後**伺服器上真的沒了**。
69. **Duplicate（複製既有 session）**（使用者要求：改名字和 IP，其他全留著）。
    右鍵選單多一項 Duplicate：**除了 id 和名字，其餘全部照抄**——username、port、
    password、金鑰、passphrase、group、jump host、domain、RDP/FTP 各自的設定。
    id 一定要換：**兩個 session 共用一個 id，對 vault、開著的分頁、以及把它當跳板的
    設定來說就是同一個 session**。
    命名 `web-server` → `web-server copy` → `copy 2` → `copy 3`；**複製「copy」不會疊字**
    （不會變成 copy copy），但名字裡本來就有 copy 的（例如 `copy machine`）不會被吃掉。
    做完直接開編輯器，讓使用者改名字/IP；副本在開編輯器前就已經存檔（Finder 的
    Duplicate 也是這樣），取消編輯不會把它弄丟。
    實測：右鍵有 Duplicate、清單出現 `web-server copy` 且在同一個群組、編輯器帶著
    原本的 host/port/username/group，**解開磁碟上的 vault 對答案**：password、domain、
    rdpSecurity 都在，id 是新的。
70. **5 個 pane 變成「一個大的＋四條縫」**（使用者回報，附圖）。
    連續分割同一個 pane 會長成**右傾的樹**：`split(A, split(B, split(C, split(D, E))))`。
    每一層各自把自己那塊對半分，於是 A 拿一半、B 四分之一、C 八分之一——
    正好就是截圖上 50/25/12.5/6.25/6.25。
    原本 `layoutGeneration` 的「重設成 50/50」沒有錯，**錯在「50/50」對一串巢狀的
    二分樹來說本來就不是平均**。
    改法：畫的時候把**同一個軸向**的分割**攤平成一個容器的 N 個兄弟**
    （`SplitLayout.siblings`，9 項測試），NSSplitView 本來就吃任意數量的 subview；
    另一個軸向的分割仍然是單一個 child，輪到它自己畫的時候再攤平自己那層。
    分隔線位置由 `evenDividerPositions` 算，**每一條都要把它前面那些分隔線的厚度算進去**，
    否則越往下誤差越大。
    實測（開 5 個 pane 後截圖、量中間那條垂直線上的黑色區段）：
    **244/244/244/244/236 px**（差 3.3%，就是邊緣捨入）；關掉一個之後
    **306/305/306/297**——**加或關都會重新平均**。
71. **MultiExec 可以挑要送給哪些 pane**（使用者要求）。原本是全有全無：所有連上的
    pane 一起收。現在每個 pane 有自己的開關，工具列多一個 checklist 選單
    （All／None／逐一勾選），**預設全開**，所以不動它的話跟以前一樣。
    最容易寫錯的一條規則寫在 `BroadcastPolicy`（10 項測試）：
    **在「被排除的」pane 裡打字，那個 pane 自己一定要收到**——否則那個終端機看起來
    就是不理你。但這個例外只適用「你正在打字的那一個」，不會外溢到其他被排除的。
    另外斷線的 pane 永遠不寫（沒有東西可寫），但**仍然留在清單裡**，這樣重連之後
    你之前的選擇還在。
    被排除的 pane 右上角會出現一個橘色圖示（只在 broadcast 開著時），點一下就加回來。
    實測（改 node 測試伺服器記下**每個 shell 實際收到什麼**，MM_RX_LOG）：
    broadcast 關 → 只有 shell3 收到；開 → shell1/2/3 都收到；
    排除中間那個 → 只有 shell1/shell3；**在被排除的那個裡打字 → 三個都收到**；
    再回到最上面那個打字 → 又剩 shell1/shell3。
72. **MultiExec 的選擇改到每個 pane 上，並且按下去會自動排版**（使用者要求：
    「不要在上面的選單設定」「按下 multi execution 時自動排」）。
    - 工具列的 checklist 選單拿掉了。改成**每個 pane 右上角一個徽章**，
      **藍色＝有收、橘色＝沒收**，點一下切換；被排除的 pane 整片壓暗，邊框也變橘色，
      一眼就看得出來哪幾台在收。**綠色是「游標在這裡」**（focus），畫在藍框內側，
      所以「正在打字的那一個」和「會收到的那些」可以同時看出來。
      （顏色是使用者指定的：focus 綠、broadcast 藍。實測用像素取樣確認過，
      有焦點的 pane 外圈 (0.16,0.37,0.68) 藍、內圈 (0.32,0.62,0.33) 綠。）
    - **踩到的坑：`dot.radiowaves.left.and.right.slash` 這個 SF Symbol 根本不存在**，
      所以「被排除」的徽章畫出來是空的（symbol 不存在時 SwiftUI 就是什麼都不畫）。
      用 `NSImage(systemSymbolName:)` 一個一個試出來，改用 `antenna.` 那一組。
    - 另一個坑：壓暗的那層蓋在徽章上面（SwiftUI 後面的 overlay 畫在上面），
      結果**要把 pane 加回來的那顆按鈕自己被壓暗了**。壓暗要放在徽章前面。
    - 按下 MultiExec 時：把這個視窗裡**所有終端機分頁併成一個分頁**，然後排成
      **格狀**（`GridLayout`，7 項測試）：2 個就左右，3 個以上就同時有欄和列，
      欄數取 `ceil(sqrt(n))`（螢幕是寬的，所以 5 個是 3 欄不是 2 欄），
      每欄的數量差不超過 1。
    ⚠️ 第一版排成 `ceil(sqrt(n))` 欄（5 個 → 3 欄），使用者看了說**要每列 2 個**，
    第 5 個自己一列。改成 **rows of 2**：終端機要的是寬度（80 欄字），
    三個窄欄比兩個寬欄難用，第 5 個應該往下開一列而不是被拉成整條側邊。
    最後一列只有一個時，使用者要它**跟上面一樣寬**，而不是橫跨整個視窗。
    所以 Node 多一個 `case empty`：補在短的那一列旁邊佔位。
    ⚠️ 這個佔位格**只有在旁邊那個 pane 還在的時候才有意義**——`removing()` 對 `.empty`
    一律回 nil，否則關掉那個 pane 之後會剩一塊誰也關不掉的灰色方塊。
    實測：開 5 個分頁 → 按 MultiExec → **2 欄各 910 寬、3 列 400/400/392 高**，
    第 3 列那個終端機寬度 912（跟上面一樣），右邊是灰色空格；
    打一個字 **shell1~shell5 全部收到**；把第 3 列那個關掉之後，
    **空格也跟著消失**，變回乾淨的 2×2。
73. **併分頁一定要有回頭路**（使用者：「how to go back to one session one tab」）。
    我原本把「按 MultiExec 併分頁」做成單向的，還在說明裡輕描淡寫寫了一句
    「⚠️ 是單向的」——**這是設計錯誤，不是限制**：使用者被困在一個出不去的版面裡。
    現在：**關掉 MultiExec 會把它併進來的 pane 一個一個還回各自的分頁**，
    另外 File ▸ Move Panes to Separate Tabs 也可以隨時手動拆開。
    只還「它自己併進來的那些」（`gatheredPaneIDs` 記著），使用者自己分割出來的 pane
    不會被動到。
    拆開走的是 `SessionTab(adopting:)` + `detach()`：**pane 是被領養的，不是重連的**，
    連線和 scrollback 都留著。
    實測：3 個分頁 → 按 MultiExec 併成 1 個 → 再按一次 → **又回到 3 個分頁**，
    三個都還是綠燈、畫面上原本的 scrollback 還在。
74. **SFTP 不走 jump host（使用者回報：終端機連得上，檔案瀏覽器一直卡在 Connecting…）**。
    `SSHConnection.connect()` 有 `jump` 參數、會先連跳板再用 direct-tcpip 接目標；
    但 **`SFTPClient.connect()` 只吃 config，直接 `connectParent` 打目標**——
    它根本沒有辦法知道跳板是誰（`jumpSession(for:)` 住在 AppState）。
    所以在「只有跳板連得到目標」的網路上，同一個 session 的終端機正常、
    旁邊的檔案瀏覽器就永遠轉圈圈。
    修法：`SFTPClient.connect(config:via:hostKeys:)`，跟終端機同一條路；
    單欄瀏覽器和雙欄傳輸都把 `app.jumpSession(for:)` 傳進去。
    ⚠️ 跳板的 channel 要**跟著 session 一起關**（存成 `jumpChannel`），
    否則每開一次檔案瀏覽器就多留一條到跳板的連線。
    實測（兩台測試伺服器：跳板 2406、目標 2407，目標的 HOME 放一個獨有檔案）：
    列出來的是**目標的**檔案、下載內容正確、而且在跳板上記錄 direct-tcpip 轉發，
    log 顯示 **`forward:127.0.0.1:2407` 三次**（三個測試各一次）——
    確定流量真的是穿過跳板，不是剛好本機兩個 port 都通。
    ⚠️ FTP 仍然不支援 jump host（passive 模式每次傳輸都要新連線，見 #56）。
75. **併分頁／拆分頁來回幾次之後，有一個 pane 變成整片空白**（使用者回報，
    截圖：分頁標題 ▦5、五個 pane 都在、邊框和徽章都正常，**但 VM1 那格什麼都沒有**）。
    我在這台機器上**重現不出來**（試過：5 個 pane、開關三輪、先排除一個再開關、
    先讓終端機有內容再開關），所以是照著症狀往回推機制——
    `PaneContainerView` **只在 `init` 裡 `addSubview(termView)`**，而
    `updateNSView` 是空的。
    一個 pane 的 `TerminalView` 是**唯一一個 AppKit view**；重建 split tree
    （併分頁、拆分頁、tile、關 pane）會為同一個 pane 造出新的 container，
    **後造的那個會把 termView 搬走**。如果 SwiftUI 之後決定留下「先造的那個」，
    那一格就永遠是空的——邊框在、徽章在、中間什麼都沒有，跟截圖完全一樣。
    修法：`adoptTerminal()`——`updateNSView` 和 `viewDidMoveToWindow` 都呼叫，
    發現 termView 不在自己身上就搬回來。重複呼叫沒有副作用。
    另外補了兩個防禦：`tileIntoGrid` 依 id 去重（同一個 pane 出現兩次的話，
    也只有一個畫得出來），以及 `stack([])` 原本會 index out of range。 — NSMenu 預設 autoenables，
    驗證會走 SwiftTerm 的 `validateUserInterfaceItem`，而它對不認得的 selector
    一律回 false，所以那一項是 disabled 的（看起來只是顏色淡一點）。
    改成 `autoenablesItems = false` 自己設 `isEnabled`。

---

## 尚未實作（ROADMAP 中價值清單）

⚠️ **FTP 的 explicit AUTH TLS 沒做**：Network.framework 不能把「已經連上的
明文連線」升級成 TLS，而專案沒有 swift-nio-ssl（要多拉一整包 BoringSSL）。
現在支援 plain 與 **implicit TLS（990）**；FTP 邏輯是寫在 `FTPStream` 這個
protocol 之上的，之後要補 explicit 只要多一個 conformance，不用重寫。

| 項目 | 備註 |
|---|---|

| keyboard-interactive（2FA/OTP） | ⏸ **已查證：NIOSSH 0.15.0（最新）不支援**，上游 PR #242 零 review 又有衝突。詳見 ROADMAP |
| known_hosts 管理 UI | ✅ 已做（`TrustedHosts`/`KnownHosts`/`KnownHostsStore`，選單「Trusted Hosts…」） |
| session 匯出匯入 | ✅ 已做（`SessionArchive`/`SessionExport`：預設剝除密碼，帶密碼一律加密；`SessionImport.merge` 額外去重） |
| 分頁拖曳排序 | ✅ 已做（分頁列 `onDrag`/`onDrop` → `TabReorderDropDelegate` → `WindowState.moveTab`／`ListReorder`） |
| ⑥ 團隊同步（無後端版） | ✅ 用「加密封存檔 + 智慧合併」達成，**本輪補 update-merge**：匯入時 `.additive`（只加、不動既有，安全預設）或 `.update`（依 id 更新既有=拉隊友的改動；剝密碼的封存檔不會把本機已存密碼清空）。匯入對話框在偵測到既有項有改動時給「Add & Update／Add New Only」。3 個新測試（additive vs update、保留本機密碼、同時 add/update/skip）。**真正 live cloud 後端**（CloudKit／伺服器即時同步）未做：要基礎設施、驗證性低 |
| zmodem（rz/sz over terminal） | ✅ **接收方向已做**（v1.42，見上表；跟真 `sz` 對測）。發送方向（Mac→remote `rz`）未做 |

---

## 已知限制

- **RSA 金鑰不支援**：SwiftNIO SSH 上游只做 ed25519 / ECDSA / SE-P256，
  錯誤訊息會建議 `ssh-keygen -t ed25519`。
- **舊 server 的 ssh-rsa host key** 不支援（現代 sshd 都有 ed25519/ecdsa，無實際影響）。
- SFTP 面板跟著 **focus 的 pane** 走（每台機器一個連線）。分頁裡有兩台以上機器時
  面板頂端會標出是哪一個 session——**廣播輸入開著時，上傳仍然只會到那一台**。
- Edit Locally 沒有衝突偵測：本機存檔一律覆蓋遠端。
- **ssh-agent 認證／forwarding 做不到**（上游擋住）：`NIOSSHPrivateKey` 只能用具體
  金鑰型別建立，沒有自訂簽章器接口；`SSHChannelType` 也收不到
  `auth-agent@openssh.com` channel。加密金鑰與 Secure Enclave P256 可當替代。
- Session log 是明文：畫面上出現的機密都會寫進去（檔案 0600、資料夾 0700）。
- RDP 還沒有**麥克風輸入（audin）**。播放（rdpsnd）已經是真的 macOS backend，
  但**「聽得到」還沒實測**——手邊的 xrdp 容器沒有 pulseaudio-module-xrdp。
- **跨螢幕需要伺服器支援 display control**（Windows 8.1 / Server 2012 R2 以後）。
  舊 server 只認連線當下的 layout，MacMoba 會**帶著 layout 重連**一次來達成；
  本機的 xrdp 根本不開 disp channel，所以那條路只有真 Windows server 驗得到。
- RDP 剪貼簿支援**文字、圖片與檔案**。
  圖片轉換是把 DIB 前面補上 14 bytes 的 BMP file header 交給 AppKit 解，
  反向則是產生 BMP 再把 header 切掉——不用自己解析 BITMAPINFOHEADER。
- **檔案剪貼簿是「promise + 背景補實體檔」的混合做法**：
  收到 descriptor 後先放 `NSFilePromiseProvider`（拖曳就能用、不先傳），
  同時在背景分塊拉到暫存資料夾，拉完再把剪貼簿換成真正的 file URL（⌘V 才能用）。
  **超過 200MB 就只留 promise**，不做背景預抓——否則在 Explorer 複製一個大資料夾
  就會整包拉過來。暫存資料夾在分頁關閉時清掉。
- Mac 的剪貼簿沒有變更通知，是用 0.75 秒輪詢 changeCount（AppKit 一向如此）。
- **keyboard-interactive（2FA/OTP）做不到**（上游還沒做，不是永久性的）：
  NIOSSH 0.15.0 的 `Offer` 沒有這個方法，message id 60 又被寫死當成 PK_OK 解析。
  上游 PR #242 合併後升版就有了。

---

## 測試環境備忘

```bash
# node 測試 server（SFTP 服務真實檔案系統，可用 ls 驗證結果）
cd TestSupport && node ssh-server.js &      # 127.0.0.1:2299, test/secret

# RFB 3.8 測試 server：320x240 四色象限，並把收到的鍵鼠事件寫進 log
cd TestSupport && node vnc-server.js &      # 127.0.0.1:5999

# Telnet 測試 server：會協商 ECHO/SGA/TTYPE/NAWS，並把 client 的回應寫進 log
cd TestSupport && node telnet-server.js &   # 127.0.0.1:2323

# Mosh 測試環境（sshd + mosh-server）。**port 2223，不要用 2222**——
# 2222 是 OpenSSHInteropTests 的，佔掉會讓那些測試從 skip 變成 auth 失敗。
docker build -t mm-mosh-img -f /tmp/mosh-dockerfile /tmp
docker run -d --name mm-mosh -p 2223:22 -p 60001-60005:60001-60005/udp mm-mosh-img
#   FROM ubuntu:22.04 + openssh-server + mosh + locale-gen en_US.UTF-8
#   使用者 tester / secret
tail -f /tmp/macmoba-telnet-events.log      # TTYPE= / NAWS= / LINE= 都看得到
tail -f /tmp/macmoba-vnc-events.log         # PointerEvent / KeyEvent 都看得到

# 用獨立 vault 跑 UI 測試，不會碰到正式資料
MACMOBA_DATA_DIR=/tmp/macmoba-test MacMoba.app/Contents/MacOS/MacMoba
```

要測「網路斷掉時斷線」而**又不能動到對方的 SSH tunnel**，就在中間放一個
自己控制的 TCP relay，再把它凍住（**繼續收但不轉送、兩端 socket 都不關**，
所以雙方都收不到 FIN/RST）。直接 kill relay 沒有用：那會送 RST，
FreeRDP 立刻就知道了，反而走到最快的那條路。
⚠️ 但要注意 relay 只要**還在讀 socket**，client 的 write 就不會被擋住，
所以這樣還是逼不出「`freerdp_disconnect` 卡住」——真正的卡點比較可能是
**channel 執行緒（drive / cliprdr）沒收乾淨**。逾時那條路目前只有
`RDPLifetimeTests` 涵蓋得到（在 state callback 裡把連線執行緒卡住）。

UI 自動化注意：CGEvent 的 unicode 打字進不了 NSTextField，
要用 `osascript -e 'tell application "System Events" to keystroke "..."'`；
視窗先用 System Events 固定位置座標才穩。

其他踩過的坑：

- **`MACMOBA_DATA_DIR` 只隔離 vault，不隔離 UserDefaults**——主題、字級、
  copy/paste 三個開關、macro 廣播確認都寫進共用的 app domain
  （`~/Library/Preferences/dev.macmoba.MacMoba.plist`）。測試改過開關記得改回來，
  用 `plutil -p` 確認比 `defaults read` 快（`defaults domains` 會卡很久）。
- 同時有兩個 MacMoba 在跑時，`tell process "MacMoba"` 會挑到錯的那個。
  用 `tell (first process whose unix id is <pid>)` 指定。
- 滑鼠事件要真的雙擊，得自己設 `mouseEventClickState`；
  兩次獨立 click 不會被當成 double click。
- 側邊欄分隔線很容易誤拖：拖曳選取前先確認 x 座標落在終端機區域裡。
- **截圖可能是 1x 也可能是 2x（Retina）**，會變。換算滑鼠座標前先用
  `sips -g pixelWidth` 對一下截圖實際像素與擷取區域的比例，不要假設 1:1。
- **在 Explorer 裡點已經選取的檔案會進入「重新命名」**，這時 ⌃C 複製到的是
  檔名文字不是檔案。要先點別的地方或用單擊選不同檔案。
- **用短命的 CLI 程式寫 NSPasteboard 會失敗**：process 太快結束，
  pasteboard server 還沒接手。測試用的小工具寫完要 sleep 一下再退出。
- **SwiftPM 不會追蹤 `Vendor/**.a` 的變動**：重新 vendor 靜態庫之後，
  `swift build` 認為沒事做，會沿用舊的連結結果。要先 `rm -f .build/release/MacMoba`。
  （我因此追了半天「明明編掉了卻還在 load rdpsnd」的鬼影。）
- **⌘T 開本機終端後要等到看見 prompt 才動作**：登入 shell 讀 profile 可能要十幾秒，
  這期間送進去的字會停在 PTY 緩衝區（畫面上看得到 kernel echo，但沒有 prompt），
  等 shell 起來才一次補跑。看到「指令有出現但檔案沒生出來」先想到這個，不是 bug。
