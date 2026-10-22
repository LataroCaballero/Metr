<!-- GSD:project-start source:PROJECT.md -->

## Project

**Metr**

Metr is a free, open-source system monitor for macOS (Apple Silicon only). It covers CPU, memory, disk, processes, network, GPU and temperatures/fans. It lives in the menu bar as three tiny ring gauges (CPU · RAM · Disk). Clicking them opens a panel that shows the details at a glance, and a full window is there when you want more. It should look and feel as if Apple made it, be super simple and intuitive, and work well with zero configuration.

**Core Value:** Within two seconds of clicking, you know **exactly how much is being used** (exact numbers) and **who is using it** (which app/process). It looks indistinguishable from a first-party Apple app while doing so.

### Constraints

- **Platform**: Apple Silicon only, macOS 26+ — native Liquid Glass look; Apple Silicon sensor/metric access
- **Design**: Must look and behave like a first-party Apple app (HIG, SF Symbols, system materials, native controls) — this is the product's identity
- **Simplicity**: Minimal settings; defaults must be right — the user explicitly rejects configuration overload
- **Performance**: A monitor must be lightweight itself (low CPU/RAM footprint), otherwise it pollutes what it measures
- **Budget**: $0 — no Apple Developer Program; unsigned distribution
- **Localization**: English + Spanish

<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->

