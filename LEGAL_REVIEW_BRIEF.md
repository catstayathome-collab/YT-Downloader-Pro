# YT Downloader Pro Legal Review Brief

## Document Control

| Field | Value |
| --- | --- |
| Status | Draft for independent Taiwan counsel review |
| Product owner | Ta-Chou Weng |
| Prepared | 2026-08-26 |
| Jurisdiction focus | Taiwan, with platform-contract and distribution issues |
| Decision rule | No paid launch without a written legal opinion |

This brief gives counsel facts and questions. It does not state that the product
is lawful, compliant, or approved. Counsel should verify the current law,
platform terms, product build, marketing copy, and operating process rather
than relying only on this summary.

## 1. Requested Work Product

Please provide a dated written opinion that:

- Identifies the reviewed product version, facts, URLs, agreements, and laws.
- Separates copyright law, contract/platform terms, consumer law, privacy,
  trademark/marketing, open-source licensing, and payment-provider risk.
- States which conclusions are reasonably clear and which remain uncertain.
- Lists mandatory product, marketing, contractual, or operational changes.
- Gives an explicit recommendation: Go, Conditional Go, or No-Go.
- States what changes would require a new review.

A verbal discussion is useful but does not satisfy the project's paid-launch
gate.

## 2. Product Facts

YT Downloader Pro is a desktop application currently developed for macOS in
Swift. A separate Windows Python edition exists but commercial work will remain
paused until the macOS product is stable.

The application:

- Accepts a user-supplied YouTube or supported media URL.
- Uses bundled yt-dlp to analyze and download available streams.
- Uses bundled FFmpeg/FFprobe to merge video and audio or produce MP3 output.
- May use a JavaScript runtime/helper required by current YouTube extraction.
- Downloads and processes media on the user's computer.
- Does not currently proxy, host, or retain media on an operator server.
- Supports single downloads, multiple jobs, playlists, subtitles, thumbnails,
  metadata, format selection, retries, pause/resume, and local history.
- Can save publicly accessible audiovisual content even when the content owner
  has not separately contacted the operator.
- Does not determine whether the user owns or is licensed to save each item.
- Does not remove DRM by design and does not promise access to paid, private,
  membership-only, or geographically restricted content.
- May optionally use browser cookies only after explicit user selection. Cookies
  remain local and are not intended to be uploaded to the operator.

## 3. Proposed Commercial Model

The proposed offer is:

- Free: single-video downloads up to 720p and core safety/reliability updates.
- Pro: NT$80 per month for higher available resolutions such as 1080p, 1440p,
  and 4K, plus batch URLs, playlists, advanced subtitles, presets, full retry,
  optional history synchronization, and asynchronous priority support.
- Authentication: Google OpenID Connect or another reviewed account-recovery
  path.
- Payment: ECPay recurring credit-card service, subject to written approval.
- Distribution: direct website download, not the Mac App Store.
- Marketing: primarily the owner's `catstayathome` Instagram audience.

No checkout or production entitlement system has been implemented. The current
commercial decision is Conditional Go for validation and No-Go for paid launch.

## 4. Platform And Contract Facts To Review

YouTube's Terms of Service currently restrict downloading or otherwise using
Service content except when the Service permits it, YouTube and relevant rights
holders give prior written permission, or applicable law permits it. The terms
also restrict interference with copying/access controls and automated access,
subject to stated exceptions.

YouTube's API Services Developer Policies separately state that API clients
must not download, import, back up, cache, or store copies of YouTube audiovisual
content or make it available for offline playback without prior written
approval. Counsel must determine which agreements and policies apply to the
product's actual non-official extraction method, the operator, and users.

The legal opinion must not assume that:

- Local processing removes platform-contract or copyright risk.
- A user's private-use exception authorizes the operator to sell the tool.
- Public accessibility means unrestricted permission to reproduce.
- The absence of DRM means the download is contractually permitted.
- Competing downloader products establish legality or industry approval.
- A disclaimer alone cures a product whose ordinary use creates liability.

## 5. Taiwan Copyright Questions

Taiwan Copyright Act Article 51 provides a limited private/family,
non-commercial reproduction rule within a reasonable scope. Article 80-2
regulates circumvention of technological protection measures and providing
circumvention equipment, technology, information, or services. Counsel should
review the current full Act, exceptions, cases, and the actual technical flow.

Please answer:

1. Under what circumstances, if any, may an individual user save audiovisual
   content using this product under Taiwan law?
