# R6 Reference-Project Research: Hone (hone.gg) and the AME Wizard platform (AME Beta)

Read-only web research for NEXTRIX Phase 1. No Windows settings were modified, no tweak or
script was executed on the host, and no product was installed or run. Only public web pages
were fetched and this one notes file was written. Evidence tags used throughout:

- **[IMPLEMENTED]** — verified in source text actually fetched (URL cited). Used only for
  AME-side artifacts I could verify directly (GitHub API listings, raw license file, repo pages).
- **[DOCUMENTED]** — claim from the product's own official site/store listing/docs, not verified in source.
- **[COMMUNITY-CLAIM]** — third-party statement (reviews, forum threads, search snippets).
- **[DEV-BENCHMARK]** — developer-published performance number (self-reported, not independently reproduced).
- **[VERIFIED]** — independently reproduced measurement. **None exist for either target in this run.**

Tagging constraints honored: **Hone is closed-source commercial software — every Hone finding
below is DOCUMENTED, DEV-BENCHMARK (for their self-published numbers) or COMMUNITY-CLAIM.
Nothing about Hone's internals was inspected, and no Hone claim should be read as verified
behavior.** AME Wizard findings are DOCUMENTED (official docs) or IMPLEMENTED (GitHub artifacts
read directly), plus light COMMUNITY-CLAIM context.

---

## Target 1 — Hone (commercial Windows gaming optimizer)

### Identity table

| Field | Value |
|---|---|
| Product | Hone — "FPS Booster & PC Gaming Optimizer" for Windows [DOCUMENTED, hone.gg homepage] |
| Vendor | AuraSide, Inc., a Delaware corporation ("AuraSide… referred to as… 'Hone'"); 1007 North Orange Street 4th Floor, Suite 25, Wilmington, DE 19801, USA [DOCUMENTED, hone.gg/terms] |
| Websites | https://hone.gg (marketing), https://support.hone.gg (help articles) [DOCUMENTED] |
| Distribution | hone.gg download page → installer link points at `download.overwolf.com/install/Download?ExtensionId=mgkabooemhaamambocobpeoeelpadcjhjgbcfhlc` (Overwolf platform install), and Epic Games Store listing (publisher/developer "Auraside", listed free with in-app purchases; store shows release date "07/11/23") [DOCUMENTED, hone.gg/get-started and store.epicgames.com/p/hone-b51a2d] |
| Supported OS | Windows 10 and Windows 11 (schema.org `operatingSystem: "Windows 10, Windows 11"`); explicitly not macOS/console/mobile [DOCUMENTED, hone.gg homepage + FAQ] |
| Business model | Freemium subscription: Free plan = 10 optimizations (one extra per referral, up to 15) with ads; Premium = USD 5.99/month or USD 39.99/year as rendered at checkout [DOCUMENTED, hone.gg/premium + hone.gg/app/checkout?plan=monthly] |
| Payment/refunds | Checkout via Hone app; refund page defers to Xsolla (and Tebex for some purchases) refund policies [DOCUMENTED, hone.gg/refund-policy] |
| Community channels | Discord (discord.com/invite/hone), X (@gethonegg), YouTube, Instagram [DOCUMENTED, homepage footer links] |
| Source availability | Closed source; no public repository found. Nothing below implies inspection of Hone's internals |
| Reputation surfaces | Trustpilot claimed profile (Mar 2021, paid subscription, TrustScore 4.7, 1,791 reviews at access); Epic Player Ratings 3.5/5 [COMMUNITY-CLAIM, platform-collected] |

### Findings by area

**A. Product and feature claims (all DOCUMENTED — vendor marketing, unverified)**

- Core pitch: "Boost FPS. Reduce Latency… Hone brings your Windows and game tweaks together"
  [hone.gg homepage]. Claims: "Trusted by 2.5M+ gamers" [homepage]. Get-started page claims
  Hone "decreases lag by up to 60%" and "Supports 100,000+ games" [hone.gg/get-started].
