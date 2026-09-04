# Changelog

Newest first. Each release published to GitHub takes its notes from the section
matching its version, and `make-app.sh` refuses to publish a version that has no
entry here — release notes that can be forgotten are release notes nobody writes.

## 2.29

**Large SFTP downloads are much faster, and no longer look frozen.** A download
asked for 32 KB and waited for it before asking again — nearly seven thousand
round trips for a 214 MB file, which on a 20 ms link is over two minutes spent
purely waiting. Sixteen reads now travel at once.

**Transfers show a percentage and a real progress bar.** The two-pane transfer
panel showed a spinner and "(1 of 1)" for as long as a file took; folder
transfers had a bar that moved without meaning anything, because their size was
never measured. Both now report where they actually are.

**Pasted screenshots go to a folder per session.** Two tabs onto one host shared
`~/.macmoba`, so a screenshot pasted in one sat among screenshots from every
other with nothing to say which was which. The upload notice also says a file
was created and that it expires after seven days.

大型 SFTP 下載快得多,也不再像卡住。原本每次只要 32 KB 並等它回來才要下一段——
214 MB 的檔案要將近七千次往返,在 20 ms 的連線上光是等待就超過兩分鐘。現在同時有十六個讀取在傳輸中。

傳輸會顯示百分比和真正的進度條。雙面板傳輸畫面原本只有一個轉圈和「(1 of 1)」,
一直持續到檔案傳完;資料夾傳輸的進度條會動但不代表任何進度,因為從來沒有量過大小。現在兩者都會回報真實進度。

貼上的截圖會依 session 分資料夾。兩個分頁連到同一台主機時共用 `~/.macmoba`,
於是在一個 session 貼的截圖和其他 session 的混在一起,無從分辨。上傳提示現在也會說明產生了檔案,以及七天後會清除。

## 2.28

**Fix: a right-click in a terminal could upload a screenshot to the remote
machine.** Right-click and middle-click paste, and pasting an image into an SSH
session uploads it as a file and types its path — so a screenshot still sitting
on the clipboard from earlier, plus one right-click where a menu was expected,
quietly wrote a file on the far machine. Mouse paste now handles text only;
images still upload from ⌘V and the Paste menu item, where they were asked for.

**Pasted images on the remote are now kept for seven days.** Nothing had ever
removed them, so `~/.macmoba` on a machine you paste into grew without limit.
Only files this app wrote are touched, and only past the seventh day.

修正:在終端機裡按右鍵有可能把一張截圖上傳到遠端主機。右鍵和中鍵是貼上,而在 SSH
分頁貼圖片會把它上傳成檔案並把路徑打進提示字元——所以只要剪貼簿裡還留著稍早的截圖,
在你以為是開選單的地方按一下右鍵,就會在遠端悄悄寫下一個檔案。現在滑鼠貼上只處理文字;
圖片仍然可以用 ⌘V 或選單的 Paste 上傳,那才是你真的要求它做的時候。

貼到遠端的圖片現在保留七天。先前沒有任何清理,所以你貼進去的那台機器上的 `~/.macmoba`
會無限成長。只會刪掉這個 App 自己寫的檔案,而且只刪超過七天的。

## 2.27

**Fix: copying on the Mac and pasting into a Windows RDP session did nothing.**
Every copy told the session two contradictory things a millisecond apart —
first that the clipboard had been emptied, then that it held text — because
files and text were announced separately and the first announcement was built
from the previous contents. Windows kept the wrong one. One copy now makes one
announcement, covering text, images and files together.

修正:在 Mac 複製、到 Windows RDP 分頁貼上沒有反應。每一次複製都會在一毫秒內
對遠端說兩件互相矛盾的事——先說「剪貼簿已清空」,再說「裡面有文字」——因為檔案和
文字是分開宣告的,而第一次宣告是用**上一次**的內容算出來的。Windows 留下了錯的那一份。
現在一次複製只送一次宣告,文字、圖片、檔案一起。

## 2.26

**Fix: a web tab could not pick a file to upload.** Clicking a page's file
field did nothing at all — no picker, no error, the field simply stayed empty.
The tab had never been given the object WebKit asks for anything it cannot draw
itself, so the request had nowhere to go and was dropped in silence. The same
absence made JavaScript alerts, confirmations and prompts do nothing (a page
waiting on a confirmation never continued), and made links that open in a new
window dead on click. All three now work. The file picker opens in
`~/.macmoba`, where pasted screenshots are kept, and shows hidden files.

修正:Web 分頁沒辦法選檔案上傳。點頁面上的檔案欄位完全沒有反應——不跳選取視窗、
也不報錯,欄位就一直是空的。這個分頁從來沒有被交付 WebKit 用來詢問「自己畫不出來的東西」
的那個物件,所以請求沒有地方可去,無聲地被丟掉。同一個缺席也讓 JavaScript 的
alert、confirm、prompt 全都沒有作用(頁面等在 confirm 就再也不會繼續),
並且讓「在新視窗開啟」的連結點了沒反應。三者現在都正常。檔案選取視窗會開在
`~/.macmoba`——貼上的截圖就放在那裡——並且會顯示隱藏檔案。

