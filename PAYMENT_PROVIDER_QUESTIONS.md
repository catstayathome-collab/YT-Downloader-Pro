# ECPay Product And Recurring-Payment Approval Request

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for owner review; not submitted |
| Intended recipient | ECPay merchant support or compliance review |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-08-26 |
| Submission rule | Do not submit without a fresh explicit owner approval |

This document contains no password, identity number, Merchant ID, HashKey,
HashIV, API secret, bank information, or Google credential. Those values must
never be added to the repository, an issue, a support attachment, or an email.

## 1. Purpose

Obtain a written, product-specific answer from ECPay before YT Downloader Pro
implements or enables production payments. General account enablement, a phone
conversation, or documentation showing that recurring payments exist is not
sufficient evidence.

The response must confirm whether the disclosed product and business model may
use the owner's current merchant account and recurring credit-card service.

## 2. Chinese Submission Draft

### Subject

申請確認桌面軟體訂閱服務之商品類別與信用卡定期定額收款資格

### Message

綠界科技客服／審查團隊您好：

我是綠界的個人賣家，目前正在規劃一款名為「YT Downloader Pro」的
macOS 桌面應用程式，未來可能另行提供 Windows 版本。在正式開發與啟用
付費系統前，希望先以書面方式確認此產品及訂閱模式是否符合綠界的收款與
交易管理規範。

產品的實際功能如下：

- 使用者在自己的電腦貼上影音頁面網址，由安裝於使用者電腦上的程式解析、
  下載及合併影音。
- 下載與轉檔均在使用者裝置本機執行；我們的伺服器不代理、不下載、不保存、
  不轉傳影音檔案。
- 使用者必須自行確認其對下載內容具有所有權、授權，或依法得保存使用。
- 產品不宣稱與 YouTube 或 Google 有合作、授權或官方關係。
- 產品不保證能下載付費、私人、會員限定、DRM 或受地區限制的內容，也不以
  規避著作權或存取控制作為商品訴求。

預計商業模式如下：

- 免費版：單支影片下載，最高畫質 720p，並提供基本安全更新與錯誤處理。
- Pro 訂閱：每月新臺幣 80 元，提供較高畫質選項（包含來源可用時的
  1080p、1440p 或 4K）、批次網址、播放清單、進階字幕、格式預設、完整
  自動重試、選擇性歷史同步及非即時的優先支援。
- 使用者預計透過 Google 登入辨識會員；Google 不負責付款判斷。付款狀態
  由我們的後端依綠界授權結果管理。
- 取消訂閱後不再進行下一期扣款；已付款期間及退款方式會在購買頁面明確
  說明。

為避免商品分類錯誤或日後收款被中止，敬請以書面回覆以下問題：

1. 上述桌面軟體及影音下載工具是否屬於綠界允許收款的商品／服務類別？
2. 若允許，正確的商品／服務分類名稱應為何？申請或審查時應提供哪些說明、
   網頁、圖片、條款或其他文件？
3. 現有個人賣家身分是否可以使用信用卡定期定額 API 收取每月 80 元訂閱費？
   是否必須先升級為商務賣家、特約賣家或完成其他專案審查？
4. 目前帳號顯示信用卡收款已開通，是否仍需就本產品另行申請商品審查、
   定期定額、綁卡或幕後授權服務？
5. 個人賣家可使用哪些建立訂單、定期授權結果通知、訂單查詢、退刷、取消及
   重新授權 API？哪些功能僅限特約賣家？
6. 每次定期授權成功或失敗時，綠界是否會向指定伺服器端網址發送通知？
   通知失敗的重送政策、簽章驗證及查詢對帳方式為何？
7. 使用者取消訂閱後，商家應透過哪一項 API 或後台操作停止後續授權？
   取消生效時間及已建立期數的處理規則為何？
8. 目前適用的信用卡定期定額費率、固定費用、設定費、年費、最低費用、
   撥款天期及保留款規則為何？
9. 交易失敗、連續扣款失敗、退款、部分退款、退刷、拒付及爭議款的處理流程、
   費用與商家應保存的證明文件為何？
10. 個人賣家的單筆、每日及 30 日收款額度如何計算？退款、失敗交易及跨月
    定期扣款是否計入額度？接近額度前是否有通知或升級流程？
11. 購買頁面必須顯示哪些商家資訊、商品內容、定期扣款條款、取消方式、
    退款政策及客服資訊？
12. 電子發票或收據應如何處理？綠界是否要求完成稅籍、商業或公司登記後
    才能提供此類軟體訂閱？
13. 若網站使用 Google 登入，並由我們的後端保存會員編號及訂閱狀態，綠界
    對隱私權政策、個資告知、資訊安全或 PCI DSS 責任有何額外要求？