- Feature set: Maximize FPS; Reduce Background Load ("Limit selected background apps and
  services that compete with your game"); Optimize Game Configs (presets); Reduce PC-Side
  Delay; Prioritize Your Game; Restore Supported Settings ("For supported registry
  optimizations, Hone saves the original values so you can restore them later") [hone.gg homepage].
- Game Mode tiers: Free = "Balanced Game Mode"; Premium adds "Custom & Performance Game Mode".
  "Boost-Ups: Run or schedule grouped tasks" [hone.gg/premium].
- Testimonial claims on homepage/valorant pages, e.g. "Improved my end-game in Fortnite with up
  to 45% FPS increase" (attributed to a sponsored Fortnite player) — vendor-published testimonial,
  not a benchmark result [DOCUMENTED, hone.gg homepage].
- Notable honest framing (rare in this category): FAQ states "Can Hone guarantee more FPS or
  lower latency? **No.** Your gains depend on your PC, game, and settings." And on networking:
  "It does not route traffic through relay servers or control your ISP, Wi-Fi quality, distance
  to the game server, or server load." [hone.gg homepage FAQ]. Research pages add: "We also do
  not modify game memory, anticheat files, or other sensitive game files to produce performance
  gains." [hone.gg/research/how-an-optimization-gets-added-to-hone].
- Epic listing makes a stronger claim than the main site: "all changes are fully revertible,
  you can choose what to switch on and off. Hone backups gives you peace of mind, the risk free
  optimizer." [DOCUMENTED, store.epicgames.com/p/hone-b51a2d] — compare with the main site's
  narrower "restore **supported** settings / registry optimizations" wording. Inconsistency recorded.

**B. How Hone describes its optimization/disabling behavior (DOCUMENTED — vendor description of its own behavior, closed source)**

- Per the Game Mode research paper (Nov 4, 2026, rev. Nov 9, 2026), Game Mode applies
  per-session rules: lower CPU priority of chosen apps (Below Normal / Idle), suspend processes
  (pause threads, recorded for resumption), terminate processes, stop services while recording
  previous state "without changing its startup setting" [hone.gg/research/how-game-mode-improves-performance].
- Every ~5 seconds it re-checks for "rogue processes that try to reopen themselves" and re-applies
  saved rules; an exclusion list protects "anticheat components, Windows services, recording
  tools, security software, and other protected entries" [same paper].
- After the tracked game closes, Hone "uses its back-up to restore the changes it modified:
  process priorities, suspended threads, changed service states, background CPU selections,
  GPU priorities, and session power settings. Keep in mind that terminated apps will remain
  closed." A session report separates launch-time vs. during-play changes [same paper].
- "Seven Game Enhancers" (session-scoped, opt-in): CPU Affinity via Windows CPU Sets (steering
  background apps to E-cores on hybrid CPUs); GPU Prioritization (process GPU scheduling
  priority class); Core Parking (minimum unparked processors set to 100%); Power Plan switch
  (High Performance on desktops/plugged-in laptops, Balanced on battery); Disable CPU 0;
  Disable Second CCD (AMD dual-chiplet CPUs); Disable SMT/Hyperthreading for the game only
  [same paper].
- Static optimizations: registry values backed up before applying; Windows restore point
  creation is recommended via a support article ("Setting Up a Restore Point"), plus a
  "How To Determine If Your Issue Is Hone Related" troubleshooting article [hone.gg homepage FAQ
  links to support.hone.gg articles 4902940834079 and 4758187922975].

**C. Claimed benchmark methodology and published numbers (DEV-BENCHMARK — developer-reported, single-system, self-published, not independently reproduced)**

- Hone publishes a "Hone Research" section (2 papers at access date) with a stated publication
  standard: "A result belongs in Hone Research only when the method, limits, and evidence can be
  inspected." [hone.gg/research].
- Methodology paper (Aug 20, 2026): every optimization must clear seven gates — a real problem;
  a direct mechanism explanation; known risks; a metric matched to the claim (avg FPS, 1%/0.1%
  lows, frame times, latency, storage, network); controlled tests (same PC/game/scene/settings/
  drivers/power plan/capture method; one change at a time; **3–5 baseline runs, one change,
  3–5 after runs = 6–10 runs per PC**; improvement must exceed baseline variation); a
  risk-vs-benefit review; and explicit scope ("where it helps and where it does not"). Tweaks
  end in keep / change / reject. Device-affinity example reports ~177 → 182 FPS on one system
  with a deliberately modest conclusion [hone.gg/research/how-an-optimization-gets-added-to-hone].
- Game Mode paper (Nov 4, 2026): two controlled VALORANT comparisons on one PC
  (Ryzen 7 9800X3D, RTX 5070 Ti, 32 GB RAM, CapFrameX capture):
  - Shooting range (1440p, Low): avg FPS 869.1 → 1,109.6 (**+27.7%**), 1% low +35.9%, 0.1% low +34.9%.
  - Controlled Haven scene: avg FPS 653.5 → 810.0 (**+23.9%**), 1% low +30.6%, 0.1% low +39.7%.
  - Haven CPU: total usage −17.7%, power −6%, temperature −3.6 °C.
  - "Other games, including Marvel Rivals, Overwatch and Fortnite, saw smaller average FPS
    gains of 2-5%, with 5-15% increases in the 1% and 0.1% lows."
  - Vendor's own caveat: "these results are only for one PC and configuration; your results
    may vary." [all DEV-BENCHMARK, hone.gg/research/how-game-mode-improves-performance].
- Epic Games Store listing markets larger figures "based on our benchmarks" with no methodology
  on that page: Valorant **+51%**, Fortnite **+36%**, Rocket League **+35%**, League of Legends
  **+30%**, TF2 **+39%**, CS:GO **+45%**, Destiny 2 **+27%** [DEV-BENCHMARK, store.epicgames.com/p/hone-b51a2d].
  Note the gap: the Epic-page Valorant figure (+51%) exceeds the vendor's own controlled
  Game Mode result (+23.9–27.7%, one high-end PC). Both are developer-reported; neither is
  independently verified. No third-party reproduced benchmark of Hone was found in this research.

**D. Pricing model (DOCUMENTED)**

- Free: 10 optimizations; +1 per referral up to 15; Balanced Game Mode; standard Boost-Ups; ads shown.
- Premium (auto-renewing subscription, cancellable from account): unlimited optimizations;
  premium-only optimizations; Custom & Performance Game Mode; premium game presets and
  Boost-Ups; no ads; priority support. "Free trial for new Premium members only, one per account."
  [hone.gg/premium FAQ].
- Checkout page render: **Hone Premium Monthly USD 5.99/month; Hone Premium Yearly USD 39.99/year**
  ("Best value"); "Sign in to buy. Secure payment. You can cancel at any time from your account
  page." Refund link points to Xsolla's refund policy [hone.gg/app/checkout?plan=monthly].
  The /premium page itself defers to regional pricing ("See regional price at checkout") and its
  server-rendered price widget did not load ("Price could not be loaded on this page").
- Epic listing: base game free, "In-App Purchases" [store.epicgames.com/p/hone-b51a2d].
- Refunds are governed by payment-provider policies (Xsolla; Tebex for Tebex checkouts) rather
  than a first-party refund promise [hone.gg/refund-policy].

**E. Terms of Service — redistribution, screenshots, arbitration (DOCUMENTED, hone.gg/terms)**

- Software license: "the Software… is licensed to you… for your personal, noncommercial home
  use only. We do not transfer title… You may not distribute or otherwise exploit the Software
  or decompile, reverse engineer, disassemble…"
- Site content (text, graphics, images…): download of one copy permitted "for your personal,
  noncommercial home use only" provided notices are retained, and "you may not… reproduce,
  display, publicly perform, distribute, or otherwise use the Content in any way for any public
  or commercial purpose without the prior written permission of Hone." Mirroring is prohibited;
  trademarks/logos require prior written permission.
  → Practical consequence for NEXTRIX: do not ship Hone screenshots or site/app content in a
  public repo without written permission; do not redistribute the Hone installer.
- Hone's research dataset (on the Game Mode paper) is marked in its metadata as licensed under
  `https://hone.gg/terms#use-of-content` [observed in the paper's JSON-LD] — i.e., the restrictive
  terms above also cover their published "research" numbers.
- Dispute terms: mandatory **binding individual arbitration** (AAA rules), **class-action
  waiver**, Delaware law/venue, opt-out available by email from the account address; liability
  capped at the greater of USD 50 or amounts paid in the prior 12 months; ToS changes are
  "effective immediately when we post them" [hone.gg/terms, Dispute Resolution & Liability sections].

**F. Supported Windows versions (DOCUMENTED)**

- "Hone supports Windows 10 and Windows 11 gaming PCs. It is not a macOS, console, or mobile
  optimizer." [homepage FAQ]. Get-started FAQ: "designed to work with every PC running Windows
  10 or later" [hone.gg/get-started]. No specific build numbers (e.g., 22H2/23H2/24H2) are
  published on the marketing pages reviewed.

**G. Community reputation — positive and critical (COMMUNITY-CLAIM)**

Positive:
- Trustpilot page (accessed): TrustScore **4.7**, **1,791 reviews**; claimed profile since
  Mar 2021; **paid Trustpilot subscription**; "Replied to 100% of negative reviews. Typically
  replies within 24 hours." Recent-review AI summary (553 reviews): "reviewers overwhelmingly
  had a great experience… easy to use… notable performance improvements and frame rate boosts"
  [COMMUNITY-CLAIM, trustpilot.com/review/hone.gg].
- Pro-player/creator testimonials on the homepage (Higgs/XSET, Khanada/Dignitas, etc.)
  [DOCUMENTED as vendor-published endorsements].

Critical/skeptical (recorded with sources; none independently verified):
- Trustpilot's own summary continues: "However, some reviewers mentioned encountering serious
  driver conflicts, persistent system freezes, or unexpected software behavior after applying
  certain advanced optimizations. A few customers also noted that extra features require payment
  or that the available free options are somewhat limited" [COMMUNITY-CLAIM, same page]. Trustpilot
  also flags: "This company hasn't invited customers recently, so reviews may not be representative."
- Epic Games "Player Ratings": **3.5/5** ("Captured from players in the Epic Games ecosystem")
  [COMMUNITY-CLAIM, store.epicgames.com/p/hone-b51a2d] — notably below the Trustpilot 4.7.
- r/pcmasterrace thread "HoneCtrl or Hone.gg is apparently a virus" (2023): "I just download
  HoneCtrl/Hone.gg and is has been flagged by bitdefender. It was flagged for doing malicious
  activities and being a virus." [COMMUNITY-CLAIM, reddit.com/r/pcmasterrace/comments/150nx45 —
  retrieved as search snippet; full thread not readable, see limitations].
- r/pcmasterrace thread "how to remove hone.gg when it's bricked Windows drive" (2024): title
  asserts a drive was "bricked"; retrieved reply snippets advise Windows PE / "Only solution is
  to do a full reformat… install windows again." [COMMUNITY-CLAIM,
  reddit.com/r/pcmasterrace/comments/1esomhv — snippet only; causation not established].
- r/pchelp thread "is hone.gg LEGIT. the pc optimizer": "Ive seen so many reddit posts saying
  its legit and not legit…" — illustrates mixed community sentiment [COMMUNITY-CLAIM,
  reddit.com/r/pchelp/comments/1ne6s5e — snippet only].
