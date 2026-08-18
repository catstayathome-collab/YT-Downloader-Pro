# Python 版本來源索引

這個資料夾集中保存 YT Downloader Pro 已建立獨立檔名的 Python 主程式入口。檔案適合用來比較入口與版本號；要取得某次發布的完整版本，請使用對應的 Git tag，因為 `1.8.7` 之後的入口會共用專案根目錄中的 `ytdp/`。

| 版本 | 此資料夾中的入口 | Git tag | 說明 |
| --- | --- | --- | --- |
| 1.8.0 | `v1.8.0/YT_downloader_180.py` | `v1.8.0-original` | 維護前原始版本。 |
| 1.8.1 | 無獨立檔名 | `v1.8.1` | 當時仍使用 `YT_downloader_180.py`。 |
| 1.8.2 | 無獨立檔名 | `v1.8.2` | 當時仍使用 `YT_downloader_180.py`。 |
| 1.8.3 | 無獨立檔名 | `v1.8.3` | 當時仍使用 `YT_downloader_180.py`。 |
| 1.8.4 | 無獨立檔名 | `v1.8.4` | 當時仍使用 `YT_downloader_180.py`。 |
| 1.8.5 | `v1.8.5/YT_downloader_185.py` | `v1.8.5` | 後補建立的版本化來源檔。 |
| 1.8.6 | `v1.8.6/YT_downloader_186.py` | `v1.8.6` | 加入公開更新 manifest。 |
| 1.8.7 | `v1.8.7/YT_downloader_187.py`、`YT_downloader_187_windows.py` | `v1.8.7` | macOS 入口與後續加入的 Windows 入口。 |
| 1.8.8 | `v1.8.8/YT_downloader_188.py`、`YT_downloader_188_windows.py` | `v1.8.8` | 目前 macOS 與 Windows 正式版本入口。 |

1.8.1 至 1.8.4 在當時沒有建立獨立版本檔名，因此這裡不複製內容相近但不能代表完整發布狀態的檔案。請切換到表格中的 Git tag 查看完整版本。

## 建置規則

- macOS 與 Windows 建置腳本直接使用對應版本資料夾中的入口。
- 版本入口不得重新放回專案根目錄。
- `ytdp/` 是目前共用核心，不能只複製入口檔來宣稱已保存完整版本。
- 新版本應建立 `versions/vX.Y.Z/`，加入平台入口，再同步更新本索引、建置腳本與測試。