## Technology Stack

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Swift | 6.3 (Xcode 26.6) or 6.4 (Xcode 27.1), **Swift 6 language mode** | All app and sampler code | The only first-class language for SwiftUI and AppKit. Swift 6 mode (strict concurrency) fits a multi-threaded sampler. Use default-MainActor isolation for the UI target and plain `nonisolated` code in the core package. | HIGH |
| Xcode | **27.1 (27A9275, 2026-10-15)** if the dev Mac can move to macOS 26.6.2 or later. **26.6 (17F113, 2026-06-25)** if it cannot. | IDE, SDK, `actool`, `xcstringstool`, Icon Composer | Xcode 26.6 requires macOS 26.2 or later (installable on this Mac today). Xcode 27 and 27.1 require macOS 26.6 or later, so this Mac (26.5.2) cannot run them yet. The Xcode 27 SDK makes apps look current on macOS 27. Apps linked against older SDKs keep compatibility behaviours. See Version Compatibility. | HIGH |
| Deployment target | **macOS 26.0** | Minimum OS | Matches PROJECT.md. `glassEffect`, `GlassEffectContainer` and `NSGlassEffectView` are all macOS 26.0 or later. | HIGH |
| SwiftUI | macOS 26 SDK (27 SDK once on Xcode 27) | Popover content, full window, settings | Standard controls, sidebars, toolbars, sheets and popovers pick up Liquid Glass automatically when built with the 26+ SDK. Apple says to **remove custom backgrounds** and let the system draw. | HIGH |
| AppKit | macOS 26 SDK | `NSStatusItem`, `NSPopover`, window and activation-policy control, `NSRunningApplication` | Needed for the menu bar item. SwiftUI `MenuBarExtra` is too limited for a live-drawn, programmatically controlled item (see the decision below). | HIGH |
| Observation (`@Observable`) | Swift 6 | State store feeding views | Fine-grained invalidation avoids redrawing the whole popover each second. Replaces Combine and `ObservableObject`. | HIGH |
| Swift Charts | macOS 13+ API, fine on 26 | History graphs in the full window (CPU, network, memory) | First-party, Liquid Glass-consistent, localizes axes. Use it only for the window's larger charts, not the sparklines. | HIGH |
| Xcode project (`.xcodeproj`) + **local SwiftPM package** | Xcode 16+ synchronized folders | Build system | App target in Xcode (needed for asset catalog, `.icon`, `.xcstrings`, Info.plist, signing). Pure logic (samplers, delta math, formatters) lives in a local package `MetrKit`, which can be tested with `swift test`. | HIGH |
| String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`) | Xcode 15+ format, current | EN + ES localization | The current Apple standard. Xcode extracts strings on build and handles plural variants. Spanish plurals and `%lld` specifiers are supported. | HIGH |

### System Metric APIs (the data layer)

| Metric | API to use | Public? | Verified on M4 | Notes |
|--------|-----------|---------|----------------|-------|
| CPU load, per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` and compute deltas between samples | Public (Mach) | Yes (10 CPUs) | Use `&-` wrapping math on the `UInt32` ticks. Free the returned array with `vm_deallocate`. |
| CPU P/E split | `sysctlbyname("hw.nperflevels")`, `hw.perflevelN.name`, `hw.perflevelN.logicalcpu` | Public | Yes (2 levels: Performance 4, Efficiency 6) | **Efficiency cores come first** in the `host_processor_info` array. IORegistry confirmed cpu0-5 `cluster-type=E`, cpu6-9 `P`. Do not hard-code names: Stats and macmon report that M5-family chips use "Super" cores. Derive labels from `perflevelN`, where level 0 is the highest-performance tier. |
| Memory | `host_statistics64(HOST_VM_INFO64)` plus `sysctl hw.memsize` | Public | Yes | Page size is 16 KiB on Apple Silicon. Read `vm_kernel_page_size`, never 4096. Used = app (internal minus purgeable) + wired + compressed. |
| Memory pressure | `sysctlbyname("kern.memorystatus_vm_pressure_level")` (1 normal, 2 warn, 4 critical). `kern.memorystatus_level` is the free-percentage, which reads 64 on this Mac. | Public sysctl | Yes (1, and 64) | Good enough for the gauge. Swap via `vm.swapusage`. |
| Disk space | `URL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])` over `FileManager.mountedVolumeURLs(..., options: [.skipHiddenVolumes])` | Public | Not probed (standard API) | `...ForImportantUsage` matches Finder, which counts purgeable space. APFS volumes share a container, so show per-volume but explain "shared" in the UI. Use `DiskArbitration` only if you need internal-vs-external classification. |
| Processes, own user | `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` (`ri_phys_footprint`, `ri_user_time`, `ri_system_time`) + `proc_pidinfo(PROC_PIDTASKINFO)` | Public (libproc) | Yes, **with a hard limit, see below** | CPU % is the delta of user+system time over wall time. Use `ri_phys_footprint` for memory (matches Activity Monitor "Memory"). |
| Processes, root or system | `/bin/ps` and `/usr/bin/top` (both **setuid root**) spawned via `Process` | Public CLI | Yes (`ps` listed `_windowserver`, `top` listed WindowServer at 38%) | Needed because libproc is blocked for other users (below). Stats does the same. Run only while the panel or window is open. |
| Network throughput | `sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0)` reading `if_msghdr2.ifm_data` (`struct if_data64`) | Public | Header-verified | **Do not use `getifaddrs` byte counters alone.** `struct if_data.ifi_ibytes` is `u_int32_t` and wraps at 4 GiB. Only `if_data64` is 64-bit. Pick the primary interface from `SCDynamicStore` `State:/Network/Global/IPv4` `PrimaryInterface`, and ignore `lo0`, `awdl*`, `llw*`, `utun*`, `bridge*`. |
| Link state / reachability | `NWPathMonitor` | Public | n/a | Gives connectivity and interface type only, **not throughput**. Optional. |
| GPU utilization | IOKit registry: `IOServiceMatching("IOAccelerator")` then property `PerformanceStatistics["Device Utilization %"]` (also `Renderer Utilization %`, `Tiler Utilization %`, `In use system memory`) | Registry read of undocumented keys | **Yes: 45% on `AGXAcceleratorG16G`, 8 GPU cores** | No root, no private framework. This is the **v1 GPU metric**. `gpu-core-count` is on the same node. |
| Temperatures | **SMC** user client (`IOServiceOpen("AppleSMC")` then `IOConnectCallStructMethod` selector 2 with `SMCKeyData_t`). **HID** via private `IOHIDEventSystemClient*` symbols, resolved with `dlsym`. | Private or undocumented | **Yes for both.** SMC: 2129 keys, 200 `T*` keys, `Tp01`/`Te05`/`Tg0G` read as `flt`. HID: 46 temperature sensors. | Key and sensor names **change per chip generation**. See Sensors strategy below. |
| Fans | SMC `FNum`, `F{i}Ac` (actual), `F{i}Mn`, `F{i}Mx`, `F{i}ID` | Private | **`FNum` is absent on this fanless MacBook Air M4** | UI must hide the fan row when no fans exist. Fan reads are unverified on a fan-equipped Mac (MEDIUM). Fan control writes need root, so it is out of scope. |
| GPU or CPU frequency, power | IOReport (`libIOReport.dylib`) | Private | `dlopen` works | **Excluded from v1.** macmon's README says macOS 27 broke its CPU/ANE power source and it now relies on undocumented counter mappings. Not needed for any v1 requirement. |
- Use libproc as the fast path for the user's own processes (about 450 here).
- Merge in a `ps -axo pid=,time=,rss=,user=,comm=` sample for processes owned by other users. Its cumulative `time` column lets you compute instantaneous CPU% by delta. `ps %cpu` is a decayed average and is misleading.
- Gate the `ps` call on UI visibility.
- The **Force Quit** button applies only to own-uid processes (`NSRunningApplication.forceTerminate()`, or `kill(pid, SIGTERM)` then `SIGKILL`). Hide or disable it for root-owned rows.