- Skeptical YouTube coverage exists, e.g. "*HONE Optimizer* REVIEW — Does it actually increase
  FPS or is it a scam?" and "The truth about Hone.gg" (search-reported ~155K views) [COMMUNITY-CLAIM
  for existence; video contents not analyzed].
- No lawsuits, regulatory actions, or formal controversy records were surfaced by the searches
  performed — absence of evidence only, not a verified absence.

**H. Claims vs. independent verification (explicit)**

- Everything in sections A–F is either the vendor's own claim (DOCUMENTED) or third-party
  opinion (COMMUNITY-CLAIM). All performance numbers are DEV-BENCHMARK (self-published).
- **Zero VERIFIED findings.** No independent party's reproduced measurement of Hone's effect
  on FPS/latency was found in the sources accessible to this research. Hone's internals were
  not and cannot be audited (closed source).

### Useful ideas for NEXTRIX (shortlist)

1. **Value-level registry backup before apply** — "for registry optimizations, it backs up the
   original values before applying them" [DOCUMENTED]. NEXTRIX should snapshot per-value prior
   state and make restore a first-class, per-tweak operation.
2. **Session-scoped tweaks with automatic restore** — Game Mode's model (apply at game start →
   watchdog every ~5 s for relaunching processes → restore recorded state on game close) plus a
   **session report** listing every change made at launch and during play [DOCUMENTED design
   description]. An audit log of "what changed, when, and what was restored" fits NEXTRIX's
   rollback-safety requirement exactly.
