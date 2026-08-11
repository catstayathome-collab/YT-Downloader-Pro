# YT Downloader Pro 1.8.7 設計規格

## 目標

1.8.7 是現有 Python/Tkinter macOS 版的安全與發佈修補版。這一版不重寫下載核心，也不加入 Windows 功能；重點是消除可能刪除既有檔案的風險、避免解析資料錯置、恢復安全連線、穩定背景下載期間的介面操作，並建立可供一般使用者下載與理解的 GitHub Release。

## 平台與版本範圍

- 主要原始碼建立為 `YT_downloader_187.py`，保留 `YT_downloader_186.py` 不變，讓版本差異可以回溯。
- 目標平台維持 Apple Silicon macOS，最低系統版本設定為 macOS 11.0。
- 維持 Python、Tkinter、yt-dlp Python API 與單一 `Contents/Helpers/` FFmpeg 工具目錄。
- 使用免費的 ad-hoc 簽章。Developer ID、公證、Intel universal build 與自動安裝更新不在本版範圍。
- 目前未提交的 `AppIcon.icns` 使用者變更必須保留，不得被回復或覆寫。

## 方案選擇

採用現有架構的定向修補，不在 1.8.7 將下載核心改成外部 `yt-dlp_macos` Process。這能以較低回歸風險修復現有使用者遇到的問題，也避免與 Swift 2.0 的 Process 架構重複開發。

替代方案未採用的原因：

- 全面改成 subprocess：可以提供更強的終止控制，但會改寫進度、格式、錯誤與暫停流程，超出修補版範圍。
- 直接停止 Python 版維護：現有 1.8.x 使用者仍暴露在取消誤刪風險中，不可接受。

## 下載任務與檔案安全

每次下載建立獨立的任務檔案紀錄，內容至少包含輸出目錄、唯一輸出檔名、任務開始前已存在的路徑集合，以及由 yt-dlp 進度或後處理 hook 回報的路徑。

取消清理必須符合以下規則：

- 絕不使用 `<影片標題>*` 掃描並刪除檔案。
- 絕不刪除任務開始前已存在的檔案。
- 只處理位於目前輸出目錄內的路徑，解析後的 real path 不得逃離該目錄。
- 只刪除本任務唯一輸出檔名、其 `.part`、`.ytdl`、fragment、temp 或 hook 明確回報且由本任務新建立的檔案。
- 取消後若無法判定檔案所有權，保留檔案並記錄，不以清除乾淨為優先。
- 正常失敗保留可供 yt-dlp 續傳的 partial 檔；只有使用者明確取消才清理本任務擁有的暫存檔。

重複檔名仍使用 `名稱 (1)`、`名稱 (2)` 的方式產生，但任務紀錄必須保存實際選中的完整檔名與 stem，不再只保存原始影片標題。

## 解析狀態與介面

解析結果必須與標準化後的網址綁定，保存 `analyzed_url`、標題、video format IDs 與 audio format IDs。

- 開始解析前立即停用下載按鈕並清除上一支影片的格式資料。
- 使用者輸入、貼上或改動網址後，若網址不同於 `analyzed_url`，立即使舊解析結果失效。
- 下載前再次確認目前網址等於 `analyzed_url`，且所需的 video/audio format ID 存在。
- 沒有可用格式時不得啟用下載按鈕，並顯示可理解的訊息。
- Enter 維持「解析網址」行為；本版不改成一鍵解析後直接下載。

Tkinter widget、BooleanVar 與 messagebox 只能由主執行緒存取。開始背景執行緒前，主執行緒先把網址、音訊模式、格式 ID、輸出路徑與標題轉成一般 Python 值；背景工作只處理下載，所有 UI 更新透過 `root.after(...)` 回到主執行緒。

## 暫停、取消與合併

下載期間保留目前基於 progress hook 的暫停功能。它代表在下一次進度回報點停止繼續處理，不宣稱能暫停 FFmpeg。

- yt-dlp 回報下載完成並進入後處理後，狀態改為 merging。
- merging 期間停用暫停與取消按鈕，避免顯示無法履行的操作。
- 使用者在 downloading 狀態取消時，解除 pause wait、結束 yt-dlp 工作並執行安全的任務檔案清理。
- 所有完成、取消與錯誤對話框由主執行緒顯示。