### Menu bar and window architecture decision

| Decision | Choice | Why | Confidence |
|----------|--------|-----|------------|
| Menu bar item | **`NSStatusItem` + `NSPopover` (`.transient`) hosting an `NSHostingController`**, created in an `NSApplicationDelegateAdaptor` inside a SwiftUI `App` | `MenuBarExtra` (macOS 13+, unchanged in the 26 and 27 docs) has no first-party API to open or close programmatically, to read the item's frame, or to reach the underlying `NSStatusItem` or window. The `MenuBarExtraAccess` package exists only to hack around this. A live three-ring glyph needs a custom image redrawn each second. Apple's own docs say system popovers get Liquid Glass automatically. | MEDIUM-HIGH |
| Ring glyph in the menu bar | Draw an `NSImage(size:flipped:drawingHandler:)` with Core Graphics (three arcs plus tracks), `isTemplate = true`, assigned to `statusItem.button?.image` at 1 Hz | Cheapest and crispest option, and a template image is tinted correctly on the transparent Tahoe menu bar in light and dark. Avoids hosting a SwiftUI view inside the status button. Hover and highlight behaviour of status-item buttons is currently unstable in macOS 27 betas (Apple Developer Forums thread 836113: hover events, `highlight(true)` and `occlusionState` regressions, partly fixed by beta 5). | MEDIUM |
| Popover look | Standard `NSPopover`, **no custom `NSVisualEffectView` or background** | Apple's Adopting Liquid Glass guide: "Audit the backgrounds of sheets and popovers ... remove those custom background views." | HIGH |
| Popover vs custom arrowless panel | Start with `NSPopover`. Spike an `NSPanel` + `NSGlassEffectView` only if the arrow looks wrong in review. | Fallback if the Control Center-style panel look is wanted. `NSGlassEffectView` (macOS 26.0 or later) exposes `contentView`, `cornerRadius`, `tintColor`, `style`, `effectIsInteractive`. | MEDIUM |
| Full window | SwiftUI `Window("Metr", id: "main")` with `NavigationSplitView` (sidebar: CPU, Memory, Disk, Network, GPU, Sensors, Processes), `.toolbar`, optionally `.inspector` | Standard components get the Liquid Glass sidebar, toolbar and scroll-edge effects for free. Use `backgroundExtensionEffect()` only if there is hero content. | HIGH |
| Activation policy | `LSUIElement = YES` (agent app, no Dock icon). Switch to `NSApp.setActivationPolicy(.regular)` while the full window is open and back to `.accessory` on close. | Gives menu-bar-app behaviour with a normal windowed app when the user opens the detail view. | MEDIUM |
| Glass in custom UI | Apple controls only: `.buttonStyle(.glass)`, `.glassProminent`, plus `GlassEffectContainer { ... .glassEffect(...) }` for any custom floating control. **Never glass the content layer** (graphs, process rows). | Apple: "Avoid overusing Liquid Glass effects", "Limit these effects to the most important functional elements." Many glass views outside a container hurt performance. | HIGH |
| Rings and sparklines | Custom SwiftUI `Circle().trim(...).stroke(style: .init(lineCap: .round))` and `Path` or `Canvas` | Swift Charts carries more per-update overhead. Rings are not a Charts mark. Small custom shapes keep the monitor's own CPU low. | MEDIUM |
| Settings | `Settings { }` scene with `@AppStorage`. Launch at login via `SMAppService.mainApp.register()`. | Zero third-party dependencies. `SMAppService` is macOS 13+. Behaviour under ad-hoc signing needs a test (see Pitfalls). | MEDIUM |

