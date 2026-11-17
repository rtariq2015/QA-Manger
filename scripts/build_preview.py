"""Build a standalone, offline screenshot gallery of the eight application tabs.

Use current native-host captures, never the design-option mockups. The gallery
embeds its PNGs and does not run the application or connect to any network.
"""

import argparse
import base64
import html
import json
from pathlib import Path


PAGES = (
    ("today", "Today", "Today's Daily report receipt and a compact Monthly summary."),
    ("monthly", "Monthly", "Set the department checklist, find Monthly PDFs and see their documented tests."),
    ("reports", "Reports", "Search and filter the complete saved report library."),
    ("review", "Review", "Read the full PDF, then approve or disapprove its suggested filing type."),
    ("exports", "Exports", "Choose scanners and dates, then check the reports included in a ZIP package."),
    ("folders", "Folders", "Open the organized PDF folders, export the complete library or create a full backup."),
    ("trends", "Trends", "Compare printed measurements over time and open their source PDFs."),
    ("settings", "Settings", "Manage connections, archive storage, PDF reading, backups, and updates."),
)
DETAILS = (
    ("review-queue/review-saving-1024x768.png", "Review while two file decisions are saving"),
    ("review-queue/review-saving-683x384.png", "Review at a 200% effective workstation viewport"),
    ("review-queue/review-queued-browsing.png", "Browse reports while file decisions save"),
    ("review-queue/review-queue-settled.png", "Confirmed filing and available Undo"),
    ("support-activity-web-demo.png", "Support and activity export"),
    ("support-print-web-demo.png", "Printable diagnostic report"),
    ("automatic-filing-web-demo.png", "Automatic filing and optional scanner overrides"),
    ("content-basic-web-demo.png", "Report contents"),
    ("content-continuous-pdf-web-demo.png", "Continuous PDF review"),
    ("python-measurements-web-demo.png", "Printed measurements"),
    ("trends-measurements-web-demo.png", "Measurement trends with source evidence"),
    ("daily-readings-web-demo.png", "Daily report readings"),
    ("slice-thickness-trends-web-demo.png", "Slice thickness in millimetres"),
    ("grouped-review-web-demo.png", "Explicit file types and grouped review"),
    ("daily-calendar-web-demo.png", "Saved Daily report calendar"),
    ("monthly-alignment-trends-web-demo.png", "Monthly alignment measurements"),
    ("monthly-documents-web-demo.png", "Monthly documents and checklist coverage"),
    ("table-position-trends-web-demo.png", "Continuous and stepwise table-position measurements"),
    ("python-reader-settings-web-demo.png", "PDF reading preferences"),
)


def capture(path: Path, label: str) -> str:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Expected a PNG screenshot: {path}")
    encoded = base64.b64encode(data).decode("ascii")
    return f'<img alt="{html.escape(label, quote=True)} — application screenshot with synthetic reports" src="data:image/png;base64,{encoded}">'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--version", default="5.7.10")
    parser.add_argument("--images-dir", type=Path, default=Path(__file__).resolve().parents[1] / "docs" / "images")
    parser.add_argument("--include-details", action="store_true", help="Include available report-content and Python-reader captures from the same validation run.")
    args = parser.parse_args()

    figures = []
    available = {}
    for page, title, description in PAGES:
        available[page] = []
        for theme in ("light", "dark"):
            filename = f"{page}-{theme}-web-demo.png"
            path = args.images_dir / filename
            required = theme == "light" or page in {"today", "review"}
            if not path.is_file():
                if required:
                    raise FileNotFoundError(f"Missing current application capture: {path}")
                continue
            available[page].append(theme)
            label = f"{title} · {theme.capitalize()} appearance"
            figures.append(f'<figure data-view="{page}" data-theme="{theme}" hidden><figcaption><strong>{html.escape(label)}</strong><span>{html.escape(description)}</span></figcaption>{capture(path, label)}</figure>')

    detail_figures = []
    if args.include_details:
        for filename, label in DETAILS:
            path = args.images_dir / filename
            if path.is_file():
                detail_figures.append(f'<details class="detail-capture"><summary>{html.escape(label)}</summary>{capture(path, label)}</details>')

    buttons = "".join(f'<button type="button" data-view="{page}" role="tab" aria-selected="false" aria-controls="screenshots">{html.escape(title)}</button>' for page, title, _ in PAGES)
    version = html.escape(args.version)
    page = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CT QA Manager Pro __VERSION__ · Interface gallery</title>
