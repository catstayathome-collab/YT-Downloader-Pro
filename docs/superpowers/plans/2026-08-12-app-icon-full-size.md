# Full-Size App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a complete, full-size macOS ICNS for YT Downloader Pro 1.8.7 while preserving the approved hand-drawn design.

**Architecture:** Create and visually validate one 1024x1024 master, derive every required macOS icon representation from that master, and compile them with `iconutil`. The existing build script remains the only consumer of `AppIcon.icns`, while the bundle checker verifies that the source and bundled icons match.

**Tech Stack:** OpenAI ImageGen edit mode, PNG, `sips`, `iconutil`, Python/Pillow inspection, PyInstaller 6.21.0

## Global Constraints

- Preserve the cat, headphones, music note, white background, black line style, and exact `catstayathome` lettering.
- Visible ink should use the largest uncropped fit, about 65% width and 85% height.
- Include standard 16, 32, 128, 256, 512, and 1024 pixel representations.
- Do not add shadows, gradients, colors, objects, or typography.

---

### Task 1: Full-Size Master Artwork

**Files:**
- Create: `assets/AppIcon-1024.png`
- Reference: `AppIcon.icns`

**Interfaces:**
- Consumes: the current 1024x1024 artwork extracted from `AppIcon.icns`
- Produces: a visually approved 1024x1024 PNG master

- [ ] **Step 1: Edit the current artwork**

Use ImageGen edit mode with the extracted icon as the edit target. Require a uniform scale-up and centering while preserving every approved visual invariant and the exact lettering.

- [ ] **Step 2: Inspect the generated master**

Open the result at original resolution and reject it if the text changes, any feature is cropped, or new visual elements appear.

- [ ] **Step 3: Measure subject coverage**

Run a Pillow inspection that finds pixels darker than RGB 245 and report the ink bounding box. Accept approximately 65% horizontal and 85% vertical coverage with clear edge padding.

### Task 2: Complete Iconset and ICNS

**Files:**
- Create: `assets/AppIcon.iconset/icon_16x16.png`
- Create: `assets/AppIcon.iconset/icon_16x16@2x.png`
- Create: `assets/AppIcon.iconset/icon_32x32.png`
- Create: `assets/AppIcon.iconset/icon_32x32@2x.png`
- Create: `assets/AppIcon.iconset/icon_128x128.png`
- Create: `assets/AppIcon.iconset/icon_128x128@2x.png`
- Create: `assets/AppIcon.iconset/icon_256x256.png`
- Create: `assets/AppIcon.iconset/icon_256x256@2x.png`
- Create: `assets/AppIcon.iconset/icon_512x512.png`
- Create: `assets/AppIcon.iconset/icon_512x512@2x.png`
- Modify: `AppIcon.icns`

**Interfaces:**
- Consumes: `assets/AppIcon-1024.png`
- Produces: a complete Apple iconset and compiled `AppIcon.icns`

- [ ] **Step 1: Derive all required PNG sizes**

Use `sips` to resize the approved master to 16, 32, 64, 128, 256, 512, and 1024 physical pixels and assign Apple's required 1x/2x filenames.

- [ ] **Step 2: Validate the iconset**

Verify all ten filenames exist, each PNG has its filename-implied dimensions, and small-size layers remain recognizable.

- [ ] **Step 3: Compile and round-trip the ICNS**

Run `iconutil -c icns assets/AppIcon.iconset -o AppIcon.icns`, extract the resulting ICNS back to a temporary iconset, and verify all required layers remain available.

### Task 3: Bundle and Release Candidate Verification

**Files:**
- Modify: `dist/YT Downloader Pro.app`
- Create: `dist/YT-Downloader-Pro-v1.8.7-macOS-arm64.zip`

**Interfaces:**
- Consumes: the new `AppIcon.icns` and existing 1.8.7 build pipeline
- Produces: a locally verified 1.8.7 release candidate

- [ ] **Step 1: Run automated tests**

Run `.venv-1.8.7/bin/python -m unittest discover -s tests -v`; expect every test to pass.

- [ ] **Step 2: Rebuild and verify the app**

Run `PATH="$PWD/.venv-1.8.7/bin:$PATH" ./scripts/build_1_8_7.sh`; expect the bundle checker to report v1.8.7 build 187 as internally consistent and the icon hashes to match.

- [ ] **Step 3: Launch and inspect the packaged app**

Open the packaged app, verify the new icon appearance, enter the known problem URL, press Enter, and confirm title plus quality/audio menus populate.

- [ ] **Step 4: Archive and recheck**

Create the ZIP with `ditto`, extract it into a temporary directory, and rerun `scripts/check_bundle_tools.py` against the extracted app.

- [ ] **Step 5: Commit the asset**

Commit the master PNG, full iconset, compiled ICNS, and any verification adjustments without publishing a tag or GitHub Release.
