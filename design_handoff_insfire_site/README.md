# Handoff: Insfire Studio — website + self-hosted CMS

## Overview

Insfire Studio (Kota Kinabalu, Sabah, Malaysia) is a creative storytelling agency. This package covers building their public marketing site plus a lightweight, authenticated CMS that a non-developer owner edits directly — no code changes, no redeploy, to change copy, colours, typography, section order, projects, team or SEO.

The design already exists and works as an HTML prototype, including a fully functional editor. What it lacks is a backend: content and media live in one browser (`localStorage` + IndexedDB), so nothing the owner uploads is visible to visitors, and the editor has no authentication. **This build adds the server layer and ports the existing UI onto it.**

Target: **Cloudflare Pages + Functions, D1 (content), R2 (media), Cloudflare Access (auth).** Rationale in "Architecture" below. Domain `insfire.org` is already registered and live on Cloudflare with DNS and TLS working.

## About the design files

`reference/Insfire Studio.dc.html` is a **design reference created in HTML** — a prototype showing intended look and behaviour, not production code to copy directly. It is a single-file component (it needs its sibling `support.js` to run; open it in a browser to explore).

Your task is to **recreate these designs in a real codebase** using that stack's established patterns — not to ship the prototype. The prototype is authoritative for visual design, copy, interaction and the editor's information architecture. It is *not* authoritative for code structure.

To explore it: open the file, then use the pill at the bottom of the screen to switch between **Homepage**, **Case study** and **CMS editor**. The switcher is review chrome and must not exist in production.

## Fidelity

**High-fidelity.** Final colours, typography, spacing, motion and copy. Recreate the public site pixel-accurately. The CMS editor is also hi-fi but its styling matters less than its completeness — every field listed below must exist and must write through to the site.

---

## Architecture

### Why this stack

The owner is non-technical and cost-sensitive; the domain is already on Cloudflare. This stack is one vendor, one dashboard, free-to-cheap at this traffic, and needs no server maintenance.

| Concern | Choice | Notes |
|---|---|---|
| Hosting / SSR | Cloudflare Pages | Git-connected; preview deployments per branch |
| Framework | Astro (recommended) or Next.js on Cloudflare adapter | Astro suits a mostly-static content site; islands only where motion is needed |
| API | Pages Functions (`/functions/api/*`) | Same origin, no CORS |
| Content store | D1 (SQLite) | Single `content` row holding the site JSON, plus normalised tables for projects/team/insights — see schema |
| Media | R2 + Cloudflare Images (or R2 + `/cdn-cgi/image` resizing) | Never serve raw originals |
| Video | Cloudflare Stream (preferred) or Vimeo Pro | Do **not** serve MP4 from R2 for anything over ~10 s |
| Auth for CMS | Cloudflare Access (Zero Trust) on `/admin*` + `/api/admin/*` | Identity enforced before the app runs; app reads `Cf-Access-Jwt-Assertion` |
| Cache | Pages cache + `revalidate` on publish | Public pages cached at edge; purge tag on publish |

**Do not** build a bespoke username/password system. Cloudflare Access is free for 50 users, gives email one-time-pin or Google login, and protects the route even before the app loads. Verify the `Cf-Access-Jwt-Assertion` header server-side in every `/api/admin/*` function against the team's public keys — never trust the path protection alone.

### Repo shape (Astro example)

```
src/
  pages/
    index.astro                 public homepage
    work/[slug].astro           case study page
    insights/[slug].astro       article page
    admin/[...panel].astro      CMS shell (Access-protected)
    sitemap.xml.ts
  components/site/              Hero, Problem, Services, Work, About, Team, WhyUs, Insights, Cta, Footer, Nav
  components/admin/             Field, ListEditor, MediaGrid, SlotGrid, Sidebar
  lib/
    content.ts                  load/validate site content (zod)
    media.ts                    R2 upload, variant URLs
    access.ts                   Access JWT verification
functions/
  api/content.ts                GET published content (public, cached)
  api/admin/content.ts          GET draft, PUT draft, POST publish
  api/admin/media.ts            POST upload → R2, DELETE, PATCH alt
migrations/
  0001_init.sql
```

