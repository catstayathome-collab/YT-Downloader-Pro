# YT Downloader Pro 1.8.7 Full-Size App Icon Design

## Goal

Replace the undersized 1.8.7 icon artwork with a complete macOS ICNS whose
subject reads clearly in Finder, the Dock, and small list views.

## Approved Design

- Preserve the existing hand-drawn cat, headphones, music note, white background,
  black line style, and exact `catstayathome` lettering.
- Uniformly enlarge and center the existing artwork to the largest uncropped
  fit. Because the artwork is tall, the final visible ink occupies about 65%
  width and 85% height instead of the current 57% width.
- Keep comfortable edge clearance and do not crop the headphones, ears, note,
  body, or lettering.
- Do not introduce shadows, gradients, colors, new objects, or typography.

## Deliverables

- One visually checked 1024x1024 master PNG.
- A complete iconset containing 16, 32, 128, 256, 512, and 1024 pixel
  representations using Apple's standard 1x and 2x filenames.
- A rebuilt `AppIcon.icns` used by the 1.8.7 app bundle.

## Verification

- Confirm every required iconset layer exists and has the expected pixel size.
- Confirm the visible artwork coverage is near 65% width and 85% height without clipping.
- Confirm `iconutil` can round-trip the final ICNS.
- Confirm the bundled icon hash matches the repository `AppIcon.icns`.
- Rebuild the app and rerun unit, bundle, signature, and launch checks.
