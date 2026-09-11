# YT Downloader Pro

YT Downloader Pro 是一款單影片 YouTube 下載工具，由 Ta-Chou Weng 維護。目前最新公開版本為 `1.8.8`，支援 Apple Silicon Mac 與 Windows 10/11 x64，並修正 YouTube 串流下載途中可能出現的 HTTP 403。

## 功能

- 解析單支 YouTube 影片並選擇可用畫質與音軌。
- 下載並合併為 MP4，預設選單會優先列出較高畫質與音質。
- 擷取音訊並轉換為 192 kbps MP3。
- 同名檔案不覆寫，依序使用 `名稱 (1)`、`名稱 (2)`。
- 記住上次選擇的下載資料夾。
- 下載期間顯示進度、速度與檔案大小。
- 下載階段可暫停、繼續或取消；取消只清理該次任務新建立的檔案。
- 內建 FFmpeg/FFprobe/QuickJS 啟動檢查與 GitHub 新版本提示。

## 系統需求

- Apple Silicon Mac（M1 或更新處理器），macOS 11.0 或更新版本。
- Windows 10 22H2 或 Windows 11，Intel/AMD x64。
- 可連線至 YouTube 的網路環境。
- 不需要另外安裝 Homebrew、FFmpeg 或 Python。

Intel Mac、Windows ARM、32 位元 Windows 與 Linux 不屬於目前 `1.8.x` 的支援範圍。macOS 與 Windows 使用不同的 Release 安裝檔。

## 安裝與開啟