### Draft → preview → publish

Required by the brief and worth the small cost:

- `content` table holds two rows: `draft` and `published`.
- The CMS always reads and writes `draft`.
- **Preview** renders the public site with `?preview=1` + a valid Access session, reading `draft`.
- **Publish** copies `draft` → `published`, bumps `version`, purges the edge cache.
- Keep the last 20 published versions in `content_versions` for one-click rollback.

### Schema (`migrations/0001_init.sql`)

```sql
CREATE TABLE content (
  id TEXT PRIMARY KEY,              -- 'draft' | 'published'
  json TEXT NOT NULL,               -- full site settings object (see Content model)
  version INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE content_versions (
  version INTEGER PRIMARY KEY AUTOINCREMENT,
  json TEXT NOT NULL,
  published_at TEXT NOT NULL,
  published_by TEXT
);

CREATE TABLE media (
  id TEXT PRIMARY KEY,              -- also the R2 object key prefix
  filename TEXT NOT NULL,
  mime TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  width INTEGER, height INTEGER,
  duration REAL,                    -- video only
  alt TEXT NOT NULL DEFAULT '',
  stream_uid TEXT,                  -- Cloudflare Stream id, video only
  created_at TEXT NOT NULL
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  slug TEXT UNIQUE NOT NULL,
  sort INTEGER NOT NULL,
  title TEXT NOT NULL,
  client TEXT, category TEXT, year TEXT, location TEXT,
  media_id TEXT REFERENCES media(id),
  featured INTEGER NOT NULL DEFAULT 0,
  visible INTEGER NOT NULL DEFAULT 1,
  challenge TEXT, idea TEXT, execution TEXT, result TEXT,
  gallery_json TEXT NOT NULL DEFAULT '[]',   -- ordered media ids
  seo_title TEXT, seo_description TEXT
);

CREATE TABLE team (
  id TEXT PRIMARY KEY, sort INTEGER NOT NULL,
  name TEXT NOT NULL, role TEXT, media_id TEXT REFERENCES media(id)
);

CREATE TABLE insights (
  id TEXT PRIMARY KEY, slug TEXT UNIQUE NOT NULL, sort INTEGER NOT NULL,
  title TEXT NOT NULL, category TEXT, author TEXT, date TEXT,
  cover_media_id TEXT REFERENCES media(id),
  body_html TEXT NOT NULL DEFAULT '',
  published INTEGER NOT NULL DEFAULT 0,
  seo_title TEXT, seo_description TEXT
);
```

Site-wide settings (brand, type, layout, nav, anim, hero, copy blocks, sections, cta, footer, seo) stay as one JSON blob in `content` — it is edited as a whole and never queried by field. Projects, team and insights are normalised because they need slugs, URLs and sorting.

### Content model

The prototype's editor already produces exactly the shape to use. **Export it and use it as the seed + schema source of truth:** open the prototype → CMS editor → sidebar → **Export content** → `insfire-content.json`. Validate it with zod on read and write.

Top-level keys: `brand`, `type`, `layout`, `nav`, `anim`, `hero`, `problem`, `servicesTitle`, `servicesIntro`, `services[]`, `workTitle`, `projects[]`, `about`, `teamTitle`, `teamIntro`, `team[]`, `whyusTitle`, `pillars[]`, `insightsTitle`, `insights[]`, `sections[]`, `cta`, `footer`, `seo`.

### Media pipeline

1. CMS uploads via `POST /api/admin/media` (multipart).
2. Images → R2. Generate and store width/height. Serve through Cloudflare Images or `/cdn-cgi/image/width=…,format=auto` with a `srcset` of 640/1024/1600/2400.
3. Video → Cloudflare Stream via direct-creator-upload; store `stream_uid`. Render with the Stream player or an HLS `<video>`; poster frame from Stream.
4. SVG → sanitise (strip scripts) before storing.
5. Reject >25 MB images and >2 GB video. Show progress in the CMS.
6. Never delete an R2 object while a `media_id` still references it — warn and require confirmation.