## 2.25

**Fix: after releasing a captured remote desktop, every click became a right
click.** Only on a Mac remote, because there ctrl-click *is* a right click —
the remote was left holding Control down. RoyalVNC turns modifier changes into
key events by diffing against its own remembered flags, and 2.24 started handing
the keyboard back the moment ⌃⌥ was released, before that event reached the
desktop. So the desktop never saw the modifiers clear, went on believing they
were held, and never sent the key release. It is now told first, and the
keyboard handed back after.

修正:從已擷取的遠端桌面放開後,每一次點擊都變成右鍵。只有 Mac 遠端看得出來,
因為在 macOS 上 ctrl-click 就是右鍵——遠端被留在「Control 還按著」的狀態。
RoyalVNC 是拿事件的修飾鍵和自己記住的狀態做比對來產生按鍵事件,而 2.24 開始在
⌃⌥ 一放開就交還鍵盤,比那個事件送到桌面還早;桌面因此從來沒看到修飾鍵歸零,
一直以為還按著,也就從來沒送出放開。現在改成先通知桌面,再交還鍵盤。

**East Asian text parses about three times faster.** CJK output went through a
slower path than ASCII for every single character — an extra allocation, a
grapheme-cluster construction, and a block of combining-character work that
plain text skips entirely. Characters that cannot combine with anything now take
a direct route: 11.8 to 31.9 MB/s, with ASCII unchanged. Most visible in a local
shell, where nothing on the network is holding the output back.

東亞文字的解析大約快了三倍。中日韓輸出過去在**每一個字元**上都比 ASCII 多走一段路——
多一次配置、多建一個 grapheme cluster,還有一整段純文字根本不會碰到的組合字處理。
現在不可能與鄰居組合的字元直接走捷徑:11.8 提升到 31.9 MB/s,ASCII 維持不變。
在本機 shell 最明顯,因為那裡沒有網路速度擋著。

## 2.24

**Fix: after leaving a captured remote desktop, the shell beside it would not type.**
Two causes, both only reachable now that a desktop and a shell can share one tab.
Capturing input made the desktop the first responder and releasing it never gave
that back, so keystrokes kept matching the forward-to-remote rule. And clicking a
terminal did not take the keyboard either — AppKit does not move first responder
on a click, and neither SwiftTerm nor this app was asking it to; panes got the
keyboard only when first built. Releasing now hands it back, clicking a terminal
claims it, and the focus ring follows the click.

修正:從已擷取的遠端桌面離開後,旁邊的 shell 打不了字。兩個原因,都只有在桌面和 shell 共用同一個分頁時才會踩到。
擷取輸入時會把桌面設為 first responder,而放開擷取從來沒有把它交還,所以按鍵仍然符合「轉送到遠端」的條件;
而點擊終端機也拿不回鍵盤——AppKit 不會因為點擊就移動 first responder,SwiftTerm 和這個 App 都沒有主動要求,
pane 只有在第一次建立時才拿到鍵盤。現在放開擷取會交還鍵盤,點擊終端機會取得鍵盤,焦點框也會跟著點擊走。

## 2.23

**Fix: Esc did nothing after a local shell exited.**
"Return to reconnect, Esc to close" was implemented on the SSH pane's input
path. A local shell writes straight to its own process, so once that process
was gone the keystrokes landed nowhere. It now consults the same policy — Return
starts a fresh shell in the same pane, keeping the scrollback above the
`[shell exited]` line — and an exited shell finally shows the overlay saying so,
which the SSH pane has always had.

修正:本機 shell 結束後按 Esc 沒有反應。「Return 重連、Esc 關閉」原本只做在 SSH pane 的輸入路徑上;
本機 shell 是直接寫入自己的程序,程序沒了之後按鍵就落在空處。現在改用同一套判斷——Return 會在同一格
開一個新的 shell,`[shell exited]` 以上的 scrollback 都還在——而且結束後終於會顯示提示視窗,
那是 SSH pane 一直都有的。

## 2.22

**Fix: a local shell went blank after Break Apart into Tabs.**
It was handed to SwiftUI as the terminal view itself, which was safe only while
a local shell was always a whole tab and never moved. As a pane it gets
re-parented, and a bare view lives wherever the *last* host put it — so if an
earlier host stays on screen, the pane draws nothing. It now uses the same
self-healing container an SSH pane has used all along.

修正:解散分割之後本機終端機一片空白。它原本是直接把 terminal view 本身交給 SwiftUI,
那在「本機 shell 永遠是一整個分頁、不會被搬動」的前提下才安全。變成 pane 之後它會被重新掛載,
而一個裸的 view 只會待在**最後**一個掛載它的地方——如果 SwiftUI 留在畫面上的是更早的那一個,
這一格就什麼都不畫。現在改用 SSH pane 一直在用的那個會自我修復的容器。

