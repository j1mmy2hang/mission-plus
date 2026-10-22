"""Adds one release to appcast.xml, newest first.

Usage: appcast.py appcast.xml --version 1.1.0 --build 42 --url <zip url>
                  --signature 'sparkle:edSignature="…" length="…"' --notes notes.md
"""
import argparse
import email.utils
import html
import re

parser = argparse.ArgumentParser()
parser.add_argument("appcast")
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--url", required=True)
parser.add_argument("--signature", required=True, help="output of Sparkle's sign_update")
parser.add_argument("--notes", required=True, help="Markdown release notes")
parser.add_argument("--minimum-system-version", default="14.0")
args = parser.parse_args()


def inline(text):
    text = html.escape(text, quote=False)
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)


def notes_html(markdown):
    """The small Markdown subset the changelog uses: paragraphs and "- " lists, with **bold**."""
    blocks, items, para = [], [], []

    def flush():
        if para:
            blocks.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()
        if items:
            blocks.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith("- "):
            if para:
                flush()
            items.append(stripped[2:])
        elif items:
            items[-1] += " " + stripped  # continuation of a list item
        else:
            para.append(stripped)
    flush()
    return "\n".join(blocks)


item = f"""    <item>
      <title>{args.version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{args.minimum_system_version}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes_html(open(args.notes).read())}
      ]]></description>
      <enclosure url="{args.url}" type="application/octet-stream" {args.signature.strip()}/>
    </item>
"""

feed = open(args.appcast).read()
if f"<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>" in feed:
    raise SystemExit(f"appcast.xml already has {args.version}")
# Newest first: insert before the first existing item, or before </channel> when there is none.
anchor = feed.find("    <item>")
if anchor == -1:
    anchor = feed.find("  </channel>")
open(args.appcast, "w").write(feed[:anchor] + item + feed[anchor:])