---

## Screens / views

### 1. Homepage (`/`)

Single scrolling narrative. Section order and visibility are data-driven from `sections[]` — the renderer must honour both. Default order and default on/off state:

| # | key | Section | Default |
|---|---|---|---|
| — | — | Nav (sticky) | always |
| — | — | Hero | always |
| 1 | `why` | Why it matters | on |
| 2 | `services` | How Insfire helps | on |
| 3 | `work` | Stories we've told | on |
| 4 | `about` | About Insfire | on |
| 5 | `team` | Behind the fire | **off** |
| 6 | `whyus` | Why Insfire | on |
| 7 | `insights` | Insights | **off** |
| — | — | Closing CTA | always |
| — | — | Footer | always |

The two off-by-default sections are intentional (owner isn't ready) — keep them built and switchable, not deleted.

**Nav** — sticky, `18px` vertical padding, `--pad` horizontal, `rgba(10,10,10,.72)` + `backdrop-filter: blur(14px)`, bottom border `1px solid rgba(255,255,255,.08)`. Left: wordmark `INSFIRE`, 700, 15px, `letter-spacing:.24em`. Centre: menu items, 500, 11.5px, uppercase, `letter-spacing:.18em`, opacity .82, hover → accent. Right: CTA, 600, 11.5px, uppercase, accent bottom-border, `padding-bottom:4px` — hidden below 880px. **Adaptive colour:** an IntersectionObserver watches `[data-nav]` sections; over a `light` section the header becomes `rgba(243,241,237,.86)` with `#0a0a0a` text and `rgba(10,10,10,.1)` border. Both sticky and adaptive are toggles in the CMS. Mobile: replace the inline menu with a full-screen overlay — the prototype does not design this; build it clean, 44px+ targets, same type treatment.

**Hero** — `min-height:94vh`, content bottom-aligned, `padding:140px var(--pad) calc(34px * var(--ss))`. Background: uploaded image (with `insSlowZoom` 22s ease-in-out infinite alternate, scale 1 → 1.08) or video (autoplay, muted, loop, playsinline); when empty, a diagonal striped placeholder labelled with what to upload — **the placeholder must not ship to production; if no hero media is set, fall back to flat `#0a0a0a`.** Over it: a vertical gradient whose stops are driven by `hero.overlay` (0–90%) — `rgba(10,10,10,{0.35 + ov*0.55})` → `rgba(10,10,10,{ov*0.75})` at 42% → `rgba(10,10,10,.94)`; plus a radial orange bloom at `left:-10%; top:35%; width:60%; height:40%`, `rgba(255,90,31,.22)`, `filter:blur(10px)`, animating `insSpark` (opacity .25 → .85) 9s infinite.
Content: eyebrow (mono, 11px, `.34em`, uppercase, accent); H1 two lines + accent full stop, 700, `clamp(44px,11vw,168px) * --hs`, `line-height:.88`, `letter-spacing:var(--hls)`; then a 3-up auto-fit row — supporting paragraph (300, `calc(var(--bs)*1.25)`, max 30ch), button pair, and right-aligned two-line category text (mono, 10.5px, `.22em`, `line-height:2`).
Primary button: accent fill, `#0a0a0a` text, 600/12.5px/uppercase/`.14em`, `padding:17px 26px`, `min-height:48px`, hover → white fill + `translateY(-2px)`, transition `.35s cubic-bezier(.2,.8,.2,1)`. Secondary: text + `1px` bottom border `rgba(255,255,255,.35)`, hover → accent.

**Why it matters** — `#0a0a0a`, top border `rgba(255,255,255,.07)`. Optional section number (mono, 10.5px, `.3em`, `rgba(242,240,236,.38)`) gated by `layout.showNumbers`. H2 two lines, second line `rgba(242,240,236,.34)`, 700, `clamp(30px,6.4vw,92px) * --hs`, max 22ch. Below, two columns: left = intro paragraph, three bullets in a stack with a `1px` accent left border and `22px` padding, closing line; right = three stacked statements at `clamp(26px,4.6vw,64px) * --hs` — full ink, `rgba(242,240,236,.5)`, accent.

**How Insfire helps** — paper background `#f3f1ed`, ink text. Header row: H2 (max 18ch) and a 34ch intro. Then a bordered list, one row per capability group: `grid-template-columns: minmax(0,auto) minmax(0,1.2fr) minmax(0,1fr)`, `gap: clamp(16px,4vw,60px)`, `padding: clamp(26px,4vw,52px) 0`, `border-bottom: 1px solid rgba(10,10,10,.14)`, hover `background: rgba(10,10,10,.03)` over `.4s`. Cells: number (mono, accent, 600), title (700, `clamp(30px,5vw,68px) * --hs`, `line-height:.95`), and the items list (one per line from a newline-separated field, `calc(var(--bs)*.92)`, `rgba(10,10,10,.66)`).

**Stories we've told** — 12-column grid, `gap: clamp(14px,2.2vw,34px)`, deliberately asymmetric. Featured projects sort first; the first six render with spans `[12,7,5,12,6,6]` and aspect ratios `['16/7','4/3','1/1','21/8','4/3','4/3']`; the third item is bottom-aligned (`align-self:end`). Image hover: `scale(1.04)` over `.8s cubic-bezier(.2,.8,.2,1)`; container hover: `outline: 1px solid` accent. Featured badge: accent chip, `#0a0a0a`, mono 10px, `.18em`, `padding:6px 10px`, top-left at 18px. Caption below each: meta line (mono 10.5px `.24em` uppercase — accent when featured, else `rgba(242,240,236,.5)`), title (first item 600 at `clamp(20px,2.6vw,38px)`, rest 500 at `clamp(17px,1.8vw,26px)`), and a right-aligned `year · location` stamp. Each card links to `/work/[slug]`.

**About Insfire** — paper. Two columns. Left: H2 four lines with the last word in accent, 700, `clamp(30px,5.6vw,80px) * --hs`, `line-height:.98`; below it a serif statement in **Instrument Serif** at `calc(var(--bs)*1.6)`, `line-height:1.35`, `rgba(10,10,10,.78)`, max 32ch. Right: body paragraph (300, max 44ch) then a 3-up stats row above a `1px solid rgba(10,10,10,.16)` top border — value 700 at `clamp(22px,2.6vw,40px)` with an accent suffix, label mono 10px `.18em` uppercase `rgba(10,10,10,.5)`.

**Behind the fire** (off by default) — paper, continues without a new background. Header row: H2 + 30ch intro, above a top rule. Portraits: auto-fit `minmax(190px,1fr)`, `3/4` ratio, name 500 at `calc(var(--bs)*.94)`, role mono 10px uppercase.

**Why Insfire** — `#0a0a0a`. H2 then auto-fit `minmax(260px,1fr)` columns, `gap: clamp(24px,3.4vw,54px)`. Each pillar: top border (**first is accent**, rest `rgba(255,255,255,.18)`), `padding-top:20px`, title 600 at `clamp(18px,2vw,28px)`, body 300 at `var(--bs)`, `rgba(242,240,236,.62)`.

**Insights** (off by default) — `#0a0a0a`, list rows `minmax(0,auto) minmax(0,3fr) minmax(0,1fr)`: category (mono, accent, uppercase), title (400, `clamp(17px,2.2vw,32px)`), date right-aligned. Row hover `rgba(255,255,255,.03)`; each links to `/insights/[slug]`.

**Closing CTA** — `#0a0a0a`, top border, centred, `padding: calc(clamp(96px,15vw,220px) * --ss) var(--pad)`. Orange bloom positioned over the first word: `left:4%; top:6%; width:46%; height:58%`, `rgba(255,90,31,.18)`, `insSpark` 11s. H2 three parts, third in accent, 700 at `clamp(32px,8vw,124px) * --hs`, `line-height:.94`. Then supporting line, the primary button (links to WhatsApp `https://wa.me/60123164569`, `target="_blank" rel="noopener"`), and a location line in mono 10.5px `.26em`.

**Footer** — `#0a0a0a`, top border `rgba(255,255,255,.1)`. Auto-fit `minmax(180px,1fr)` in four groups: wordmark + serif tagline; site menu; socials (Instagram `https://www.instagram.com/insfirestudio/`, Facebook `https://www.facebook.com/share/175BA15PGt/`); contact (`theinsfire@gmail.com` as `mailto:`, location). Bottom strip: copyright left, note right, mono 10px `.2em` uppercase `rgba(242,240,236,.35)`.

### 2. Case study (`/work/[slug]`)

Sticky header with "← All stories" and the wordmark. Hero: `min-height:70vh`, bottom-aligned, project media full-bleed under a `rgba(10,10,10,.72)` → `.35` at 45% → `.95` gradient; meta line (`client · category · year`) in mono accent; H1 700 at `clamp(32px,7vw,104px) * --hs`, max 20ch. Body: two columns — left a `max-width:60ch` stack of four labelled blocks (**The challenge / The idea / The execution / The result**, label mono 10.5px `.28em` accent, body 300 at `calc(var(--bs)*1.2)`, `line-height:1.6`), right an aside with a top rule listing Client, Category, Year, Location, Deliverables. Empty blocks and empty details are omitted, not shown blank. Below: the project gallery (`gallery_json`) as a 12-column asymmetric grid, then a "Next story →" link to the next visible project.

### 3. Insights article (`/insights/[slug]`)

Not designed in the prototype — build it consistent with the case study: dark, one column at `max-width:68ch`, cover image full-bleed above the title, category/author/date in mono accent, body from the CMS rich-text field, and a three-item "more insights" list at the end reusing the homepage row treatment.

### 4. CMS (`/admin`, Access-protected)

Two-column shell: a 236px sticky sidebar (`border-right: 1px solid rgba(255,255,255,.09)`, `height:100vh`, own scroll) and a main column capped at 1080px. Background `#0d0d0d`.

Sidebar: `INSFIRE CMS` wordmark with `CMS` in accent; three labelled groups; active item gets `rgba(255,255,255,.09)` background and a 2px accent left border. Below them: **Export content**, **Import content**, **Reset to defaults**.

Sticky topbar: tab title, a save-status note, **View site** (outline) and **Publish** (accent fill).

Tabs and their fields — all of these exist in the prototype and all must write through to the site:

- **Content → Projects** — add / reorder / delete / hide / feature; title, client, category, year, location, media, challenge, idea, execution, result. Add: slug (auto from title, editable, must be unique), gallery (multi-select, orderable), per-project SEO title/description.
- **Content → Services** — section title, intro, work-section title; capability groups (add/reorder/delete) each with title and a newline-separated items field.
- **Content → Team** — section title, intro; members with name, role, portrait.
- **Content → Insights** — section title; articles with title, category, date, link. Add: slug, author, cover image, rich-text body (TipTap or Lexical), publish/unpublish, per-article SEO.
- **Content → Media** — see below.
- **Design → Colours** — accent, ink, paper, wordmark text.
- **Design → Typography** — heading font, body font (both from a curated list: Poppins, Space Grotesk, DM Sans, Archivo, Instrument Serif, Playfair Display, Georgia, system-ui), heading scale 0.7–1.3, heading letter-spacing −60…+20 (stored in thousandths of an em), body size 14–20px.
- **Design → Layout** — container 1100–1900px, section spacing 0.6–1.6×, corner radius 0–28px, section numbers on/off.
- **Design → Navigation** — sticky on/off, adaptive colour on/off, CTA label, CTA link; menu items add/reorder/delete with label + href.
- **Design → Animations** — mode (cinematic / minimal / off), reveal travel 0–60px, reveal duration 400–1600ms.
- **Site → Hero** — eyebrow, two headline lines, supporting text, media picker, overlay 0–90%, both CTA labels and links, two category lines.
- **Site → Sections** — order (up/down) and visibility per section; plus the copy of every narrative block: Why-it-matters (headline, second line, intro, 3 bullets, closing line, 3 big lines), About (4 heading lines, serif statement, body), Why-Insfire title and pillars (add/reorder/delete), studio stats (value/suffix/label), closing CTA (3 lines, supporting text, button label, link, location).
- **Site → Footer** — tagline, email, location, copyright, right-hand note; footer menu and socials, both add/reorder/delete.
- **Site → SEO** — page title, meta description, canonical URL, robots (index,follow / noindex,nofollow), social share image.

**Media tab — the important one.** It opens with a **slot grid**: one card per media position the live site can render, in page order, each showing its current thumbnail or an accent-outlined *Empty* state. Slots are derived from content, so the count grows with it. At seed content there are **9**: hero background (1), project thumbnails (4), team portraits (3), social share image (1).

Each slot card: click anywhere on the thumbnail to upload straight into that position ("Click to upload" / "Click to replace"), plus a dropdown to re-pick any existing library item. Below the grid, a large drag-and-drop zone that accepts a batch and **fills the empty slots in page order**, reporting e.g. "6 uploaded — 4 placed on the website". Then the library grid itself: thumbnail, filename, size, an editable alt-text field, and Delete.

Preserve this slot-first design — it is what makes the CMS usable by a non-developer. Add to it: upload progress, a "used in N places" indicator per library item, and a confirm dialog on deleting an item that is still referenced.

---

## Interactions & behaviour

- **Scroll reveal** — elements marked for reveal start at `opacity:0` and `translateY(anim.distance)`, transitioning `opacity {duration}ms cubic-bezier(.2,.75,.2,1)` and `transform {duration+100}ms` when they enter the viewport (IntersectionObserver, `rootMargin:'0px 0px -8% 0px'`, `threshold:.05`), then unobserve. `minimal` caps travel at 12px; `off` and `prefers-reduced-motion: reduce` show everything immediately. Keep the prototype's safety net: a timeout that forces everything visible after `duration + 1800ms`, so content can never be stranded invisible.
- **Nav adaptive colour** — as described under Nav; observer options `rootMargin:'-70px 0px -85% 0px'`.
- **Hover** — buttons lift 2px and invert to white; project images scale 1.04; list rows tint; links go accent.
- **Case study navigation** — from a project card; "Next story" advances through visible projects and wraps.
- **CMS save** — debounce field writes ~400ms, `PUT /api/admin/content` to the draft, show "Saving…" → "Saved". On failure keep the local value and surface a retry. Optimistic UI.
- **Publish** — confirm dialog, then `POST /api/admin/content/publish`, purge cache, toast with a link to the live page and a rollback affordance.
- **Reduced motion** — respect it everywhere; never gate content on animation.
- **Responsive** — no horizontal scroll at any width, 44px minimum touch targets, type scales via `clamp()`. Test 375 / 414 / 768 / 1024 / 1440 / 1920. The prototype's CMS is desktop-first; make the admin at least usable at 768px (stack the sidebar into a top drawer).

## State management

Public pages: no client state beyond the two observers. Render server-side from `published` content; hydrate only the nav observer and the reveal observer as islands.

CMS: one content object in memory is the single source of truth (the prototype does exactly this — a deep `store` object with dotted-path `get`/`set`), plus `{tab, saveStatus, media[], uploadProgress}`. Every field is a controlled input bound to a dotted path. Media list comes from `GET /api/admin/media`. Do not scatter state per-field.

## Design tokens

Exposed as CSS custom properties on `:root` and overwritten from `brand`/`type`/`layout` so CMS changes apply without a rebuild.

| Token | Default | Meaning |
|---|---|---|
| `--accent` | `#FF5A1F` | Insfire orange — accent only, 5–10% of surface |
| `--ink` | `#0a0a0a` | Dark sections |
| `--paper` | `#f3f1ed` | Light sections |
| `--hf` | `Poppins` | Heading font |
| `--bf` | `Poppins` | Body font |
| `--hs` | `1` | Heading scale multiplier |
| `--hls` | `-0.032em` | Heading letter-spacing |
| `--bs` | `16px` | Body size |
| `--cw` | `1560px` | Container max width |
| `--ss` | `1` | Section spacing multiplier |
| `--pad` | `clamp(16px,4vw,56px)` | Page gutter |
| `--r` | `0px` | Corner radius |

Supporting inks used literally: `rgba(242,240,236,.82/.72/.62/.55/.45/.42/.38/.35)` on dark, `rgba(10,10,10,.78/.68/.66/.6/.58/.5/.16/.14)` on light. Section padding `calc(clamp(88px,13vw,190px) * var(--ss))`. Grid gaps `clamp(12px,2vw,34px)`. Mono labels use the UI monospace stack at 9.5–11px with `.14em`–`.34em` tracking, uppercase.

Fonts: Poppins 300/400/500/600/700 and Instrument Serif 400 are required; the other five are CMS options. Self-host via `@fontface` with `font-display:swap` and subset to latin — do not load all seven families from Google on the public site; load only the two the current settings use.

Keyframes: `insSlowZoom` (scale 1 → 1.08) and `insSpark` (opacity .25 → .85 → .25).

## Accessibility

Semantic landmarks (`header`/`nav`/`main`/`section`/`footer`), one `h1` per page, ordered headings. Focus visible: `2px solid var(--accent)`, `outline-offset:3px`. All media needs alt text — the CMS collects it, so surface an empty-alt warning before publish. Body text ≥4.5:1 (headline-scale type may sit at 3:1). Keyboard-operable nav and CMS. Reduced-motion honoured.

## SEO

Per-page title/description from the CMS; Open Graph + Twitter card with the chosen share image; canonical URLs; `robots.txt`; generated `sitemap.xml` covering home, each visible project and each published article. JSON-LD: `Organization` on the homepage (name, logo, `sameAs` socials, `address` Kota Kinabalu, Sabah, MY), `CreativeWork` per project, `Article` per insight. Clean URLs, no trailing-slash duplicates.

## Performance

Target LCP <2.0s on 4G Malaysia. Hero image preloaded with a responsive `srcset` and `fetchpriority="high"`; hero video lazy-attached after first paint with a poster image, never blocking LCP. Everything below the fold lazy. AVIF/WebP with JPEG fallback. Total JS on the homepage under 40KB gzipped — the site needs two observers, not a framework runtime everywhere. Cache public content at the edge, purge on publish.

## Assets still needed from the owner

Blocking: logo (SVG), favicon set, real hero film or still, project media and real challenge/idea/execution/result copy per project, team portraits. Everything in the prototype's copy is real and approved — the imagery is placeholder.

## Build order

1. Repo + Pages project + D1 + R2 bindings; migrations; seed `content` from the exported `insfire-content.json`.
2. Public homepage, fully data-driven, published content only. Ship it — parity with what is live today, then better.
3. Cloudflare Access on `/admin*` and `/api/admin/*`; JWT verification in the functions.
4. CMS shell + field renderer + all Design and Site tabs (the prototype's field definitions port almost directly).
5. Media pipeline + slot grid.
6. Projects CRUD + case-study pages + gallery.
7. Insights CRUD + article pages + rich text.
8. Draft/preview/publish + version history.
9. SEO, sitemap, schema, a11y pass, Lighthouse pass.

## Files in this bundle

- `reference/Insfire Studio.dc.html` — the design reference and working editor prototype. Open in a browser; use the bottom pill to switch views. Export its content as the seed JSON.
- `reference/support.js` — runtime the prototype needs in order to render. Not part of the production build.
