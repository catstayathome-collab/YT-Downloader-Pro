# YT Downloader Pro Commercial Feasibility

## Document Control

| Field | Value |
| --- | --- |
| Status | Approved Phase 1 decision baseline |
| Decision | Conditional Go for validation only; No-Go for paid launch |
| Owner | Ta-Chou Weng |
| Last reviewed | 2026-08-26 |
| Owner approval | Approved on 2026-08-26 for Phase 1 validation work only |
| Next review | After written payment-provider and legal responses |

This document is a product and engineering decision record. It is not legal,
tax, accounting, or financial advice. A qualified Taiwan lawyer and accountant
must review the final operating model before public sales begin.

## 1. Executive Decision

YT Downloader Pro may proceed with a landing page, waitlist, closed product
testing, documentation, and non-payment technical preparation. It must not
accept subscription payments or advertise paid availability until every launch
gate in section 10 has evidence attached.

The current decision separates three questions that must not be conflated:

1. The application is technically capable of providing the proposed features.
2. ECPay is technically capable of recurring credit-card billing.
3. ECPay, applicable law, and relevant platform terms permit this specific
   product to be sold using the proposed claims and operating model.

Only the first two are presently supported. The third remains unresolved.

## 2. Product Definition Under Review

YT Downloader Pro is a desktop application distributed outside the Mac App
Store. Media processing occurs on the user's device. The proposed service does
not proxy, host, or retain downloaded media on YT Downloader Pro servers.

The intended audience is users saving content that they own, have permission to
use, or are otherwise legally permitted to preserve. The product must not claim
that it grants download rights, bypasses copyright, or makes every YouTube video
legally downloadable.

The proposed public offer is:

| Capability | Free | Pro at NT$80/month |
| --- | --- | --- |
| Maximum video resolution | 720p | Highest available, including 1080p/1440p/4K |
| Single-video download | Included | Included |
| Batch URLs and playlists | Not included | Included |
| Advanced subtitles | Basic or not included | Included |
| Format presets | Basic defaults | Included |
| Automatic retry and controlled recovery | Safety-critical minimum | Full policy |
| Local history | Included | Included |
| Optional history synchronization | Not included | Included, opt-in only |
| Support | Community/self-service | Asynchronous priority support |

Safety, privacy, security updates, actionable error messages, and fixes needed
to keep the free version functional must never be paywalled. The paid plan may
offer greater convenience and capability, but not weaker safety for free users.

## 3. Confirmed Decisions

- macOS remains the native Swift `2.x` product line.
- Windows remains the Python `1.8.x` product line until separately redesigned.
- macOS distribution is outside the Mac App Store.
- Pro is proposed as a recurring NT$80 monthly subscription.
- Free downloads are capped at 720p; Pro may select higher resolutions.
- Pro also includes batch downloads, playlists, advanced subtitles, presets,
  full automatic retry, optional history synchronization, and priority support.
- Authentication may use Google OpenID Connect, but paid entitlement is owned
  by the YT Downloader Pro backend, not by Google.
- Download failures use a documented controlled recovery ladder. The product
  does not silently switch to unreviewed third-party download services.
- No paid-system implementation begins before written approval is obtained.
- Documentation, tests, release runbooks, and ownership boundaries are required
  parts of the product rather than post-launch cleanup.

## 4. Evidence Confirmed As Of 2026-08-26

### 4.1 ECPay account observation

A read-only review of the owner's ECPay dashboard showed completed email,
identity, and bank verification and enabled credit-card collection. The account
was shown as a personal seller with a rolling 30-day collection limit of
NT$200,000.

This observation is operational context, not approval for YT Downloader Pro.
The account state and limit must be rechecked immediately before any launch.
ECPay publicly documents subscription/recurring-payment support and authorization
callbacks, but some functions or merchant categories may require separate
review or special approval.

### 4.2 macOS distribution

Apple permits software to be distributed outside the Mac App Store. A public
release must use Developer ID signing, hardened runtime, notarization, stapling,
and release-package verification. Apple explains that Gatekeeper checks
Developer ID software and that notarization scans signed software before
distribution.

### 4.3 Platform-policy risk

YouTube's API Services Developer Policies state that an API client must not,
without YouTube's prior written approval, download, import, back up, cache, or
store copies of YouTube audiovisual content or make it available for offline
playback. The legal reviewer must determine how these policies, YouTube's Terms
of Service, the application's actual extraction method, user authorization, and
Taiwan law apply to this product. The project must not infer permission merely
because competing download services exist.

### 4.4 Third-party licensing

The distributed yt-dlp artifact and every other bundled helper require a
release-specific license inventory. yt-dlp's official README states that its
PyInstaller-bundled executables contain GPLv3+ code and that the combined work
is GPLv3+. Commercial distribution is not automatically prohibited by GPL, but
the project must satisfy all applicable source, notice, license, and
redistribution obligations. A lawyer must review the final bundle composition.

## 5. Feasibility Assessment

