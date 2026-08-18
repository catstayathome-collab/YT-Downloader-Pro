YT Downloader Pro 1.8.8 Windows x64 未簽署版
=================================================

這是公開 `v1.8.8` Release 的可攜式 Windows 版本，不是安裝程式。
請只從本專案的 GitHub Releases 下載；不要從轉傳連結、網路硬碟或不明網站取得檔案。

支援的系統
----------

- Windows 10 22H2 或更新版本，Intel/AMD x64。
- Windows 11，Intel/AMD x64。
- Windows 7、Windows 8、32 位元 Windows 與 Windows ARM 不支援。

取得與驗證 GitHub Release
-------------------------

1. 開啟本專案的公開 GitHub Releases 頁面並進入 `v1.8.8`。
2. 下載 `YT-Downloader-Pro-v1.8.8-Windows-x64.zip` 與同名的 `.sha256` 檔案。
3. 將兩個檔案放在同一個資料夾。
4. 在 PowerShell 切換至下載資料夾，執行：

   Get-FileHash -Algorithm SHA256 .\YT-Downloader-Pro-v1.8.8-Windows-x64.zip

   將輸出的 Hash 與 `.sha256` 檔案中的值逐字比較；兩者不同時請停止，不要解壓或執行。
5. 對 `YT-Downloader-Pro-v1.8.8-Windows-x64.zip` 按右鍵，選擇「全部解壓縮」，再開啟解壓後的 `YT-Downloader-Pro-v1.8.8-Windows-x64` 資料夾。不要直接在壓縮檔內執行程式，也不要只搬走其中的 EXE。

啟動與 SmartScreen
------------------

在解壓後的資料夾中執行 `YT Downloader Pro.exe`。此未簽署版預期會出現 Microsoft Defender SmartScreen：

1. 僅在已從公開 GitHub Release 取得檔案並完成 SHA-256 比對後，選擇 `More info`。
2. 確認顯示的應用程式是 `YT Downloader Pro.exe`，再選擇 `Run anyway`。
3. 若 Hash 不同、來源不明、顯示的檔名不符，或安全軟體指出其他風險，請不要選擇 `Run anyway`，並回報問題。

程式以視窗模式執行，正常啟動、下載與轉檔時不應另外出現命令列視窗。

功能與資料位置
----------------

Windows 版提供 1.8.8 單支影片工作流程：分析 YouTube URL、選擇可用影片/音訊、最高可用品質 MP4 合併、192 kbps MP3、進度/速度/大小顯示、下載期間暫停/繼續/取消、同名檔案以 ` (1)` 避免覆寫，以及記住可用的輸出資料夾。介面會依 Windows 顯示語言使用繁體中文、English 或日本語。

- 設定檔：`%APPDATA%\YT Downloader Pro\settings.json`
- 診斷紀錄：`%LOCALAPPDATA%\YT Downloader Pro\logs`
- 包內 helper：`Helpers\ffmpeg.exe`、`Helpers\ffprobe.exe`、`Helpers\deno.exe`

設定檔只保存最後的輸出資料夾與語言；診斷紀錄不應包含 Cookie、密碼、權杖或登入憑證。回報問題時，請提供 app 版本、Windows 版本、發生階段、完整錯誤文字，以及相關 log；不要提供 Cookie 或帳號資料。

Helper 復原
-----------

程式只使用同一個解壓資料夾內 `Helpers` 的三個檔案，不會改用系統安裝的 FFmpeg 或 Deno。若啟動檢查顯示 helper 遺失、毀損、架構錯誤或被防毒軟體隔離：

1. 關閉程式，重新從已驗證 SHA-256 的原始 ZIP 解壓完整資料夾。
2. 保留 `Helpers\ffmpeg.exe`、`Helpers\ffprobe.exe` 與 `Helpers\deno.exe` 的原有檔名和位置，不要個別從網路下載替換檔案。
3. 若 Windows Security 隔離了檔案，先再次確認 artifact 來源與 ZIP Hash，再依公司或個人安全政策處理；無法確認時請回報並附上 log。

更新與使用提醒
----------------

程式會讀取公開的 GitHub `version.txt` manifest 檢查版本；Windows 只會導向名稱包含 Windows-x64 的相容資產，絕不把 macOS ZIP 當成 Windows 更新。此版本不會自動更新內建工具。

本專案不授予下載第三方影音內容的權利。不得下載未獲授權的影音內容；請只下載自己擁有、已獲授權，或法律與平台條款允許保存的內容。