2. Does selling a general-purpose downloader create direct, contributory,
   inducement, assistance, or other liability even where some uses are lawful?
3. Does charging specifically for higher resolution, playlists, and automation
   materially increase risk compared with a free general-purpose tool?
4. Are any yt-dlp client, signature, JavaScript challenge, PO Token, cookie, or
   fallback behaviors legally treated as circumvention or interference with a
   technological protection measure?
5. Which sources or categories must the product refuse, including DRM, paid,
   private, membership, age-restricted, or region-restricted content?
6. Is a user representation of ownership/permission meaningful, and what
   additional controls are needed to avoid relying on a checkbox alone?
7. Should the product be limited to creator backups, user-owned channels,
   licensed URLs, Creative Commons content, or another narrower scope?
8. What complaint, takedown, repeat-misuse, evidence-preservation, and appeal
   process should a Taiwan-based operator maintain?
9. Does optional cloud history change the operator's exposure even if media is
   never uploaded?
10. What records should be retained or deliberately not retained to balance
    complaint handling, privacy, and legal obligations?

## 6. Contract And Product-Scope Questions

Please answer:

1. Can this product be offered consistently with the applicable YouTube Terms
   without obtaining YouTube's written permission?
2. Does the operator's method of accessing public webpages or media endpoints
   create a separate automated-access or anti-circumvention contract issue?
3. Would requiring users to agree to YouTube's terms change the operator's risk?
4. Is there a defensible narrower product focused on creator-owned or expressly
   licensed content, and how would that authorization be verified?
5. Should YouTube URLs be supported at all in a paid product if permission is
   unavailable?
6. What language must be removed from product pages, screenshots, social posts,
   app dialogs, and support responses?
7. What events should trigger immediate suspension of sales or functionality?

## 7. Consumer Protection And Subscription Questions

The service is proposed as a recurring digital subscription sold by distance
transaction. Taiwan's Consumer Protection Act and the rules governing reasonable
exceptions to distance-transaction withdrawal rights require specific review.
The digital-content/online-service exception may depend on clear prior notice
and consumer consent before service begins; it must not be assumed to apply
automatically to a continuing subscription.

Please answer:

1. What information must appear before checkout: seller identity, contact
   method, total price, recurring interval, renewal, functionality, system
   requirements, upstream limitations, cancellation, and complaint process?
2. Does the seven-day withdrawal right apply to the app, subscription, or any
   part of the service, and what exact consent is needed for an exception?
3. What refund rights apply when YouTube or yt-dlp changes make a paid feature
   temporarily or permanently unavailable?
4. Can the service stop future renewal immediately while retaining paid access
   through the current period?
5. What notice and consent are required for price or feature changes?
6. What wording would be unfair, misleading, or unenforceable in a standard-form
   contract?
7. What service-level promise is safe for "priority support" at NT$80/month?
8. Are minors permitted to subscribe, and what age/guardian controls are needed?
9. What records are needed to prove recurring-payment consent and cancellation?
10. What shutdown/refund duties apply if ECPay or YouTube access is terminated?

## 8. Privacy And Security Questions

The planned account system may process Google subject identifiers, email,
subscription state, payment references, support messages, device/app metadata,
and optional synchronized history. It must not receive browser cookies or media.

Taiwan's Personal Data Protection Act requires a valid purpose/basis for private
entities processing personal data and appropriate security measures for stored
personal-data files. Counsel should review the final data map, vendors,
cross-border transfers, notices, retention, access, deletion, and incident plan.

Please answer:

1. What collection notices and consent/basis are required for each data class?
2. May immutable Google `sub` be used as the primary identity while email is
   treated as changeable contact data?
3. What data-subject access, correction, deletion, export, and account-closure
   process is required?
4. What retention periods apply to subscription, tax, payment, support, security,
   diagnostic, and optional history records?
5. What processor/vendor agreements and cross-border disclosures are required?
6. What breach notification and evidence-preservation duties apply?
7. Can support diagnostics contain URLs, titles, file paths, IP addresses, or
   device identifiers, and what opt-in/redaction controls are required?
8. Should optional history synchronization be postponed until after launch?

## 9. Trademark, Naming, And Marketing Questions

Please review:

- The names `YT Downloader Pro` and `YouTube Downloader Pro`.
- App icon, screenshots, YouTube name/logo references, and comparison claims.
- Whether `YT` is likely to imply affiliation or create trademark risk.
- Required non-affiliation wording and where it must appear.
- Use of actual videos, thumbnails, creators, comments, or channel names in
  marketing and screenshots.
- Instagram promotions, testimonials, influencer disclosures, giveaways, and
  price/feature claims under Taiwan advertising and fair-trade rules.

Marketing must not say "legal YouTube downloader," "official," "always works,"
"download any video," or another categorical claim without a reviewed factual
and legal basis.

## 10. Open-Source And Distribution Questions

The distributed app bundles or may bundle yt-dlp, FFmpeg, FFprobe, QuickJS or
another JavaScript runtime, yt-dlp JavaScript components, and Swift packages.
yt-dlp's official README states that PyInstaller-bundled releases include
GPLv3+ code and that the combined work is GPLv3+; other artifacts have different
licenses. FFmpeg licensing depends on its build configuration.

Please determine for the exact release artifacts:

1. Whether the app and bundled helpers are separate works, aggregates, or a
   combined/derivative work under each applicable license.
2. Which source, written offer, installation information, notices, license
   texts, attribution, relinking, or modification disclosures are required.
3. Whether the Swift application source may remain private and what
   Corresponding Source must be delivered to binary recipients.
4. Whether the current repository history and already-public releases create
   continuing obligations.
5. Whether any component or build option creates GPL, LGPL, non-free codec,
   patent, trademark, or commercial-distribution concerns.
6. What Software Bill of Materials and release archive must be retained.

Repository privacy must not be used to conceal or avoid license obligations.

## 11. Payment And Business-Entity Questions

Please coordinate with an accountant where appropriate and answer:

- Whether the operator may begin as an individual seller.
- When business/tax registration and invoices become mandatory.
- Which seller identity and contact details must be public.
- Whether ECPay's written product approval changes none of the operator's
  independent legal duties.
- Whether liability, insurance, contract, or tax considerations justify forming
  a business entity before paid launch.
- How refunds, chargebacks, disputed recurring payments, and reserves should be
  addressed in the Terms and records.

## 12. Draft Documents Counsel Must Review

Before final Go, counsel must review the final versions of:

- Product and pricing page.
- Terms of Use / EULA.
- Acceptable Use Policy.
- Privacy Policy and cookie notice.
- Subscription, renewal, cancellation, and refund terms.
- Support policy and diagnostic consent.
- Copyright complaint and misuse process.
- In-app onboarding, login, paywall, error, and cancellation text.
- Instagram launch posts, claims, screenshots, and FAQ.
- ECPay written response and merchant terms.
- Dependency inventory, licenses, and exact signed release artifact.

## 13. Evidence Record

Do not store privileged legal advice in a future public repository. Record only
the decision metadata here and keep the opinion in a restricted evidence store.

| Field | Value |
| --- | --- |
| Counsel/law firm | Not selected |
| Engagement date | Not started |
| Materials supplied | Not supplied |
| Opinion date | Not available |
| Recommendation | Unknown |
| Mandatory changes | Unknown |
| Re-review triggers | Unknown |
| Restricted evidence location | Not available |
| Owner final decision | No-Go pending opinion |

## 14. Primary References

- [YouTube Terms of Service](https://www.youtube.com/t/terms)
- [YouTube API Services Developer Policies](https://developers.google.com/youtube/terms/developer-policies)
- [Taiwan Intellectual Property Office: Copyright Act](https://www.tipo.gov.tw/tw/copyright/693-8432.html)
- [Taiwan Copyright Act Article 51](https://www.tipo.gov.tw/tw/copyright/694-17686.html)
- [Taiwan Copyright Act Article 80-2](https://www.tipo.gov.tw/tw/copyright/694-17503.html)
- [Executive Yuan: Reasonable Exceptions to Distance Transaction Rescission](https://www.ey.gov.tw/Page/4FF303AE95592945/80289438-3b0c-456b-a79d-1f93cbbc6aa4)
- [Executive Yuan interpretation on clear notice for digital content/services](https://www.ey.gov.tw/Page/24C4B877E850ED4E/d09b1f97-08be-4e98-9726-3417fce28004)
- [Ministry of Justice: Personal Data Protection Act](https://mojlaw.moj.gov.tw/ENG/LawContentE.aspx?LSID=FL010627)
- [yt-dlp README and licensing notes](https://github.com/yt-dlp/yt-dlp/blob/master/README.md)