1. 前往 [GitHub Releases](https://github.com/catstayathome-collab/YT-Downloader-Pro/releases/latest) 下載最新的 macOS 壓縮檔。
2. 解壓縮後，將 `YT Downloader Pro.app` 移到「應用程式」資料夾。
3. 第一次開啟若 macOS 顯示安全提示，請在 Finder 對 App 按右鍵並選擇「打開」，再確認一次。
4. 貼上影片網址、按 Enter 或「解析影片」，選擇格式及儲存位置後開始下載。

請只從本專案的 Releases 頁取得安裝檔。目前最新公開版本為 `1.8.8`。

## Windows 版

`v1.8.8` 同時提供 macOS arm64 與 Windows 10 22H2/Windows 11 Intel/AMD x64 安裝檔。Windows 版是未簽署的可攜式 ZIP，檔名為 `YT-Downloader-Pro-v1.8.8-Windows-x64.zip`。

Windows 使用者應從公開 GitHub Release 下載 ZIP 與 SHA-256 檔案、完成比對、完整解壓後啟動 `YT Downloader Pro.exe`。未簽署版本預期會出現 SmartScreen 提示，詳細步驟請參考包內 `README-Windows.txt`。

## macOS Swift 2.0 內部測試版

`swift-2.0/` 是 macOS 13 以上的原生 SwiftUI 下載中心。它採用持久化下載卡片、播放清單、多工佇列、每項任務獨立的暫停/取消/重試，以及英文、日文與繁體中文介面。此版本目前仍是內部測試候選，不是已發布的公開最新版；公開版仍為上方所述的 `1.8.8`。

目前 `yt-dlp_macos` 同時含 arm64 與 x86_64，但 `ffmpeg`、`ffprobe`、`qjs` 只有 arm64。因此 Task 15 只允許建立 Apple Silicon 內部測試 App；通用版或 Intel 請求會在組裝前明確失敗，不會混用舊版且版本不一致的工具，也不會宣稱 Intel 支援。

```bash
python3 -m unittest tests.test_swift_bundle -v
./scripts/build_swift_2.sh \
  --version 2.0.0 \
  --architectures arm64 \
  --sbom-created 2026-08-27T00:00:00Z \
  --unsigned-test
python3 scripts/check_swift_bundle.py \
  'dist/YT Downloader Pro 2.app' \
  --expected-version 2.0.0 \
  --architectures arm64 \
  --inventory tools/macos-helper-inventory.json
```

輸出為 `dist/YT Downloader Pro 2.app`、arm64 內部測試 ZIP 與 `dist/swift-2.0-bundle-report.json`。工程架構、開發、發布、SBOM/授權維護及問題排除分別記錄於 `docs/swift-2.0/ARCHITECTURE.md`、`DEVELOPMENT.md`、`RELEASE.md`、`SBOM_AND_LICENSES.md`、`TROUBLESHOOTING.md`，人工驗收表位於 `docs/SWIFT_2_TEST_CHECKLIST.md`。

## 已知限制

- `1.8.8` 一次處理一支影片，不支援播放清單與多網址佇列。
- 暫停只在 yt-dlp 回報下載進度時生效；進入 FFmpeg 合併或 MP3 轉換後不能暫停或取消。
- DRM、付費、私人、會員限定、地區限制或需要登入驗證的影片不保證可下載。
- YouTube 隨時可能調整格式或驗證方式；遇到格式錯誤時請先重新解析並確認是否已有新版。
- 使用者必須確認自己有權下載內容，並遵守 YouTube 條款及所在地法律。

## 問題排除

- **解析失敗**：檢查網址與網路後重新解析，並確認系統日期時間正確。
- **內建轉檔工具無法使用**：重新下載完整 App，不要單獨移動 App 內的檔案。
- **無法儲存**：改選「下載項目」或其他有寫入權限的資料夾。
- **格式已變動**：重新解析影片，再選擇新的畫質與音軌。

## 問題回報

請在 GitHub Issues 提供下列非敏感資料；公開 Issue 不是私密客服管道：

- App 完整版本，例如 `1.8.8`。
- Mac 型號與處理器，例如 MacBook Air M5。
- macOS 版本。
- App 顯示的錯誤分類與已經過濾的錯誤摘要。
- 問題發生在解析、MP4、MP3、暫停、取消或合併的哪個階段。

請勿在公開 Issue 張貼影片網址、下載紀錄、本機路徑、電子郵件、付款資料、
Cookie、授權標頭、Token、完整診斷檔或含有個人資料的截圖。只有在重現問題
確實需要網址時，才應透過日後提供的第一方私密支援表單另行同意送出。

## 商業化第一階段文件

付費版目前是「可行性驗證可繼續、公開收費不可開始」的狀態。未取得綠界
針對此產品的書面同意、台灣律師意見、會計與第三方授權確認前，不會啟用
正式結帳或訂閱權限。

- [`COMMERCIAL_FEASIBILITY.md`](COMMERCIAL_FEASIBILITY.md)：商業決策、收入模型、風險與啟動門檻。
- [`PAYMENT_PROVIDER_QUESTIONS.md`](PAYMENT_PROVIDER_QUESTIONS.md)：送交綠界前的產品揭露與問題草稿，尚未送出。
- [`LEGAL_REVIEW_BRIEF.md`](LEGAL_REVIEW_BRIEF.md)：提供台灣律師審查的事實與問題。
- [`PRIVACY_DATA_MAP.md`](PRIVACY_DATA_MAP.md)：本機與未來後端的資料邊界。
- [`ENTITLEMENT_ARCHITECTURE.md`](ENTITLEMENT_ARCHITECTURE.md)：Google 登入、訂閱狀態與功能權限架構。
- [`RECOVERY_LADDER.md`](RECOVERY_LADDER.md)：yt-dlp 失敗時有上限且不靜默降畫質的恢復流程。
- [`REPOSITORY_AND_SUPPORT_STRATEGY.md`](REPOSITORY_AND_SUPPORT_STRATEGY.md)：私有開發庫、公開發佈面與回饋功能方案。

## 版本與原始碼

- `v1.8.0-original`：維護前的原始版本。
- `v1.8.3`：記住上次下載資料夾。
- `v1.8.4`：加入 Apple Silicon 工具與啟動檢查。
- `v1.8.5`：修正不可合併的 HLS 格式選擇。
- `v1.8.6`：加入 GitHub Contents API 更新檢查。
- `v1.8.7`：改善 Apple Silicon 相容性、下載安全性、錯誤訊息與完整尺寸 App 圖示。
- `v1.8.8`：分析與下載統一使用可正常取得串流的 YouTube client，加入 HTTP 403 本地化提示與 Windows x64 版本。
- `versions/v1.8.8/`：macOS 與 Windows `1.8.8` 的版本化入口。
- `versions/v1.8.7/`：保留的 macOS 與 Windows `1.8.7` 版本化入口。
- `versions/`：集中保存可用的 Python 版本入口與歷史索引。
- `develop/v2.0-swift`：原生 SwiftUI 下載中心開發線。

每個 Python 版本保留獨立檔名並集中在 `versions/v1.8.x/`，方便比較與回復。完整版本仍以 Git tag 為準，因為 1.8.7 之後的入口會共用 `ytdp/`；公開版本會讓 `version.txt`、Git tag 與 GitHub Release 維持相同版本號。

`1.8.8` 的自動驗證結果與雙平台發布門檻記錄於 `docs/RELEASE_1_8_8_VALIDATION.md`。

## 開發與建置

```bash
python3 -m venv .venv-1.8.8
.venv-1.8.8/bin/python -m pip install -r requirements.txt
.venv-1.8.8/bin/python -m pip install -r requirements-test.txt
.venv-1.8.8/bin/python -m unittest discover -s tests -v
PATH="$PWD/.venv-1.8.8/bin:$PATH" ./scripts/build_1_8_8.sh
```

建置腳本會把唯一一組 `ffmpeg` 與 `ffprobe` 放入 `Contents/Helpers/`，設定 App 版本資訊並執行 arm64、工具版本、授權設定與簽章檢查。

Swift 2.0 使用獨立的 `scripts/build_swift_2.sh` 與 `scripts/check_swift_bundle.py`；不要用 Python/PyInstaller 建置腳本覆蓋 Swift App，也不要讓 Swift 發布流程修改 Windows `1.8.x` 資產。

## 第三方工具與授權

下載核心使用 [yt-dlp](https://github.com/yt-dlp/yt-dlp)，影音合併與 MP3 轉換使用 [FFmpeg](https://ffmpeg.org/)，YouTube JavaScript challenge 使用 [QuickJS](https://bellard.org/quickjs/)。完整來源與建置資訊記錄於 `THIRD_PARTY_NOTICES.md` 及對應工具說明。

本專案不授予下載第三方影音內容的權利。請只下載自己擁有、已獲授權，或法律允許保存的內容。