3. **Exclusion lists as a safety rail** — protect anticheat, antivirus, recording tools, Windows
   essentials from background-management rules [DOCUMENTED].
4. **Tweak-admission methodology** — the 7-gate scorecard (problem → mechanism → risk →
   metric-matched goal → 6–10 controlled runs → risk/benefit → scope) with keep/change/reject
   outcomes [DOCUMENTED as their claimed method]. Directly transferable to NEXTRIX's evidence
   standards for admitting any tweak.
5. **Metric discipline** — 1%/0.1% lows and frame times over average FPS; CapFrameX as a
   capture tool; "the measurement must match the claim" [DOCUMENTED].
6. **Honest negative-space documentation** — per-tweak "where this does not help" sections and
   explicit no-guarantee disclaimers [DOCUMENTED]. NEXTRIX docs should adopt this tone.
7. **Specific session-scope mechanisms worth studying** (not adopting blindly): CPU Sets for
   steering background work to E-cores, GPU scheduling priority class, core-parking minimum,
   per-game CCD/SMT/CPU0 exclusions as opt-in, higher-risk tiers [DOCUMENTED mechanisms].

### Reject / caution (Hone) — with reasons

- **All Hone performance percentages (4.7★ reviews, +51%, "up to 60% lag decrease", "2.5M+
  gamers") must never be cited as evidence of anything in NEXTRIX** — closed source, all
  self-reported, none independently reproduced. The Epic-page numbers (+51% Valorant) even
  exceed the vendor's own published controlled results (+23.9–27.7% on one PC).
- **"Fully revertible" (Epic listing) contradicts "restore supported settings" (main site)** —
   reversibility scope is undefined; do not model NEXTRIX's undo claims on Hone's wording.
- **Legal exposure via ToS** — no redistribution of Hone software; no public/commercial display
  or distribution of Hone content (incl. screenshots) without written permission; mandatory
  arbitration/class waiver; ToS change effective on posting. NEXTRIX should reference Hone only
  by citation of public URLs and short quotations for research purposes.
- **Reputation signal is weak** — Trustpilot is a paid, claimed profile flagged "reviews may
  not be representative"; Epic players rate 3.5/5; multiple independent Reddit threads report
  AV flags and broken systems (unverified, but recurring). Treat Hone as a claims source, not
  a trust anchor.
- **Overwolf-based distribution** (installer served by download.overwolf.com) ties the product
  to an overlay/monetization platform — context for its trust posture; not a pattern to imitate
  for a transparency-first tool.

---

## Target 2 — AME Wizard platform ("AME Beta", formerly AME Wizard)

The playbook engine used by ReviOS, AtlasOS and others. Official documentation lives at
**docs.amelabs.net** (older links still point to docs.ameliorated.io); product homepage is
**ameliorated.io**; downloads at download.ameliorated.io; source on GitHub under
**Ameliorated-LLC**.

### Identity table

| Field | Value |
|---|---|
| Product | AME Beta — "The Ultimate tool for modifying Windows"; docs call it "AME Beta, previously AME Wizard"; binary download named both "AME Beta.zip" and "AME Wizard Beta.zip" [DOCUMENTED, ameliorated.io + docs.amelabs.net/getting_started.html] |
| Current version | **AME Beta v0.8.4** (146 MB zip), from the homepage download button at access date; explicitly a beta ("before AME v.1.0" roadmap language) [DOCUMENTED, ameliorated.io] |
| Vendor | Ameliorated LLC ("Amelabs"); GitHub org `Ameliorated-LLC` (9 public repos) [IMPLEMENTED, org listing read] |
| Supported Windows (official playbooks) | "Privacy+ supports all stable Windows 11 versions; AME 10 supports Windows 10 21H2 and 22H2" [DOCUMENTED, docs getting_started]. Example playbook.conf declares SupportedBuilds 22000, 22621; actions can be gated per-build down to the update-revision level (e.g., 22621.1265) [DOCUMENTED, docs configuration/actions] |
| Playbook format | Folder: `playbook.conf` (XML metadata) + `Configuration/main.yml` + `Configuration/Tasks/*.yml` + `Executables/`; distributed packaged as an `.apbx` file (7-Zip 7z archive, fixed password "malte") [DOCUMENTED, docs creating_playbooks] |
| Verified playbooks (ecosystem) | AtlasOS, ReviOS (third-party), Privacy+, AME 10 (first-party) — "AtlasOS is a verified Playbook", "ReviOS is a verified Playbook" [DOCUMENTED, ameliorated.io homepage]. XOS/SapphireOS/Vain/UltraOS named in the task brief were not individually verified here (see limitations) |
| Source availability | Core engine `trusted-uninstaller-cli` ("Core functionality for AME Wizard") = public, **MIT** [IMPLEMENTED, license read]. Official playbooks public on GitHub **without any LICENSE file** [IMPLEMENTED, GitHub contents API]. Wizard GUI app source: not found among the org's 9 repos [IMPLEMENTED absence]. Docs site labels the project "Open source… Most of our software is released under the MIT license" [DOCUMENTED, ameliorated.io — note "most"] |
| Code signature | None during beta: "Ameliorated is currently in the process of acquiring a code-signing certificate. During the beta phase, no builds of AME Wizard will be code signed" [DOCUMENTED, docs security-exceptions] |
| Contact/verification | Verification granted via Discord/Telegram handles @styris_ame / @actrons [DOCUMENTED, docs verification] |

### Findings by area

**A. Current version and supported Windows builds (DOCUMENTED)**

- AME Beta v0.8.4, 146 MB [ameliorated.io]. Docs introduce "AME Beta, previously AME Wizard"
  [docs getting_started]. The docs changelog records **documentation** milestones (latest
  2025-05-30: ISO Mode introduction, new `!download` and `!software` actions, rename
  `!writeStatus` → `!status`, non-breaking) — it is not a wizard release/version history
  [docs.amelabs.net/changelog.html + changelog/2025-05-30.html]. Earlier milestone 2024-06-12:
  `UniqueId` property introduced ("will be required in a future release"), `custom.yml` renamed
  to `main.yml`, new `!task` action, logging overhaul (`Output.txt` + `Log.yml`), `errorAction`
  replacing `ignoreErrors`, `handleExitCodes` for run/cmd/powerShell [docs changelog/2024-06-12.html].
- Build targeting is playbook-level (`SupportedBuilds` in playbook.conf) and action-level
  (`builds:` with `>=`, `<=`, `>`, `<`, negation `!>`, and exact update revisions like
  `22621.1265`), plus `cpuArch` gating [docs configuration + actions].
- No published minimum Windows requirement for the wizard itself beyond the playbooks' own
  build lists; .NET/C# is claimed ("Built with C# and .NET") [ameliorated.io].

**B. Playbook authoring schema (DOCUMENTED)**

Structure (exact hierarchy per docs):

```
Playbook (root folder)
├── playbook.conf
├── Configuration
│   ├── main.yml
│   └── Tasks
│       ├── registry.yml
│       └── appx.yml
└── Executables
```
Source: docs.amelabs.net/creating_playbooks.html (official Amelabs documentation; no license
notice found on docs pages — quoted briefly for research).

`playbook.conf` (XML) required properties: `Name`, `Username`, `UniqueId` (UUIDv4/GUID),
`ShortDescription`, `Title`, `Description`, `Details`, `Version` (formats `1` / `0.1` / `0.0.1`).
Optional: `SupportedBuilds`, `FeaturePages`, `Requirements`, `ProductCode` (verification),
`ProgressText`, `Git` (updates + Source Code button), `Website`, `DonateLink`, `InstallGuide`,
`PasswordReplace` (replaces Microsoft-account passwords when converting to local accounts),
`ISO`/`OOBE`/`Software` (ISO-injection options), `UseKernelDriver` ("use the kernel driver for
higher privileges, unnecessary in most cases") [docs configuration].

Snippet — playbook.conf (7 lines):
```xml
<Playbook>
    <Name>Example PB</Name>
    <UniqueId>UNIQUE ID</UniqueId>
    <Version>0.1</Version>
    <SupportedBuilds>
        <string>22000</string>
        <string>22621</string>
    </SupportedBuilds>
</Playbook>
```
Source: docs.amelabs.net/developers/configuration.html — © Ameliorated (official docs; no
license notice found on the page; short excerpt for research only).

Actions (the complete documented set, 14): `!run` (executable/file), `!registryKey`
(add/delete key), `!registryValue` (modify value), `!appx` (remove/clearCache APPX),
`!service`, `!scheduledTask` (delete folder / modify task), `!taskKill`, `!systemPackage`
(remove Windows component), `!cmd`, `!powerShell`, `!download` (URL or git release),
`!software` (chocolatey-style install), `!status` (progress text), `!task` (include another
YAML task file) [docs actions].

Universal optional parameters on every action: `weight` (progress bar), `status`,
`errorAction` (**Ignore / Log / Notify / Halt** — failure semantics), `option`/`options`
(feature gating), `builds` (conditions above), `cpuArch`, `onUpgrade`, `onUpgradeVersions`,
`previousOption`, `iso` (true/false/only), `oobe` (null/true/false/only) [docs actions].

Snippet — registry task (5 lines):
```yaml
title: Registry Edits
actions:
  - !registryValue: {path: 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting', value: 'Disabled', type: REG_DWORD, data: '1'}
  - !registryValue: {path: 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced', value: 'Hidden', type: REG_DWORD, data: '1'}
```
Source: docs.amelabs.net/creating_playbooks.html — © Ameliorated (official docs; excerpt only).

Feature declaration (how playbooks present user choices): `FeaturePages` in playbook.conf
define wizard pages of three types — **CheckboxPage, RadioPage, RadioImagePage** — with
`Options` (each carrying a `Name` used in YAML), `TopLine`/`BottomLine` text (+ links),
`DependsOn` (page shown only if a previous option was selected), and `IsRequired`. YAML gates
execution with `option: <name>` and inverse selection with `option: "!<name>"` [docs
features/pages.html + features/features-in-yaml.html].

Requirements / preflight checks (12 documented values): `Internet`, `NoInternet`, `Activation`,
`FreshInstall` (install ≤ 40 h old; "easily bypassable in the UI"), `DefenderToggled` ("toggle
the primary four Windows Security toggles"), `DefenderDisabled` ("neutralize defender via the
**Prepare System** step"), `UCPDDisabled` (disable the UCPD driver via Prepare System),
`NoAntivirus` (checks WMI `root/SecurityCenter2` `AntivirusProduct` for non-Defender AV),
`NoPendingUpdates`, `PasswordSet` (converts Microsoft accounts to local), `AdministratorPasswordSet`,
`PluggedIn` [docs requirements].

Updates: a `Git` property (GitHub/Gitea/GitLab) — release **tag must match playbook Version**
and each release must contain exactly one `.apbx` asset, which the wizard downloads for
updates [docs updates]. Upgrades: `UpgradableFrom` (version ranges, `any`, or lists;
`AllowUnsupportedUpgrades` to block unsupported paths); action-level `onUpgrade` /
`onUpgradeVersions` / `previousOption` control re-application — re-running the same playbook
version triggers only `onUpgrade: false` actions [docs upgrades].

Packaging/distribution quirk: `.apbx` = 7-Zip archive with the fixed public password **"malte"**;
docs state the rationale outright: "Encryption protects your playbook from being scanned by
browsers or antivirus software for executables." A developer "PrivacyCore" playbook is offered
from download.ameliorated.io with the same password [docs creating_playbooks].

**C. Rollback / "undo" architecture and its limits (DOCUMENTED — this is the critical section for the engine decision)**

- Official statement of the current state: "**Currently, AME Beta lacks a standardized way to
  uninstall playbooks once applied to a system. Each playbook creator provides their own
  removal method.**" And: "Universal playbook reversibility is currently under heavy development
  and is a confirmed feature for future releases before AME v.1.0." [docs remove_upgrade.html,
  read 2026-11-23 — i.e., not yet shipping in v0.8.4].
- What removal looks like today for the first-party Privacy+ playbook: open the "Privacy+
  Settings" app (github.com/Ameliorated-LLC/ame-settings-cli) → "Uninstall Privacy+ Playbook"
  → **supply an up-to-date Windows 11 ISO** → "The process upgrades your system with the latest
  Windows version, restoring removed services, undoing registry edits, and uninstalling added
  software" → reboot. In other words, the documented undo for Privacy+ is an **in-place Windows
  upgrade/repair using an ISO**, not an incremental restore [docs remove_upgrade.html].
- The docs contain **no mention of automatic restore-point creation, per-value registry
  backup/restore, or transactional undo** anywhere in the pages read (actions, tasks, upgrades,
  running-playbook). `errorAction` (Ignore/Log/Notify/Halt) governs *runtime failure handling*,
  not rollback [docs actions]. Rollback, where it exists at all, is a per-playbook,
  author-provided mechanism: the docs note "ReviOS uses a reversible deletion method" —
  ReviOS implements its own reversibility [docs creating_playbooks].
- What this means for "what it does and does not restore": **the platform itself guarantees
  nothing**. A given playbook may restore what its author scripted (Privacy+: services,
  registry edits, added software — via ISO upgrade; terminated/deleted items are only restored
  by that full upgrade path); the platform's own docs recommend VM testing: "Always test
  actions in a virtual machine to avoid system damage." [docs creating_playbooks warning].
- Re-application/upgrade semantics are the only built-in "statefulness": version tracking via
  `UniqueId` + `Version`, `onUpgrade` gating, and option memory across upgrades [docs upgrades].

**D. Open vs closed source (IMPLEMENTED where verified)**

- [IMPLEMENTED] GitHub org `Ameliorated-LLC` hosts **9 public repos** (listing read):
  `trusted-uninstaller-cli` (C#, 371★, "Core functionality for AME Wizard", MIT badge),
  `privacy_plus` (Batchfile 86.2% / PowerShell 10.8% / JS 3%, 93★, 8 releases, latest v0.8.2
  on 2025-10-03, 1 contributor, last commit 2025-10-22), `AME-10` (Batchfile, 44★),
  `ame-settings-cli` (Privacy+ settings tool, C#), `ame-settings-legacy`, `ame-assassin`
  ("removing APPX packages bypassing DISM… removing system components"), `ame-sfc-interface`
  ("interfacing with sfc.exe to warn against usage of sfc /scannow"), `appfetch` (MIT),
  `jumper` (MIT).
- [IMPLEMENTED] `trusted-uninstaller-cli` default branch is `public`; root contains
  `LICENSE.md` = full **MIT License, "Copyright (c) Ameliorated LLC"** (text read in full).
- [IMPLEMENTED] `privacy_plus` repo root (branch `public`) contains **only** `.gitea/` and
  `src/` — **no LICENSE file** (also confirmed 404 on raw `LICENSE` and `LICENSE.md`).
  Same for `AME-10`: root contains only `.gitea/` and `src/` — no LICENSE file.
- [IMPLEMENTED absence] No repository for the AME Beta wizard GUI application exists in the
  org's 9 repos; the homepage "Open source" section links only to `trusted-uninstaller-cli`
  and says "Most of our software is released under the MIT license" [DOCUMENTED, ameliorated.io].
  → Verified summary: **deletion engine = open (MIT); wizard GUI = not published; official
  playbooks = source public, no license granted.**
- Engine capability claim: "AME Beta is capable of, while the operating system is running,
  deleting any specified file on the file system without causing a crash. This includes files
  usually locked by the system integrity protection. Each file is verified to confidently
  ensure the deletion was successful." [DOCUMENTED, ameliorated.io]. Also: "Full regex support
  for actions" [same page].

**E. Licenses and distribution terms**

- Core engine: MIT (permissive; commercial use, modification and redistribution permitted with
  notice retention) [IMPLEMENTED, LICENSE.md read].
- Wizard binary: **no EULA or distribution-license page found** on ameliorated.io or in the docs
  (limitation — the wizard displays a playbook-run "license agreement" page per the
  running-playbook guide, but its text is not published online) [DOCUMENTED for the page's
  existence; text unavailable].
- Official playbooks (Privacy+, AME 10): published source, **no LICENSE file** [IMPLEMENTED].
  *Inference (labeled as such):* absent a license, default copyright applies — modifying and
  redistributing their playbook content has no granted permission; the docs themselves state
  ReviOS "requires removing their product code before modification" [DOCUMENTED].
- The security-exceptions guide warns against modified builds: "Untrusted, or modified builds
  from third party websites or social media may be vectors for malware, and Ameliorated takes
  no responsibility…" [DOCUMENTED].

**F. Playbook verification and redistribution restrictions (DOCUMENTED)**

- Verification is **reputation-gated and manual**: "Ameliorated gives out verification status
  only for well known playbooks with a good reputation. If you believe you fit this criteria,
  contact @styris_ame or @actrons on Discord or Telegram." A `ProductCode` integer (issued by
  AME) in `playbook.conf` makes the wizard detect the playbook as verified, and "**if you
  change the Playbook, it will need to be verified again**" [docs verification]. The
  `Website` property becomes a verification dropdown only for verified playbooks [docs configuration].
- Redistribution-relevant facts, exactly as documented: any modified third-party playbook
  loses its verified status (re-verification requires AME's approval); the ReviOS playbook
  "requires removing their product code before modification" [docs creating_playbooks]; the
  ecosystem-curated list on the homepage is "verified Playbooks from leading projects" (AtlasOS,
  ReviOS) [ameliorated.io]; an icon convention (256px `playbook.png` based on the official
  frame) is recommended [docs verification]. No automated/public signing scheme is documented
  — verification is a centralized, discretionary process over Discord/Telegram.
- Distribution packaging uses the fixed-password encrypted `.apbx` (see section B) — the
  official rationale is AV-scanning evasion [docs creating_playbooks].

**G. Security posture (DOCUMENTED — matters for the engine decision)**

- Unsigned beta builds: "Windows Security may automatically flag AME Wizard Beta as malicious…
  or may even delete it before given the chance to execute" — the guide instructs users to add
  Defender exclusions for their **Downloads and %Temp% folders** and to allow the detected
  "Trojan Script" threat; SmartScreen requires "Run anyway" [docs security-exceptions]. The
  docs state no beta build will be code-signed [same page].
- Requirement vocabulary normalizes security-tool neutralization as preflight steps:
  `DefenderDisabled` ("neutralize defender via the Prepare System step"), `DefenderToggled`
  (toggle the primary four Windows Security toggles), `UCPDDisabled`, `NoAntivirus` [docs requirements].
- `UseKernelDriver` playbook option: "use the kernel driver for higher privileges" [docs configuration].
- First-party tooling reflects post-tweak system state: `ame-sfc-interface` exists to "warn
  against usage of `sfc /scannow`" on ameliorated systems [IMPLEMENTED repo description].

**H. Community presence (COMMUNITY-CLAIM, light — deep ReviOS/AtlasOS research belongs to other subagents)**

- A Linus Tech Tips forum thread discusses AME Wizard (linustechtips.com/topic/1500973); a
  Hacker News thread exists ("Ameliorated: Windows 10 and 11 minus the spyware",
  news.ycombinator.com/item?id=35398294) [COMMUNITY-CLAIM, existence only; contents not read].
- The vendor's homepage links an LTT video ("In an early incarnation, AME was featured on
  Linus Tech Tips") and Wolfgang's Channel videos [DOCUMENTED as vendor-claimed endorsements].

### Useful ideas for NEXTRIX (shortlist)

1. **Declarative action vocabulary** — 14 typed YAML actions (`!registryValue`, `!service`,
   `!scheduledTask`, `!cmd`, `!powerShell`, `!appx`, `!systemPackage`, `!taskKill`…) with a
   universal parameter set. A constrained, auditable vocabulary beats free-form scripts for
   static analysis, dry-run, and documentation generation — a strong schema to emulate in a
   PowerShell engine [DOCUMENTED].
2. **Build/CPU-conditional execution** — `builds: ['>=22621', '!>22625']` with update-revision
   precision (`22621.1265`) and `cpuArch` gating maps directly onto NEXTRIX's hardware-aware
   requirement [DOCUMENTED].
3. **Preflight requirement gates** — a typed checklist (pending updates, third-party AV present,
   plugged in, activation, install age) run before any change [DOCUMENTED].
4. **Feature pages + option gating** — Checkbox/Radio pages with `DependsOn`, `IsRequired`, and
   `option` / `!option` YAML gating is a clean user-choice model wired to execution [DOCUMENTED].
5. **Upgrade-aware re-application** — `UpgradableFrom`, `onUpgrade`, `onUpgradeVersions`,
   `previousOption`, and "re-run same version only triggers `onUpgrade:false`" — version-bound
   state tracking that prevents duplicate application [DOCUMENTED].
6. **Git-release update channel** — tag = version, one artifact per release, three git hosts
   supported [DOCUMENTED].
7. **The decisive negative lesson** — the platform's own docs admit there is **no standardized
   undo** (removal = ISO-based Windows upgrade for Privacy+; universal reversibility is
   "before v.1.0" future work). NEXTRIX's rollback-safety requirement cannot be delegated to
   AME Wizard today; if a hybrid is chosen, rollback must be NEXTRIX's own layer
   (per-value/per-object snapshots + restore), independent of the apply engine [DOCUMENTED].

### Reject / caution (AME Wizard) — with reasons

- **No standardized rollback/uninstall today** [DOCUMENTED] — direct conflict with NEXTRIX's
  rollback-safe requirement if the AME engine were chosen as-is; removal for the flagship
  playbook requires downloading a Windows ISO and performing an upgrade.
- **Unsigned beta binary + documented instruction to whitelist Downloads/%Temp% in Defender**
  [DOCUMENTED] — the opposite of a trust-first posture; a NEXTRIX-branded artifact must never
  require AV exclusions.
- **`.apbx` encryption with a fixed password, explicitly to prevent AV scanning of embedded
  executables** [DOCUMENTED rationale] — never replicate this pattern.
- **`UseKernelDriver` elevation option and Defender/UCPD neutralization requirements**
  [DOCUMENTED] — high-risk surface; NEXTRIX should treat kernel-driver elevation and
  security-tool disabling as hard "never by default" tiers.
- **Licensing ambiguity for playbook content** — official playbooks ship without LICENSE files
  [IMPLEMENTED]; do not copy Privacy+/AME-10 playbook task code into NEXTRIX without a
  permission grant. MIT covers only the trusted-uninstaller engine (and some small tools).
- **Centralized, discretionary verification** — verified status requires Discord/Telegram
  outreach and re-verification after any change [DOCUMENTED]; NEXTRIX cannot rely on it, and a
  NEXTRIX playbook would necessarily ship "unverified" by their gatekeepers.
- **Beta-state documentation flux** — "AME Wizard" vs "AME Beta" naming, dual docs domains
  (docs.amelabs.net vs docs.ameliorated.io links), docs-only changelog, and "integrating and
  curating these options… before version 1.0" language [DOCUMENTED] — schema and behavior may
  still shift under a 0.x version.

---

## Engine-decision implications (inference from the above evidence — labeled as inference)

- A pure **AME Wizard playbook** strategy conflicts with two NEXTRIX pillars today: no
  standardized undo (documented absence) and a trust-hostile distribution posture (unsigned
  binary, AV exclusions, fixed-password encrypted packages, kernel-driver option).
- The AME **schema** (typed actions, build/cpu conditions, requirement gates, feature pages,
  upgrade semantics) is well-designed and directly portable to a **PowerShell engine** with
  declarative manifests — capturing its benefits without its runtime trust debt.
- If a **hybrid** is considered, the safe division of labor is: AME-style declarative
  manifests → compiled/executed by NEXTRIX's own engine with NEXTRIX's own snapshot/restore
  layer; never require the AME binary itself for a rollback-safe flow.
- Hone contributes methodology (tweak-admission gates, metric matching, session-scoped
  reversible tweaks, exclusion lists, session reports) but no auditable internals and no
  independently verified results — citation-only reference.

---

## Research limitations

- **Reddit threads were not directly readable.** old.reddit.com returned an empty page shell
  and firecrawl refused reddit.com ("currently not supported"). All Reddit evidence above is
  from search-result titles and snippet text (quoted where used); full thread bodies, vote
  counts, and context are unverified. The two r/pcmasterrace threads and one r/pchelp thread
  are cited by URL so a later pass can retry them.
- **YouTube reviews were not watched** (video content analysis out of scope for this run);
  skeptical Hone reviews are recorded by existence/title only.
- **Hone is closed-source**: nothing about its internals was inspected (and per the task rules
  nothing was installed or executed). All Hone findings are DOCUMENTED/COMMUNITY-CLAIM; every
  Hone performance figure is DEV-BENCHMARK. No VERIFIED (independently reproduced) performance
  results exist in this file for either target.
- **Hone pricing** was captured from a server-rendered checkout page (USD 5.99/mo; USD 39.99/yr);
  the /premium page's own price widget did not render server-side and the vendor states regional
  pricing varies — other regions may differ.
- **AME wizard EULA text is not published online** as far as could be found; the wizard shows a
  license agreement at runtime (per docs), which this read-only research did not and could not
  run. Wizard-binary distribution terms therefore remain unverified (limitation, not absence).
- **No wizard release history** is published; v0.8.4 is from the homepage download label and the
  docs changelog covers documentation changes only.
- **GitHub access quirks**: direct api.github.com via plain fetch was rate-limited (HTTP 403);
  metadata was obtained through proxied fetches instead. The raw `LICENSE` paths at `master`/
  `main` 404 because the default branch is `public` (LICENSE.md found there). The license-field
  JSON for trusted-uninstaller-cli was truncated by the fetch, but the license text itself was
  read in full from raw.githubusercontent.com (MIT confirmed) and the org listing shows the MIT
  badge.
- **XOS, SapphireOS, Vain, and UltraOS playbooks** named in the task brief were not individually
  researched here (platform-level scope; those belong to other researchers — see
  `r3-sapphire-vain.md`). AtlasOS and ReviOS were covered only to the extent the AME docs
  and homepage document them as verified playbooks.
- **docs.ameliorated.io vs docs.amelabs.net**: the product site links to docs.ameliorated.io
  while the same content is served at docs.amelabs.net; treated as one official documentation
  set (amelabs appears to be the current brand; "Amelabs" branding on both).
- Web search via the default search tool failed (HTTP 402) at the start of this session; all
  searches were performed through the firecrawl search backend instead. This is noted for
  provenance, not as a claim about any source.

Access date: 2026-11-23. Researcher: NEXTRIX subagent R6.