| Area | Rating | Current assessment |
| --- | --- | --- |
| Desktop product | High | Swift 2.0 already supplies a strong technical base. |
| Account and entitlement backend | High | Standard architecture; not yet implemented. |
| Google authentication | High | Use system-browser OIDC with PKCE and immutable `sub`. |
| ECPay recurring billing | Medium | Technically supported; product approval and exact contract terms unresolved. |
| Outside-App-Store distribution | High | Requires Developer ID signing and notarization. |
| Legal/platform permission | Low/unknown | Largest launch risk; written professional review is mandatory. |
| Unit economics at NT$80 | Medium | Viable only with low support cost and sufficient retention. |
| Reliability over time | Medium | yt-dlp and YouTube behavior require continuous maintenance. |

Overall status: **Conditional Go for validation; No-Go for paid public launch.**

## 6. Revenue Model

Monthly recurring revenue before fees, refunds, tax, infrastructure, support,
and the owner's labor is:

`gross MRR = active paid subscribers x NT$80`

| Active paid subscribers | Gross MRR |
| ---: | ---: |
| 50 | NT$4,000 |
| 100 | NT$8,000 |
| 250 | NT$20,000 |
| 500 | NT$40,000 |
| 625 | NT$50,000 |
| 1,000 | NT$80,000 |
| 2,500 | NT$200,000 |
| 5,000 | NT$400,000 |

The 625-subscriber and 2,500-subscriber rows are operational warning points,
not targets. At NT$80, 625 subscribers produce NT$50,000 monthly sales, which
may meet Taiwan's current service-sales tax-registration threshold. At 2,500
subscribers, gross monthly sales equal the ECPay account limit observed during
the 2026-08-26 review. An accountant and ECPay must confirm how refunds,
settlement timing, tax classification, and rolling limits are calculated.

The maintainable net-revenue model is:

`net contribution = collected revenue - payment fees - refunds/chargebacks`
`                   - tax - hosting/monitoring - support labor - maintenance`

No net-income promise may be published until the following inputs are known:

- ECPay's actual contracted percentage and fixed fees.
- Recurring authorization failure and retry behavior.
- Refund, chargeback, and fraud rates.
- Tax registration, invoice, and business-entity requirements.
- Hosting, email, monitoring, backup, and incident-response costs.
- Median support minutes per active subscriber.
- Monthly subscriber churn.

At NT$80, manual support is the main unit-economics threat. "Priority support"
must mean a documented asynchronous response target, not unlimited real-time
support or guaranteed resolution of upstream YouTube failures.

## 7. Instagram Demand Validation

Follower count and Reel views are not revenue. The primary funnel is:

`qualified landing-page visitors x paid conversion rate = new subscribers`

A rough steady-state model, after enough time and assuming stable acquisition,
is:

`active subscribers ~= monthly new subscribers / monthly churn rate`

Before payment development, an honest landing page and waitlist should measure:

- Unique visits from the `catstayathome` profile link.
- Waitlist completion rate.
- Device and operating-system mix.
- Willingness to pay NT$80 per month.
- Which Pro benefits actually change purchase intent.
- Expected download frequency and support needs.

No fabricated countdowns, false scarcity, hidden recurring terms, or claims of
guaranteed compatibility are allowed. A useful Phase 1 signal is at least 100
qualified waitlist registrations and 20 to 30 explicit purchase-intent
responses, but this is a validation threshold, not proof of future revenue.

## 8. Risk Register

| Risk | Severity | Required mitigation before launch |
| --- | --- | --- |
| ECPay rejects or later suspends the product category | Critical | Written description-specific approval; provider-neutral billing adapter; shutdown plan. |
| YouTube/platform terms conflict with the product | Critical | Taiwan legal opinion and deliberately narrowed product claims/scope. |
| Copyright complaints or misuse | Critical | Acceptable-use policy, notice process, records, and clear user authorization terms. |
| Payment credentials leak from the app | Critical | Secrets remain server-side; rotation, least privilege, and incident runbook. |
| Google account becomes the only recovery path | High | Account recovery and a reviewed alternative login path. |
| yt-dlp or YouTube changes break downloads | High | Controlled recovery ladder, signed tool updates, canary tests, rollback. |
| GPL or helper-license obligations are missed | High | Software bill of materials and legal review of every release artifact. |
| NT$80 cannot fund support | High | Bounded support policy, self-service diagnostics, measure support minutes. |
| History synchronization exposes sensitive activity | High | Opt-in only, data minimization, deletion/export, retention limits, encryption. |
| Personal brand receives complaints | High | Transparent marketing, prompt support, status page, refund and incident policies. |

## 9. Phase 1 Allowed And Prohibited Work

Allowed before approval:

- Create and review the commercial, payment, legal, privacy, entitlement, and
  recovery documents.
- Prepare an honest landing-page draft and a waitlist without accepting money.
- Collect aggregate funnel measurements with consent-aware analytics.
- Conduct free closed-beta testing and reliability work.
- Prepare Developer ID signing and notarization.
- Inventory dependencies and licenses.

