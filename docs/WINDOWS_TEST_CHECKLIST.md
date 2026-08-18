# Windows 11 1.8.8 手動驗收紀錄

測試者：

測試日期：

Windows 版本與版本號：

裝置與處理器：

Actions workflow URL：

Artifact 名稱：`YT-Downloader-Pro-v1.8.8-Windows-x64`

ZIP：`YT-Downloader-Pro-v1.8.8-Windows-x64.zip`

SHA-256 比對結果來源：

請在每一列的「結果」與「備註」填入實際觀察、錯誤訊息、輸出檔名或相關 log 位置。維護者已完成 macOS 與 Windows 核心下載驗收並核准 `v1.8.8` 公開發布；其餘情境仍應在後續版本持續回歸。

| # | 驗收情境 | 結果 | 備註 |
| --- | --- | --- | --- |
| 1 | 從公開 GitHub Release 下載 ZIP，完成 SHA-256 比對並解壓。 |  |  |
| 2 | 未簽署 SmartScreen 流程顯示；完成來源與 Hash 確認後，透過 `More info` 與 `Run anyway` 啟動。 |  |  |
| 3 | 啟動 `YT Downloader Pro.exe` 時沒有額外命令列視窗。 |  |  |
| 4 | 分析回歸影片 `https://youtu.be/RIItBfZ6S3Q`。 |  |  |
| 5 | 下載並合併最高可用品質 MP4，確認跨過 33.6% 並完成至 100%。 |  |  |
| 6 | 轉換為 192 kbps MP3。 |  |  |
| 7 | 重複下載相同內容時建立 ` (1)`，且不覆寫原檔。 |  |  |
| 8 | 變更輸出資料夾後重新啟動，確認資料夾設定仍被保留。 |  |  |
| 9 | 在可暫停的下載階段測試暫停、繼續與取消行為。 |  |  |
| 10 | 取消下載時，確認既有檔案未被刪除。 |  |  |
| 11 | 確認繁體中文 UI、Windows 字型、檔案對話框與路徑顯示。 |  |  |
| 12 | 分別確認離線、不可寫入資料夾與 helper 遺失時的本地化處理及 log。 |  |  |