14. 若將來修改價格、增加年繳方案、增加 Windows 版本或調整付費功能，是否
    需要重新送審？
15. 若綠界不承作此類商品，敬請明確告知不符合的規範或商品類別，讓我們在
    開發正式付款系統前停止或調整計畫。

我們願意提供公開的中文產品介紹頁、價格、服務條款、隱私權政策、取消與
退款說明、應用程式畫面及測試版供審查。為避免理解差異，也懇請回覆時明確
寫明是針對上述「本機執行的第三方影音下載桌面軟體及其訂閱功能」進行判斷，
而不只是一般性說明綠界具備定期定額功能。

謝謝協助。

YT Downloader Pro
產品負責人：翁大洲（Ta-Chou Weng）

## 3. Required Attachments Before Submission

Do not attach credentials or internal source code. Prepare only these reviewed
materials:

- Public Chinese product-description page or a non-indexed review page.
- Pricing table showing Free and Pro differences.
- Screenshots of the macOS application without user download history.
- Draft Terms of Use and Acceptable Use Policy.
- Draft Privacy Policy and data-flow summary.
- Draft cancellation, refund, and customer-support policy.
- A statement that media transfer and processing occur locally.

Every screenshot must be checked for email addresses, local file paths, video
history, browser profiles, tokens, and other personal data before attachment.

## 4. Answers Required For A Go Decision

An acceptable response must explicitly resolve all of these categories:

| Category | Required evidence |
| --- | --- |
| Product eligibility | Written confirmation naming or clearly describing the disclosed desktop downloader |
| Merchant status | Whether the existing seller type is sufficient and any required upgrade |
| Recurring capability | Exact approved recurring product/API and prerequisites |
| Technical integration | Callback, query, cancellation, retry, signature, and test-environment rules |
| Commercial terms | Actual fees, settlement, limits, reserves, refunds, and chargebacks |
| Consumer disclosures | Required checkout, recurring, cancellation, refund, and support text |
| Tax/invoice prerequisite | Registration and invoice expectations stated by ECPay, subject to accountant confirmation |
| Change control | Events that require re-review or a new application |

A generic response such as "ECPay supports subscriptions" does not satisfy the
gate. Follow up until the product category and current merchant account are
addressed, or mark the payment-provider gate as failed.

## 5. Response Record

Complete this table only after an actual response is received. Preserve the
original message or ticket export under a future private compliance evidence
location; do not paste sensitive account data into this file.

| Field | Value |
| --- | --- |
| Submitted date | Not submitted |
| Submission channel | Not submitted |
| ECPay ticket/reference | Not submitted |
| Responding team/name | Not submitted |
| Response date | Not submitted |
| Product explicitly accepted | Unknown |
| Recurring payment accepted | Unknown |
| Required merchant upgrade | Unknown |
| Conditions or restrictions | Unknown |
| Follow-up required | Yes |
| Evidence location | Not available |

## 6. Submission Procedure

1. The owner reviews and approves this exact draft.
2. Replace no fields with passwords, identity numbers, keys, or bank data.
3. Prepare and privacy-review the required attachments.
4. Submit through the authenticated ECPay support channel.
5. Save the original outbound text, timestamp, ticket number, and attachments.
6. Save every response without editing its meaning.
7. Update the response record and `COMMERCIAL_FEASIBILITY.md` launch gate.
8. If the answer is ambiguous, send a focused follow-up instead of treating it
   as approval.
9. Do not begin production billing implementation until the response is
   unambiguous and the separate legal-review gate is also satisfied.

## 7. Primary References

- [ECPay recurring and subscription service](https://www.ecpay.com.tw/IntroRecurringPayment/)
- [ECPay recurring-payment management](https://support.ecpay.com.tw/16214/)
- [ECPay recurring-payment integration documentation](https://developers.ecpay.com.tw/2868/)
- [ECPay merchant-backend guide](https://support.ecpay.com.tw/wp-content/uploads/2025/05/%E7%B6%A0%E7%95%8C%E7%A7%91%E6%8A%80%E5%BB%A0%E5%95%86%E7%AE%A1%E7%90%86%E5%BE%8C%E5%8F%B0%E6%93%8D%E4%BD%9C%E6%89%8B%E5%86%8A_V1.1.10_20250506.pdf)
- [ECPay member terms revision summary](https://support.ecpay.com.tw/wp-content/uploads/2025/05/%E4%BF%AE%E6%AD%A3%E5%B0%8D%E7%85%A7%E7%B8%BD%E8%AA%AA%E6%98%8E_GW250505BS1.pdf)