Prohibited before approval:

- Enable production checkout or recurring charges.
- Store production ECPay secrets in any client, repository, or test fixture.
- Advertise the Pro subscription as available for purchase.
- Claim legal permission, official YouTube affiliation, or guaranteed access.
- Collect cloud download history before privacy design and explicit consent.
- Implement a fallback that sends URLs, cookies, or media to an unreviewed
  third-party service.

## 10. Paid Launch Gates

Every item requires a dated evidence link, file, ticket, or signed opinion.
Verbal assurances and screenshots of general account enablement are not enough.

- [ ] ECPay confirms in writing that the exact described desktop application
      and recurring NT$80 subscription may use the merchant account.
- [ ] ECPay confirms the allowed merchant category, recurring APIs/callbacks,
      fees, limits, settlement, refunds, chargebacks, and cancellation process.
- [ ] A Taiwan lawyer reviews YouTube/platform terms, copyright exposure,
      product naming, marketing copy, Terms of Use, Acceptable Use Policy,
      privacy policy, refund terms, and complaint handling.
- [ ] A Taiwan accountant confirms registration, invoice, tax, and entity
      requirements for the intended launch volume.
- [ ] A licensing review covers yt-dlp, FFmpeg, FFprobe, QuickJS/JavaScript
      components, Swift packages, website dependencies, and release artifacts.
- [ ] The owner approves measured waitlist demand and a conservative cost model.
- [ ] The macOS release is Developer ID signed, notarized, stapled, and tested on
      clean supported Macs; the Windows release has an explicit signing plan.
- [ ] Privacy threat model, deletion/export flow, credential rotation, backup,
      incident response, refund, cancellation, and service shutdown are tested.
- [ ] The owner signs a final Go decision that links to all evidence above.

## 11. Stop Conditions

The commercial project returns to No-Go if any of the following occurs:

- ECPay declines the disclosed product or will not provide written confirmation.
- Legal review concludes the proposed operating model is not reasonably
  defensible without permissions that have not been obtained.
- A required license obligation cannot be met.
- The entitlement service would require collecting unnecessary download URLs,
  browser cookies, or media content.
- The measured support and infrastructure cost cannot fit the NT$80 price.
- Marketing must conceal the product's function to obtain payment approval.

## 12. Phase 1 Document Set

This decision is implemented by the following reviewable documents:

- `PAYMENT_PROVIDER_QUESTIONS.md`: exact ECPay product disclosure and questions;
  it remains unsubmitted until fresh owner approval.
- `LEGAL_REVIEW_BRIEF.md`: facts and questions for qualified Taiwan counsel.
- `PRIVACY_DATA_MAP.md`: current and proposed data inventory and boundaries.
- `PRIVACY_THREAT_MODEL.md`: macOS Swift 2.x privacy assets, trust boundaries,
  implemented controls, and blocked launch gates.
- `SUPPORT_REPORT_AND_DATA_REQUESTS.md`: user-reviewed support report payloads,
  local export and deletion rules, and future backend data-request gates.
- `OPERATIONS_RUNBOOK.md`: credential rotation, backup/restore, incident
  response, cancellation/refund handling, and shutdown drills.
- `ENTITLEMENT_ARCHITECTURE.md`: account, billing, subscription, and feature
  grant contracts; implementation remains blocked by launch gates.
- `RECOVERY_LADDER.md`: bounded local recovery, retry, client, cookie, and
  optional PO Token provider policy.
- `REPOSITORY_AND_SUPPORT_STRATEGY.md`: private development/public release
  split, repository migration gates, and privacy-safe feedback design.

No external submission, repository visibility change, checkout, or production
account action is authorized merely because these documents exist.

## 13. Primary References

- [Apple: Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [Apple: Signing Mac software with Developer ID](https://developer.apple.com/developer-id/)
- [YouTube API Services Developer Policies](https://developers.google.com/youtube/terms/developer-policies)
- [ECPay recurring and subscription payment service](https://www.ecpay.com.tw/IntroRecurringPayment/)
- [ECPay recurring-payment management](https://support.ecpay.com.tw/16214/)
- [ECPay member terms revision summary](https://support.ecpay.com.tw/wp-content/uploads/2025/05/%E4%BF%AE%E6%AD%A3%E5%B0%8D%E7%85%A7%E7%B8%BD%E8%AA%AA%E6%98%8E_GW250505BS1.pdf)
- [Taiwan Ministry of Finance: Online transaction tax regulations](https://www.etax.nat.gov.tw/etwmain/tax-info/network-transaction-taxtation-area/regulation)
- [Taiwan Ministry of Finance: Notes for domestic online sellers](https://www.etax.nat.gov.tw/etwmain/tax-info/network-transaction-taxtation-area/seller/notice)
- [yt-dlp README and licensing notes](https://github.com/yt-dlp/yt-dlp/blob/master/README.md)