### Sampling architecture (stack-level decisions)

| Concern | Choice | Why |
|---------|--------|-----|
| Timer | One `DispatchSourceTimer` with leeway on a utility-QoS queue (or an actor owning a `ContinuousClock` loop). 1 Hz for the three ring metrics. Heavier collectors (process list, SMC/HID, `ps`) run only while the popover or window is visible. | A monitor must not pollute what it measures (PROJECT.md constraint). Do **not** rely on `NSWindow.occlusionState` to detect visibility. Apple forum reports say it is unreliable for status items on macOS 27. Track popover open/close yourself. |
| Concurrency | One `Sampler` actor produces an immutable `Sendable` snapshot struct. A `@MainActor @Observable` store receives it. Use `Synchronization.Mutex` for tiny shared caches. | Strict-concurrency friendly. Views never touch Mach or IOKit. |
| History | In-memory ring buffers (about 60-300 points per metric). No persistence. | No SwiftData or Core Data needed. Fewer files, less risk, lower footprint. |
| Wake/sleep | Observe `NSWorkspace.didWakeNotification` and reset delta baselines and the HID client after wake. | Stats resets its HID sensors on wake. Deltas across sleep produce spikes. |
| Private symbols | A small **C target** in `MetrKit` declaring `IOHIDEventSystemClient*` prototypes and SMC structs. Resolve symbols with `dlsym` and degrade gracefully if missing. | Failure becomes "no temperature row", not a crash on a new macOS. |

### Sensors strategy (temperatures and fans)