## 2.21

**Local terminals can be split, and can share a tab with anything else.**
The local shell was the one tab kind left out of the heterogeneous-split work:
it parked a never-connected SSH pane in the tree and drew itself around it, so
`canSplit` had to claim the tab had no tree at all. It is now an ordinary leaf,
which means Split Right/Down works on it, it can sit beside an SSH pane or a
remote desktop, it survives Break Apart into Tabs, and the arrangement is
restored on the next launch. The split menu gained **New Local Terminal**.

本機終端機現在可以分割,也可以跟其他任何連線共用同一個分頁。它原本是唯一沒有納入異質分割的分頁類型——
在樹裡塞一個永遠不會連線的 SSH pane,再繞過它自己畫,所以 `canSplit` 只能宣稱這個分頁根本沒有樹。
現在它就是一個普通的葉節點:可以分割、可以跟 SSH 或遠端桌面並排、解散分割後仍然正常,版面也會在下次啟動還原。
分割選單新增 **New Local Terminal**。

## 2.20

**Web tabs can finally load a self-signed internal console.**
The certificate pin was working all along — the fingerprint matched, the
credential was accepted immediately, and the load still failed with -1202. The
cause was App Transport Security, and the part that is not obvious is that an
ATS refusal **cannot be overridden from the authentication challenge**: the
prompt appears, trusting works, the pin is stored, and the page fails anyway.
Web-view content is now exempt from ATS (`NSAllowsArbitraryLoadsInWebContent`),
which leaves the app's own network calls under ATS and leaves the per-host
certificate pin — the thing actually protecting these tabs — fully in force.

網頁分頁終於能開自簽憑證的內部主控台。憑證釘選一直都是正常的——指紋相符、當場接受、卻還是 -1202。
真正的原因是 App Transport Security,而不明顯的地方在於:**ATS 的拒絕無法從憑證詢問那裡覆蓋**——
對話框會跳、按信任有效、指紋也存了,頁面照樣失敗。現在只讓網頁內容豁免 ATS,
App 自己的網路請求仍受 ATS 保護,而真正在保護這些分頁的每主機憑證釘選完全不受影響。

## 2.19

**Web tab: keep digging at the self-signed certificate refusal.**
A pinned certificate is now handed back with its faults formally excused
(`SecTrustSetExceptions`), because returning a credential built on a trust that
still evaluates as bad is the documented way to have it refused twice. The
diagnostics also record *which* URL failed — a refusal for a host that never
produced a challenge is a different problem from one for the host just accepted.

網頁分頁:繼續追自簽憑證被拒的問題。已釘選的憑證現在會正式標記「使用者已接受這些瑕疵」再交回去;
診斷也會記下**是哪一個網址**失敗——沒出現過憑證詢問的主機失敗,跟剛剛才接受的主機失敗,是兩回事。

## 2.18

**Log what the certificate challenge actually contains.**
Two releases guessed wrong, so every decision is now recorded: host, whether the
system trusted it, the offered and stored fingerprints, the action taken and the
answer given. The alert also brings the app forward first — a prompt nobody sees
is indistinguishable from a broken feature.

    log show --predicate 'subsystem == "dev.macmoba.tls"' --last 10m --info

## 2.17

**Answer the certificate challenge before asking, not after.**
Trusting a certificate did nothing in 2.16. A WKWebView trust challenge has to be
answered on the spot: measured against a real self-signed server, answering even
0.2s late leaves the navigation dead. So the attempt is declined immediately, the
user is asked afterwards, and on acceptance the fingerprint is pinned and the page
reloaded.

## 2.16

**Web tabs can reach servers whose certificate the Mac won't verify.**
Internal consoles are almost always self-signed or behind a private CA, and WebKit
refused them outright. Rather than ignoring TLS errors, the certificate is now
pinned per host the way SSH host keys and RDP certificates already are: a good
certificate never prompts, an unknown one shows its fingerprint once, and a pinned
one that later changes always asks again. Revocable from Trusted Hosts.

## 2.15

**Repaint only the dirty rows while dragging a selection.**
Copying was never the slow part — extracting a selection takes about 4ms whether
it covers a thousand lines or ten thousand. The stutter was SwiftTerm repainting
the whole view on every mouse-move of a drag: 7.2ms at 1200×800, 22.4ms at
2560×1440. SwiftTerm's Metal renderer marks only the changed rows, so it is now
available as **Settings → Terminal → GPU rendering** (off by default, applies live).

## 2.14

**Ten thousand lines of scrollback, not five hundred.**
SwiftTerm's 500-line default had never been changed. That is a terminal-widget
default, not a session-manager one — a few seconds of a build log. Now 10,000 by
default and adjustable from 500 to 100,000. The buffer grows with output rather
than being allocated up front, so idle panes cost nothing extra.