<style>
:root{font-family:'Segoe UI',system-ui,sans-serif;color:#1b3e43;background:#f2f6f3;line-height:1.6;color-scheme:light}*{box-sizing:border-box}body{margin:0;padding:36px 28px 26px}main{max-width:1440px;margin:auto}h1,p{margin:0}header{display:flex;justify-content:space-between;align-items:center;gap:24px;margin-bottom:23px}.eyebrow{font-size:10px;font-weight:700;letter-spacing:2px;color:#0b7f6e;margin-bottom:8px}h1{font-size:clamp(25px,3vw,36px);font-weight:650;letter-spacing:-1px;line-height:1.2}.intro{max-width:770px;font-size:13px;color:#657f80;margin-top:12px}.version{font-size:11px;color:#406c62;border:1px solid #cde3d8;background:#e6f2ea;border-radius:20px;padding:7px 13px;white-space:nowrap}.gallery-controls{display:flex;align-items:center;justify-content:space-between;gap:18px;margin:27px 0 18px;padding:10px;background:#fff;border:1px solid #d9e5df;border-radius:12px}nav,.themes{display:flex;gap:5px;flex-wrap:wrap}button{font:600 12px/1.4 'Segoe UI',system-ui,sans-serif;border:1px solid transparent;padding:10px 16px;border-radius:7px;background:transparent;color:#617d7d;cursor:pointer}button:hover{background:#edf5ef;color:#0b7464}button:focus-visible,summary:focus-visible{outline:3px solid #42b69a;outline-offset:3px}button[aria-selected=true]{background:#0b7f6e;color:white;box-shadow:0 2px 5px #1e5c4514}.themes{padding-left:13px;border-left:1px solid #e2ebe6}.themes button{font-size:10px;padding:8px 11px}.themes button[aria-pressed=true]{background:#e8f3ec;color:#0b7464;border-color:#bcd8ca}.themes button:disabled{opacity:.35;cursor:default}.preview-note{font-size:11px;color:#647d7d;margin-bottom:15px;display:flex;align-items:center;gap:8px}.preview-note:before{content:'';width:6px;height:6px;border-radius:50%;background:#67af92;flex:none}figure{margin:0;background:white;border:1px solid #d8e3dd;border-radius:13px;overflow:hidden;box-shadow:0 5px 20px #214c3f06}figure[hidden]{display:none}figcaption{display:flex;align-items:center;justify-content:space-between;gap:16px;border-bottom:1px solid #dce7e0;padding:15px 19px;font-size:11px}figcaption strong{font-weight:650;white-space:nowrap}figcaption span{font-size:10px;color:#718986;text-align:right}img{display:block;width:100%;height:auto}.details-gallery{margin-top:23px}.detail-capture{background:white;border:1px solid #d8e3dd;border-radius:10px;margin-bottom:12px;overflow:hidden}.detail-capture summary{font-size:12px;font-weight:600;padding:14px 18px;cursor:pointer}.detail-capture[open] summary{border-bottom:1px solid #d8e3dd}footer{display:flex;justify-content:space-between;gap:16px;margin-top:19px;font-size:10px;color:#708883}@media(max-width:900px){.gallery-controls{align-items:flex-start;flex-direction:column;gap:10px}.themes{border-left:0;padding-left:3px}nav button{padding:9px 13px}figcaption{align-items:flex-start;flex-direction:column;gap:5px}figcaption span{text-align:left}}@media(max-width:600px){body{padding:22px 13px}header{align-items:flex-start;gap:14px}.intro{font-size:11px}.version{font-size:9px;padding:5px 9px}.eyebrow{font-size:8px;letter-spacing:1.3px}nav{gap:3px}nav button{font-size:10px;padding:8px 10px}footer{flex-direction:column;gap:4px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto}}
</style></head><body><main><header><div><p class="eyebrow">CT QA MANAGER PRO · INTERFACE GALLERY</p><h1>A clearer view of your QA workspace</h1><p class="intro">Explore the eight separate tabs and the light and dark appearances. These are screenshots of the application using synthetic demonstration reports, not an interactive copy of the program.</p></div><span class="version">Version __VERSION__</span></header>
<div class="gallery-controls"><nav role="tablist" aria-label="Application views">__BUTTONS__</nav><div class="themes" role="group" aria-label="Screenshot appearance"><button type="button" data-appearance="light" aria-pressed="true">Light</button><button type="button" data-appearance="dark" aria-pressed="false">Dark</button></div></div>
<p class="preview-note">Screenshots only. Open the portable application to search, review, export, or change settings.</p><section id="screenshots" aria-label="Selected application screenshot">__FIGURES__</section>__DETAILS__<footer><span>Embedded screenshots · Opens offline · Synthetic demonstration data</span><span>Received reports and filing decisions do not mark clinical QA as passed.</span></footer></main>
<script>
'use strict';
const available=__AVAILABLE__;let selectedView='today',selectedTheme='light';
function show(view,theme){selectedView=view;selectedTheme=available[view].includes(theme)?theme:'light';document.querySelectorAll('figure[data-view]').forEach(figure=>figure.hidden=figure.dataset.view!==selectedView||figure.dataset.theme!==selectedTheme);document.querySelectorAll('nav button[data-view]').forEach(button=>{const active=button.dataset.view===selectedView;button.setAttribute('aria-selected',String(active));button.tabIndex=active?0:-1;});document.querySelectorAll('[data-appearance]').forEach(button=>{button.disabled=!available[selectedView].includes(button.dataset.appearance);button.setAttribute('aria-pressed',String(button.dataset.appearance===selectedTheme));});}
document.querySelectorAll('nav button[data-view]').forEach(button=>{button.addEventListener('click',()=>show(button.dataset.view,selectedTheme));button.addEventListener('keydown',event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const tabs=[...document.querySelectorAll('nav button[data-view]')],index=tabs.indexOf(button);const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;show(tabs[next].dataset.view,selectedTheme);tabs[next].focus();});});
document.querySelectorAll('[data-appearance]').forEach(button=>button.addEventListener('click',()=>show(selectedView,button.dataset.appearance)));show(selectedView,selectedTheme);
</script></body></html>'''
    replacements = {
        "__VERSION__": version,
        "__BUTTONS__": buttons,
        "__FIGURES__": "".join(figures),
        "__DETAILS__": '<section class="details-gallery" aria-label="Additional application screenshots">' + "".join(detail_figures) + "</section>" if detail_figures else "",
        "__AVAILABLE__": json.dumps(available, separators=(",", ":")).replace("<", "\\u003c"),
    }
    for marker, replacement in replacements.items():
        page = page.replace(marker, replacement)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(page, encoding="utf-8")
    print(f"Built {output} with {len(figures)} application captures and {len(detail_figures)} detail captures.")


if __name__ == "__main__":
    main()