## HTTPS 與錯誤處理

- 移除全域 `ssl._create_unverified_context` 覆寫。
- 移除分析與下載設定中的 `nocheckcertificate`。
- 使用 Python/yt-dlp 的預設憑證驗證；打包後確認 `certifi` CA bundle 可被找到。
- 將憑證、無網路、權限不足、格式變動、工具不可用與取消分成可本地化的錯誤訊息。
- 啟動自動更新檢查遇到暫時網路失敗時維持安靜；使用者手動檢查時顯示可操作的錯誤。

## 工具鏈與授權

FFmpeg 與 FFprobe 必須來自同一個可追溯版本，符合以下驗證：

- arm64 或 universal Mach-O，能執行 `-version`。
- configure output 不得包含 `--enable-nonfree`。
- 保存來源 URL、版本、SHA-256、授權與對應 source/build information。
- 打包後仍只有一份實體 FFmpeg 與一份實體 FFprobe。

若找不到符合條件且可合理再散布的工具，本地 1.8.7 功能驗證可以繼續，但不得建立公開 Release，並將此項回報為發佈阻擋條件。

## 可重現建置與 App 資訊

- `requirements.txt` 使用已實際通過整合測試的 yt-dlp 與 PyInstaller 精確版本，不使用 `>=`。
- 建置腳本改用 `YT_downloader_187.py`。
- App 的 `CFBundleShortVersionString` 設為 `1.8.7`，`CFBundleVersion` 設為 `187`，`LSMinimumSystemVersion` 設為 `11.0`。
- 修改 Info.plist 後再依 helper、主程式、app 的順序進行 ad-hoc 簽章與驗證。
- 建置驗證必須檢查版本、架構、簽章、helper 可執行性與 FFmpeg 實體檔案數量。

## GitHub 文件與更新流程

README 需加入：

- 中文為主的功能摘要與支援範圍。
- Apple Silicon/macOS 需求、安裝與首次開啟方式。
- MP4、MP3、畫質與音軌選擇、重複檔名、資料夾記憶、更新檢查等功能。
- 單影片限制、暫停限制與不支援 DRM/私人內容等已知限制。
- 問題回報需要的 App 版本、Mac 型號、macOS、網址與錯誤截圖。
- yt-dlp 與 FFmpeg 的來源、授權及合理使用提醒。

更新提示的下載網址改為 GitHub Releases 頁。只有在 v1.8.7 Release 已建立且附有可下載的 zip/DMG 後，才把 `main/version.txt` 更新為 `1.8.7`，避免舊 App 提前通知一個尚未可下載的版本。

## 測試策略

自動測試至少涵蓋：

- 取消同標題新任務時，既有 MP4/MP3 不被刪除。
- 取消只刪除本任務新建立的 partial/temp 檔。
- `../`、symlink 或輸出目錄外路徑不會被清理。
- 重複檔名依序產生 `(1)`、`(2)`。
- 修改網址後舊解析結果失效。
- video/audio 格式缺失時下載保持停用。
- SSL、無網路與格式錯誤轉為本地化訊息。
- manifest、版本比較、設定路徑與工具檢查既有測試繼續通過。

整合驗證至少使用先前曾失敗的兩支 YouTube 影片進行解析，並在暫存目錄測試 MP4、MP3、取消與重複檔名。公開發佈前必須在另一台 Apple Silicon Mac 測試下載、首次開啟與更新提示。

## 驗收條件

- 所有自動測試通過，且取消誤刪測試在 1.8.6 會失敗、在 1.8.7 會通過。
- 兩支既有問題影片可解析並提供可下載格式。
- MP4 與 MP3 實際下載成功，重複檔案不被覆寫。
- 取消不會刪除任務開始前存在的任何檔案。
- App bundle 版本為 1.8.7、arm64 可執行、簽章驗證通過、FFmpeg/FFprobe 各只有一份實體檔案。
- GitHub README 能讓非開發者理解功能、限制、安裝方式與問題回報方法。
- 公開 Release 存在可下載安裝檔後，才更新 `version.txt` 與建立 `v1.8.7` tag。
