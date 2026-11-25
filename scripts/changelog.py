#!/usr/bin/env python3
"""Turns CHANGELOG.md into what each place shows. Standard library only, so it
runs on a Mac with the Xcode tools and on GitHub's Ubuntu runners alike.

  scripts/changelog.py title <version>          the release's title; fails if there's no entry
  scripts/changelog.py notes <version>          GitHub release notes, Markdown
  scripts/changelog.py html <template> <out>    the website's changelog page

The format (see the comment at the top of CHANGELOG.md): a "## <version> —
<title>" heading, the date as "_YYYY-MM-DD_", then paragraphs and "- "
bullets with inline Markdown. The app parses the same file in Changelog.swift.
"""

import datetime
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEADING = re.compile(r"^## (\d+\.\d+\.\d+) — (.+)$")
DATE = re.compile(r"^_(\d{4}-\d{2}-\d{2})_$")
REPO = "https://github.com/pego/lanes"
INSTALL = "curl -fsSL https://lanes.pego.tech/install | sh"


def parse(text):
    """[{version, title, date, blocks: [("p" | "li", markdown)]}], newest first."""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    entries, cur, block = [], None, None
    for line in text.splitlines():
        m = HEADING.match(line)
        if m:
            cur = {"version": m[1], "title": m[2].strip(), "date": None, "blocks": []}
            entries.append(cur)
            block = None
            continue
        if cur is None:
            continue
        d = DATE.match(line.strip())
        if d and cur["date"] is None and not cur["blocks"]:
            cur["date"] = datetime.date.fromisoformat(d[1])
        elif not line.strip():
            block = None
        elif line.startswith("- "):
            block = ["li", line[2:].strip()]
            cur["blocks"].append(block)
        elif block is not None:          # a wrapped line of the same paragraph or bullet
            block[1] += " " + line.strip()
        else:
            block = ["p", line.strip()]
            cur["blocks"].append(block)
    return entries


def load():
    return parse((ROOT / "CHANGELOG.md").read_text(encoding="utf-8"))


def find(version):
    for e in load():
        if e["version"] == version:
            return e
    sys.exit(f"✗ CHANGELOG.md has no entry for {version}. Add one before releasing.")


def to_markdown(e):
    out, prev = [], None
    for kind, text in e["blocks"]:
        if prev is not None and (kind == "p" or prev == "p"):
            out.append("")
        out.append(("- " if kind == "li" else "") + text)
        prev = kind
    return "\n".join(out)


def inline(md):
    """The inline Markdown CHANGELOG.md uses, as HTML."""
    codes = []

    def keep(m):
        codes.append(f"<code>{html.escape(m[1])}</code>")
        return f"\x00{len(codes) - 1}\x00"

    s = re.sub(r"`([^`]+)`", keep, md)
    s = html.escape(s, quote=False)
    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", lambda m: f'<a href="{html.escape(m[2])}">{m[1]}</a>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    s = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"<em>\1</em>", s)
    return re.sub("\x00(\\d+)\x00", lambda m: codes[int(m[1])], s)


def to_html(e, latest):
    v = e["version"]
    parts, in_list = [], False
    for kind, text in e["blocks"]:
        if kind == "li" and not in_list:
            parts.append("<ul>")
            in_list = True
        elif kind == "p" and in_list:
            parts.append("</ul>")
            in_list = False
        parts.append(f"<li>{inline(text)}</li>" if kind == "li" else f"<p>{inline(text)}</p>")
    if in_list:
        parts.append("</ul>")
    date = ""
    if e["date"]:
        d = e["date"]
        date = f'<time datetime="{d.isoformat()}">{d.day} {d.strftime("%B %Y")}</time>'
    badge = '<span class="rel-latest">Latest</span>' if latest else ""
    body = "\n      ".join(parts)
    return f"""<article class="release" id="v{v}">
    <header class="rel-head">
      <a class="rel-version" href="#v{v}">{v}</a>{badge}
      {date}
    </header>
    <h2>{html.escape(e["title"])}</h2>
    <div class="rel-body">
      {body}
    </div>
    <a class="rel-link" href="{REPO}/releases/tag/v{v}">Release on GitHub →</a>
  </article>"""


def main(argv):
    if len(argv) == 2 and argv[0] == "title":
        print(find(argv[1])["title"])
    elif len(argv) == 2 and argv[0] == "notes":
        e = find(argv[1])
        print(f"""**Install** (no security prompt):

```sh
{INSTALL}
```

Or download **Lanes.dmg** below and drag Lanes into Applications. It's not notarized, so the first launch needs System Settings → Privacy & Security → Open Anyway. Universal (Apple Silicon and Intel), macOS 13+.

**Already on Lanes 0.8.0 or later?** It updates itself within a few hours, or right away with **Settings → Updates → Check Now** or `lanes update`.

{to_markdown(e)}

*Lanes is an independent project, not affiliated with or endorsed by Anthropic.*""")
    elif len(argv) == 3 and argv[0] == "html":
        template = Path(argv[1]).read_text(encoding="utf-8")
        marker = "<!-- releases -->"
        if template.count(marker) != 1:
            sys.exit(f"✗ {argv[1]} must hold exactly one {marker} placeholder")
        entries = load()
        if not entries:
            sys.exit("✗ CHANGELOG.md has no releases")
        releases = "\n\n  ".join(to_html(e, i == 0) for i, e in enumerate(entries))
        Path(argv[2]).write_text(template.replace(marker, releases), encoding="utf-8")
    else:
        sys.exit(__doc__.strip())


if __name__ == "__main__":
    main(sys.argv[1:])