- **What exists (measured on M4):** SMC exposes `Tp01`/`Tp05`/`Tp09` (P-cluster die), `Te05` (E-cluster), `Tg0G` (GPU), plus battery and NAND keys. HID exposes 46 sensors named `PMU tdie N`, `PMU2 tdie N`, `PMU tdev N`, `gas gauge battery`, `NAND CH0 temp`. HID did **not** expose the `pACC`/`eACC`/`GPU MTR` names that Stats' reader uses for M1-M3.
- **Per-generation SMC key tables (from Stats `Modules/Sensors/values.swift`, MEDIUM):**
- **Recommended approach:**
- **Fans:** SMC `FNum` and `F{i}Ac`/`Mn`/`Mx`. Fanless Macs (Air) legitimately have none, so the UI must handle zero fans. The probe machine confirms this case, and it is common.

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Swift Testing (`import Testing`) | ships with Xcode | Unit tests for delta math, formatters, key-table selection | Always, in `MetrKit` |
| `swift format` | ships with Swift 6 toolchains | Formatting | Optional, in CI or pre-commit |
| Sparkle | 2.x | Auto-update | **Defer.** It adds XPC helpers and an EdDSA key workflow and is awkward unsigned. For v1, show "check for updates" as a link to GitHub Releases. |
| MenuBarExtraAccess (orchetect, macOS 13+) | n/a | Programmatic open/close for `MenuBarExtra` | **Only** if the team later abandons `NSStatusItem`. Its README says it works with both menu styles but the `.menu` style has runloop caveats. Not verified on macOS 26 or 27. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode 26.6 or 27.x | Build, Instruments (SwiftUI instrument, Time Profiler to verify Metr's own CPU), Icon Composer, String Catalog editor | Install the full Xcode. Command Line Tools alone cannot build the app. `xcodebuild` errors with "requires Xcode". |
| Icon Composer (bundled with Xcode 26+) | Layered Liquid Glass app icon (`.icon`) | Apple's adoption guide asks for layered icons. Icon Composer 2.0 in Xcode 27 adds a sharper rendering mode for upcoming OSes. |
| `xcodebuild` | Release build and archive | Command shown below. Ad-hoc sign for Apple Silicon. |
| `create-dmg` (create-dmg/create-dmg, shell script, **v1.3.0**) | Pretty .dmg with Applications symlink and background | `brew install create-dmg`. Use `--skip-jenkins` on headless CI. Without `--skip-jenkins` it drives Finder via AppleScript and can hang. Not installed on this Mac or in the GitHub `macos-26` image. |
| GitHub Actions `macos-26` (arm64) | Build and release | Image is macOS 26.6.2 with **Xcode 26.6 (17F113) as default**. Add `brew install create-dmg`. Use `gh release create`. |
| `gh`, `brew` | Release and tooling | Already installed locally. |

## Installation

# One-time dev machine setup (Command Line Tools are NOT enough)

# 1. Install Xcode 26.6 from developer.apple.com/download (works on macOS 26.2+), or

#    update to macOS 26.6.2/27.x and install Xcode 27.1.

# Packaging tool

# Release build (arm64, ad-hoc signed, NOT sandboxed)

# DMG

# Checksum for the release notes

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `NSStatusItem` + `NSPopover` | SwiftUI `MenuBarExtra(.window)` | If you will accept a static or simple label and no programmatic open/close. It is far less code. The 26/27 docs show no new `MenuBarExtra` APIs, so its limits persist. Reasonable for a throwaway prototype. |
| `NSStatusItem` + `NSPopover` | `NSStatusItem` + custom `NSPanel` + `NSGlassEffectView` | If the popover arrow clashes with the design intent. More work: you own positioning, dismissal and focus. |
| Core Graphics template image for the glyph | `ImageRenderer` of a SwiftUI ring view to `NSImage` | If you want to share the exact SwiftUI ring view in the menu bar and the popover. Slightly more CPU per tick, and rasterisation scale needs care. |
| Xcode project + local SwiftPM package | Pure SwiftPM executable | Not viable for the shipped `.app`. SwiftPM does not produce a bundle, and the Icon Composer `.icon`, asset catalog and `.xcstrings` pipeline need Xcode's `actool` and `xcstringstool`. Pure SwiftPM stays fine for the tested core library. |
| Xcode project (hand-managed, synchronized folders) | XcodeGen or Tuist | If multiple contributors cause `.pbxproj` merge pain. Xcode 16+ synchronized folders already reduce this. Not worth the extra dependency for a solo-start project. |
| `IOAccelerator` `PerformanceStatistics` for GPU % | IOReport GPU residency | Only if you need GPU **frequency or power**. It is private, and macOS 27 already broke part of the same IOReport surface (macmon). |
| SMC table + HID fallback for temps | HID only | If you want zero per-chip tables. On M4 it gave `PMU tdie` die temps but no named CPU/GPU cluster, so labelling is weaker. |
| libproc plus `ps` merge for processes | Spawn `top -l 2` only | Simpler, and covers all PIDs (Stats does this). But every refresh costs a full second plus a process spawn and parsing text. Use as the fallback if the `ps` delta approach proves unreliable. |
| `sysctl NET_RT_IFLIST2` | `getifaddrs` | Only for interface discovery and addresses. Counters are 32-bit there. |
| create-dmg (shell) | `hdiutil create -srcfolder` | If you want no dependency. You lose the background and icon layout. |
| create-dmg (shell) | create-dmg (Node, sindresorhus) | If you will notarize later. Its README stresses signing and notarizing. Not relevant for v1. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| **App Sandbox** (Xcode's macOS template turns it on by default) | Sandbox is incompatible with what this app does: opening `AppleSMC` and HID user clients, reading other processes via libproc, spawning `ps`/`top`, and `kill()` on other processes. Apple forum evidence shows `IOServiceOpen` failures in sandboxed apps (USB case). Temporary-exception entitlements are not allowed in the Mac App Store, and not every block has one. All probes above succeeded unsandboxed. I did not test a sandboxed build, so this is a design inference. | Set `ENABLE_APP_SANDBOX = NO`. This is acceptable because distribution is an unsigned DMG, not the App Store. |
| `powermetrics` | Requires root | IOAccelerator, SMC and HID as above |
| IOReport (`libIOReport`) in v1 | Private and fragile across macOS and chips (macmon: macOS 27 broke its CPU/ANE power source). Not needed by any v1 requirement. | Defer to a post-v1 "power and frequency" module, behind a feature flag |
| SMJobBless / privileged helper / fan **control** | Needs a developer identity and root. Fan control is not in scope, and Stats itself lists it as unmaintained. | Read-only sensors |
| `host_statistics` (non-64) for VM stats | 32-bit counters | `host_statistics64(HOST_VM_INFO64)` |
| `hw.cpufrequency` | Not available on Apple Silicon | Skip CPU frequency in v1 |
| `getifaddrs` for throughput counters | 32-bit `u_int32_t` byte counters wrap at 4 GiB (verified in the SDK header `net/if_var.h`) | `NET_RT_IFLIST2` and `if_data64` |
| Hard-coded 4096 page size | Apple Silicon pages are 16 KiB | `vm_kernel_page_size` |
| Hard-coded "P" and "E" core labels | M5-family chips use "Super" and "Performance" tiers | Derive from `hw.perflevelN.name` |
| `NSStatusItem.view` (deprecated custom view) | Deprecated, and macOS 27 betas broke tracking and hover for views in status items | `statusItem.button` with an image |
| `if` / `else` (conditional content) inside a `Chart { }` closure when deployment target is below 27 | Xcode 27 release notes: it warns that `_ConditionalContent` conformance to `ChartContent` is 27.0 or later and "the app might crash at runtime". The note is listed as resolved, but treat it as a trap while targeting 26. | Pre-filter data and use `ForEach` |
| Custom `NSVisualEffectView` or fake blur behind the popover or sidebar | Fights the system Liquid Glass. Apple explicitly says to remove it. | System materials only |
| `UIDesignRequiresCompatibility` | Opts out of the new design. This defeats the "made by Apple" goal. | Leave unset |
| Electron / web-tech wrappers, Rust+UI toolkits | Cannot be "indistinguishable from a first-party app", and cost RAM, which violates the lightweight constraint | SwiftUI + AppKit |
| Combine `Timer.publish` for sampling | Adds main-thread work and coalescing surprises | `DispatchSourceTimer` or actor-owned loop |
| SwiftData / Core Data | Nothing to persist in v1 | In-memory ring buffers, `UserDefaults` for settings |
| Third-party chart libraries | Not needed, and risk inconsistent visuals | Swift Charts plus custom `Shape` |
| README instruction "right-click, then Open" | **Removed since macOS Sequoia (15).** Apple's current support page (102445) lists only: try to open, then System Settings, then Privacy & Security, then **Open Anyway**, then **Open**. PROJECT.md currently says right-click, which is outdated. | Document the Open Anyway flow, and optionally `xattr -dr com.apple.quarantine /Applications/Metr.app` |

## Stack Patterns by Variant

- Use Xcode 26.6 (Swift 6.3, macOS 26.5 SDK).
- Plan a later bump to the Xcode 27 SDK. Re-test menu and popover look on macOS 27, because apps built with older SDKs keep compatibility behaviour and apps built with the 27 SDK get new defaults. One example: the macOS 27 SDK hides menu item symbol images by default.
- Use Xcode 27.1 (Swift 6.4, macOS 27 SDK) and keep `MACOSX_DEPLOYMENT_TARGET = 26.0`.
- Guard any 27-only API with `#available`. Swift 6.4 adds `anyAppleOS` availability shorthand.
- The new `@State` macro implementation back-deploys, but it rejects `@State` with an initial value that is also assigned in `init`.
- Hide the temperature and fan rows and keep everything else working. Treat sensors as a plug-in with a `Sensor` protocol and capability flags (`hasCPUTemp`, `fanCount`).
- `FNum` read fails, so show no fan row. Do not render "0 RPM".
- Sample only the three ring metrics (CPU, memory, disk) at 1 Hz, or slower on battery. Stop everything else.

## Version Compatibility

| Item | Compatible With | Notes |
|------|-----------------|-------|
| Xcode 26.6 (17F113) | Runs on macOS 26.2 or later. Swift 6.3. SDKs 26.5. | Installable on this Mac (26.5.2). GitHub `macos-26` image default. |
| Xcode 27 (27A266a) / 27.1 (27A9275) | Requires macOS 26.6 or later. Swift 6.4. SDK 27. | Not installable on 26.5.x. Xcode 27.2 RC (27B48) posted 2026-10-19. |
| `glassEffect(_:in:)`, `GlassEffectContainer`, `NSGlassEffectView`, `.glass` / `.glassProminent` button styles | macOS 26.0 or later | Matches the deployment target. No `#available` needed. |
| `MenuBarExtra` | macOS 13 or later | Not recommended here. See the decision. |
| `NSStatusItem.expandedInterfaceDelegate` | New in macOS 27 (reported in forum thread 836113) | Optional. Guard with `#available(macOS 27, *)` and do not depend on it. |
| Swift Charts conditionals and Xcode 27 | Avoid `if` inside `Chart` when deployment target is below 27 | See What NOT to Use. |
| Gatekeeper | Unsigned or ad-hoc signed app opens only via **Open Anyway** (macOS 15 and later). Apple Silicon needs at least an ad-hoc signature (Xcode's `CODE_SIGN_IDENTITY="-"`). | Apple Silicon will not run completely unsigned arm64 code, and the Xcode build signs ad hoc. |
| Stats (reference) | Min macOS 12, latest v3.0.22 (published 18 Oct) | Adds M5 and M6 support and macOS 27 battery-temp fixes, so it is a live source of new SMC keys. |

## Reference Projects (read these, do not copy blindly)

| Project | License | What to learn |
|---------|---------|---------------|
| **exelban/Stats** (Swift, Xcode project, `Kit/`, `Modules/{CPU,GPU,RAM,Disk,Net,Sensors,Battery}`, `SMC/`) | MIT | The canonical reference for this exact domain. Key files: `Modules/CPU/readers.swift` (`host_processor_info`, IOReport frequency), `Modules/RAM/readers.swift` (`host_statistics64`, `kern.memorystatus_vm_pressure_level`, `vm.swapusage`), `Modules/GPU/reader.swift` (`IOAccelerator` `PerformanceStatistics`), `Modules/Net/readers.swift` (`NET_RT_IFLIST2`, `SCDynamicStore`, `nettop`), `Modules/Disk/readers.swift` (`mountedVolumeURLs`, `DiskArbitration`), `Modules/Sensors/{readers,values}.swift` (HID page `0xff00` usage `5` for temperature, SMC per-generation key tables, fan keys), `SMC/smc.swift`. Its UI is deliberately not Apple-like and has many options. Copy the data layer ideas, not the UX. It runs processes through `top`/`ps` in `Process()`, which matches our libproc finding. Also note its README: on Tahoe, users must enable the app under System Settings, Menu Bar, or the item will not show. Document this in Metr's README and first-run. |
| **vladkens/macmon** (Rust) | MIT | Sudoless Apple Silicon telemetry through IOReport and SMC. Documents that macOS 27 broke CPU/ANE power via IOReport. A cautionary example of private API fragility, and good evidence for deferring IOReport. |
| **Apple "Landmarks: Building an app with Liquid Glass"** (sample) | Apple sample | Official patterns for `GlassEffectContainer`, sidebar and toolbar. |
| **orchetect/MenuBarExtraAccess** | MIT | Documents exactly which `MenuBarExtra` capabilities are missing. Useful as a decision record. |

## Confidence Notes and Gaps

- **Verified on this M4 by running code (HIGH):** libproc visibility limits, `IOAccelerator` GPU %, `host_processor_info`, `host_statistics64`, memory pressure sysctls, SMC open and key reads, HID temperature sensors, `ps`/`top` seeing all processes, E-cores-first CPU ordering, `if_data` 32-bit vs `if_data64` 64-bit in headers.
- **Not verifiable here (MEDIUM or LOW):**
- **macOS 27 status-item regressions** come from forum posts about betas (beta 5 appeared to fix hover). Re-test on the release build.

## Sources

- Local probes run on this machine (Mac16,12, M4, macOS 26.5.2): Swift and C programs in the scratchpad exercising libproc, IOKit, HID, SMC, `host_*`. **HIGH**
- Apple: Xcode 26.6 release notes and Xcode 27 release notes (`developer.apple.com/documentation/xcode-release-notes/...`). Versions, Swift 6.3 / 6.4, OS requirements, String Catalog and Icon Composer notes, Swift Charts conditional-content note. **HIGH**
- Apple: Releases list (`developer.apple.com/news/releases/`). Xcode 27 (27A266a) 2026-09-14, 27.1 (27A9275) 2026-10-15, 27.2 RC 2026-10-19, 26.6 (17F113) 2026-06-25, macOS 26.6.2 (25G83). **HIGH**
- Apple: macOS 27 Golden Gate release notes (menu item image defaults, `NSStatusItem`-adjacent changes, Gatekeeper `spctl --purge`). **HIGH**
- Apple: Applying Liquid Glass to custom views, Adopting Liquid Glass, `glassEffect(_:in:)` (macOS 26.0 or later), `NSGlassEffectView` (macOS 26.0 or later), `MenuBarExtra` (macOS 13.0 or later), `SMAppService` (macOS 13.0 or later), Localizing and varying text with a string catalog. **HIGH**
- Apple Support 102445, "Safely open apps on your Mac" (Open Anyway flow, no Control-click). **HIGH**
- Apple Developer Forums thread 836113, "Various menu bar NSStatusItem issues with macOS 27". **MEDIUM** (beta-era forum thread)
- exelban/Stats repository: README, releases (v3.0.22), `Modules/*/readers.swift`, `Modules/Sensors/values.swift`, `Kit/process.swift`. MIT. **HIGH** for what the code does, **MEDIUM** for key tables across chips.
- vladkens/macmon README (IOReport, macOS 27 caveat, M1-M5 support). **MEDIUM**
- orchetect/MenuBarExtraAccess README. **MEDIUM**
- actions/runner-images `macos-26-arm64` readme (Xcode 26.6 default, macOS 26.6.2). **MEDIUM-HIGH**
- create-dmg/create-dmg releases (v1.3.0, `--skip-jenkins`). **MEDIUM**
- Secondary blogs on Xcode 27 and macOS 27 availability (MacRumors, MacObserver). Used only to cross-check dates already confirmed on Apple's pages. **MEDIUM**

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-fast` for a trivial task inline, with no subagents and no PLAN.md
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
