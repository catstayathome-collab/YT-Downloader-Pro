# 1.8.8 發布驗證

回歸影片：`https://youtu.be/RIItBfZ6S3Q`

## 自動驗證

- [x] 共用分析選項使用 YouTube `web_embedded` client。
- [x] 共用下載選項使用相同的 `web_embedded` client。
- [x] HTTP 403 會顯示繁中、英文或日文的可理解訊息。
- [x] macOS 實際下載格式 `137+140`，跨過原本的 33.6% 失敗點並完成至 100%。
- [x] macOS 輸出通過 FFprobe：1920x1080 H.264 影片與 AAC 音訊。
- [x] macOS App bundle 為 1.8.8 build 188，且內建 helper、arm64 架構與簽章檢查通過。

## 發布門檻

- [ ] 在 Apple Silicon Mac 從封裝後 App 完成一次 UI 分析與 MP4 下載。
- [ ] 在 Windows 11 x64 依 `WINDOWS_TEST_CHECKLIST.md` 完成 12 項手動驗收。
- [ ] 確認 macOS 與 Windows 都能用回歸影片跨過 33.6% 並完成合併。
- [ ] 完成後才將 `version.txt` 更新為 `1.8.8`、建立 tag 與公開 Release。
