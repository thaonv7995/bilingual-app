"""Direct document ingestion (.pdf, .epub) without lossy page decomposition.

Preserves the original document intact under `books/<slug>/source/book.<ext>`
while extracting metadata, cover art (`output/assets/cover.<ext>`), page counts,
and outline/TOC data so PDF and EPUB books integrate seamlessly with library
shelves, offline caching, backup/restore, and native Apple Books-style readers.
"""

from __future__ import annotations

import json
import posixpath
import re
import shutil
import unicodedata
import zipfile
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

from books_core.package import validate_book_slug

SUPPORTED_FORMATS = frozenset({"bkb", "pdf", "epub"})

_VIETNAMESE_D_MAP = str.maketrans({"đ": "d", "Đ": "D"})


def slugify_filename(filename: str) -> str:
    """Create a safe, deterministic book slug from an uploaded filename."""
    stem = Path(filename or "book").stem
    normalized = unicodedata.normalize("NFKD", stem.translate(_VIETNAMESE_D_MAP))
    ascii_only = normalized.encode("ascii", "ignore").decode("ascii").lower()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_only).strip("-")
    if not slug:
        slug = "book"
    slug = slug[:96].rstrip("-") or "book"
    return validate_book_slug(slug)


def infer_book_format(book_dir: Path, metadata: dict[str, Any] | None = None) -> str:
    """Determine a book's format ('bkb', 'pdf', or 'epub') from metadata or disk layout."""
    meta_fmt = str((metadata or {}).get("format") or "").strip().lower()
    if meta_fmt in SUPPORTED_FORMATS:
        return meta_fmt
    source_dir = book_dir / "source"
    if (source_dir / "book.pdf").is_file():
        return "pdf"
    if (source_dir / "book.epub").is_file():
        return "epub"
    return "bkb"


def resolve_book_source_file(
    book_dir: Path,
    book_format: str,
    source_filename: str | None = None,
) -> Path | None:
    """Safely locate the original source file (`source/book.pdf` or `source/book.epub`)."""
    fmt = (book_format or "").strip().lower()
    if fmt not in ("pdf", "epub"):
        return None
    source_dir = (book_dir / "source").resolve()
    if not source_dir.is_dir():
        return None

    candidates: list[str] = []
    if source_filename:
        cleaned = Path(source_filename).name
        if cleaned and cleaned not in (".", "..") and "/" not in cleaned and "\\" not in cleaned:
            candidates.append(cleaned)
    candidates.append(f"book.{fmt}")

    for name in candidates:
        candidate = (source_dir / name).resolve()
        if candidate.parent == source_dir and candidate.is_file():
            return candidate

    # Fallback: first matching extension directly inside source/
    for item in sorted(source_dir.iterdir()):
        if item.is_file() and item.suffix.lower() == f".{fmt}":
            resolved = item.resolve()
            if resolved.parent == source_dir:
                return resolved
    return None


def _humanize_stem(filename: str) -> str:
    stem = Path(filename or "Untitled").stem
    cleaned = re.sub(r"[_\-]+", " ", stem).strip()
    return cleaned or "Untitled"


def _is_generic_pdf_title(title: str) -> bool:
    low = title.strip().lower()
    if not low or len(low) <= 1:
        return True
    if low in ("untitled", "document", "microsoft word", "presentation", "slide 1"):
        return True
    if low.startswith("microsoft word -") or low.endswith(".pdf") or low.endswith(".docx"):
        return True
    return False


def _fallback_pdf_page_count(pdf_path: Path) -> int:
    """Pure-Python fallback to estimate PDF page count when PyMuPDF is absent."""
    try:
        data = pdf_path.read_bytes()
        matches = re.findall(rb"/Type\s*/Page\b(?!s)", data)
        return max(1, len(matches))
    except Exception:
        return 1


def import_pdf_file(
    pdf_path: str | Path,
    dest_parent_dir: str | Path,
    *,
    original_filename: str = "book.pdf",
    explicit_slug: str | None = None,
) -> dict[str, Any]:
    """Import a raw `.pdf` file without splitting it into rigid HTML pages.

    Creates:
        dest_parent_dir/<slug>/
          ├── book.json
          ├── source/book.pdf
          └── output/assets/cover.png   (rendered from page 1 when PyMuPDF is available)
    """
    src_path = Path(pdf_path).expanduser().resolve()
    if not src_path.is_file():
        raise FileNotFoundError(f"PDF file not found: {src_path}")

    with src_path.open("rb") as fh:
        header = fh.read(1024)
    if b"%PDF-" not in header:
        raise ValueError("Invalid PDF file (missing %PDF- header).")

    slug = validate_book_slug(explicit_slug) if explicit_slug else slugify_filename(original_filename)
    parent_path = Path(dest_parent_dir).expanduser().resolve()
    parent_path.mkdir(parents=True, exist_ok=True)
    book_dir = (parent_path / slug).resolve()
    if book_dir.parent != parent_path:
        raise ValueError(f"Invalid book slug: {slug!r}")

    source_dir = book_dir / "source"
    assets_dir = book_dir / "output" / "assets"
    source_dir.mkdir(parents=True, exist_ok=True)
    assets_dir.mkdir(parents=True, exist_ok=True)

    dest_pdf = source_dir / "book.pdf"
    shutil.copy2(src_path, dest_pdf)

    title = _humanize_stem(original_filename)
    author = "Unknown"
    page_count = 1
    cover_rel = ""
    toc_entries: list[dict[str, Any]] = []

    try:
        import fitz  # PyMuPDF

        with fitz.open(dest_pdf) as doc:
            page_count = max(1, int(doc.page_count))
            meta = doc.metadata or {}
            pdf_title = str(meta.get("title") or "").strip()
            if pdf_title and not _is_generic_pdf_title(pdf_title):
                title = pdf_title
            pdf_author = str(meta.get("author") or "").strip()
            if pdf_author and pdf_author.lower() not in ("unknown", "none", "user", "admin"):
                author = pdf_author

            # Extract outline/TOC (capped for lightweight book.json)
            try:
                raw_toc = doc.get_toc(simple=True) or []
                for item in raw_toc[:1000]:
                    if len(item) >= 3:
                        toc_entries.append(
                            {
                                "level": int(item[0]),
                                "title": str(item[1]).strip(),
                                "page": max(1, int(item[2])),
                            }
                        )
            except Exception:
                toc_entries = []

            # Render crisp cover thumbnail from page 1
            if doc.page_count > 0:
                try:
                    page0 = doc.load_page(0)
                    rect = page0.rect
                    target_width = 560.0
                    scale = min(2.0, max(0.5, target_width / max(rect.width, 1.0)))
                    pix = page0.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
                    cover_dest = assets_dir / "cover.png"
                    pix.save(str(cover_dest))
                    if cover_dest.is_file() and cover_dest.stat().st_size > 0:
                        cover_rel = "assets/cover.png"
                except Exception:
                    cover_rel = ""
    except ImportError:
        page_count = _fallback_pdf_page_count(dest_pdf)
    except Exception as exc:
        raise ValueError(f"Unable to read PDF document: {exc}") from exc

    # Preserve existing custom appearance defaults if re-uploading over an existing slug
    existing_meta: dict[str, Any] = {}
    book_json_path = book_dir / "book.json"
    if book_json_path.is_file():
        try:
            existing_meta = json.loads(book_json_path.read_text(encoding="utf-8"))
        except Exception:
            existing_meta = {}

    metadata: dict[str, Any] = {
        "slug": slug,
        "format": "pdf",
        "source_filename": "book.pdf",
        "title": title,
        "author": author,
        "page_count": page_count,
        "cover": cover_rel,
        "default_font": existing_meta.get("default_font") or "default",
        "default_theme": existing_meta.get("default_theme") or "default",
    }
    if toc_entries:
        metadata["toc"] = toc_entries

    book_json_path.write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    return {
        "ok": True,
        "slug": slug,
        "format": "pdf",
        "source_filename": "book.pdf",
        "title": title,
        "author": author,
        "page_count": page_count,
        "cover": cover_rel,
        "dest_dir": str(book_dir),
    }


def _strip_ns(tag: str) -> str:
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


def _resolve_zip_path(base_dir: str, href: str) -> str:
    cleaned = href.split("#", 1)[0].split("?", 1)[0]
    from urllib.parse import unquote

    cleaned = unquote(cleaned)
    joined = posixpath.normpath(posixpath.join(base_dir, cleaned)) if base_dir else posixpath.normpath(cleaned)
    return joined.lstrip("/")


def _cover_ext_from_media_type(media_type: str, href: str) -> str:
    mt = (media_type or "").lower()
    if "png" in mt or href.lower().endswith(".png"):
        return ".png"
    if "webp" in mt or href.lower().endswith(".webp"):
        return ".webp"
    if "gif" in mt or href.lower().endswith(".gif"):
        return ".gif"
    return ".jpg"


def import_epub_file(
    epub_path: str | Path,
    dest_parent_dir: str | Path,
    *,
    original_filename: str = "book.epub",
    explicit_slug: str | None = None,
) -> dict[str, Any]:
    """Import a raw `.epub` archive intact while extracting metadata and cover art.

    Pure Python stdlib (zipfile + ElementTree) — zero external dependencies.
    Creates:
        dest_parent_dir/<slug>/
          ├── book.json
          ├── source/book.epub
          └── output/assets/cover.<ext>  (extracted cover image when present)
    """
    src_path = Path(epub_path).expanduser().resolve()
    if not src_path.is_file():
        raise FileNotFoundError(f"EPUB file not found: {src_path}")

    if not zipfile.is_zipfile(src_path):
        raise ValueError("Invalid EPUB file (not a valid ZIP archive).")

    title = _humanize_stem(original_filename)
    author = "Unknown"
    language = "en"
    spine_count = 0
    estimated_pages = 1
    cover_bytes: bytes | None = None
    cover_ext = ".jpg"

    with zipfile.ZipFile(src_path, "r") as zf:
        names = set(zf.namelist())
        names_lower = {n.lower(): n for n in names}

        def _read_member(path_candidate: str) -> bytes | None:
            if path_candidate in names:
                return zf.read(path_candidate)
            matched = names_lower.get(path_candidate.lower())
            if matched:
                return zf.read(matched)
            return None

        container_xml = _read_member("META-INF/container.xml")
        if not container_xml:
            raise ValueError("Invalid EPUB archive (missing META-INF/container.xml).")

        opf_path = ""
        try:
            container_root = ET.fromstring(container_xml)
            for el in container_root.iter():
                if _strip_ns(el.tag) == "rootfile" and el.attrib.get("full-path"):
                    opf_path = el.attrib["full-path"].strip()
                    break
        except Exception as exc:
            raise ValueError(f"Failed to parse META-INF/container.xml: {exc}") from exc

        if not opf_path:
            raise ValueError("Invalid EPUB archive (no OPF rootfile path found).")

        opf_bytes = _read_member(opf_path)
        if not opf_bytes:
            raise ValueError(f"Invalid EPUB archive (missing OPF file '{opf_path}').")

        opf_dir = posixpath.dirname(opf_path)
        manifest_by_id: dict[str, dict[str, str]] = {}
        spine_ids: list[str] = []
        meta_cover_id = ""
        cover_item_id = ""

        try:
            opf_root = ET.fromstring(opf_bytes)
            for el in opf_root.iter():
                local = _strip_ns(el.tag)
                if local == "title" and el.text and el.text.strip():
                    if title == _humanize_stem(original_filename):
                        title = el.text.strip()
                elif local == "creator" and el.text and el.text.strip():
                    if author == "Unknown":
                        author = el.text.strip()
                elif local == "language" and el.text and el.text.strip():
                    language = el.text.strip()
                elif local == "meta":
                    if el.attrib.get("name", "").lower() == "cover" and el.attrib.get("content"):
                        meta_cover_id = el.attrib["content"].strip()
                elif local == "item":
                    item_id = el.attrib.get("id", "").strip()
                    href = el.attrib.get("href", "").strip()
                    media_type = el.attrib.get("media-type", "").strip()
                    props = el.attrib.get("properties", "").strip()
                    if item_id and href:
                        manifest_by_id[item_id] = {
                            "href": href,
                            "media_type": media_type,
                            "properties": props,
                        }
                        if "cover-image" in props.split():
                            cover_item_id = item_id
                elif local == "itemref":
                    idref = el.attrib.get("idref", "").strip()
                    if idref:
                        spine_ids.append(idref)
        except Exception as exc:
            raise ValueError(f"Failed to parse EPUB OPF metadata: {exc}") from exc

        spine_count = len(spine_ids)

        # Estimate virtual page count from spine HTML text length (~1800 chars/page)
        total_chars = 0
        tag_re = re.compile(r"<[^>]+>")
        for idref in spine_ids:
            item = manifest_by_id.get(idref)
            if not item:
                continue
            member_path = _resolve_zip_path(opf_dir, item["href"])
            raw_html = _read_member(member_path)
            if raw_html:
                try:
                    text_only = tag_re.sub(" ", raw_html.decode("utf-8", errors="ignore"))
                    total_chars += len(" ".join(text_only.split()))
                except Exception:
                    total_chars += len(raw_html) // 2

        estimated_pages = max(1, spine_count, round(total_chars / 1800) if total_chars > 0 else 1)

        # Locate cover image (EPUB 3 properties="cover-image" -> EPUB 2 <meta name="cover"> -> heuristic)
        cover_candidate: dict[str, str] | None = None
        if cover_item_id and cover_item_id in manifest_by_id:
            cover_candidate = manifest_by_id[cover_item_id]
        elif meta_cover_id and meta_cover_id in manifest_by_id:
            cover_candidate = manifest_by_id[meta_cover_id]
        else:
            for item_id, item in manifest_by_id.items():
                if item["media_type"].startswith("image/") and (
                    "cover" in item_id.lower() or "cover" in item["href"].lower()
                ):
                    cover_candidate = item
                    break

        if cover_candidate:
            if cover_candidate["media_type"].startswith("image/"):
                zip_cover = _resolve_zip_path(opf_dir, cover_candidate["href"])
                raw = _read_member(zip_cover)
                if raw:
                    cover_bytes = raw
                    cover_ext = _cover_ext_from_media_type(
                        cover_candidate["media_type"], cover_candidate["href"]
                    )
            elif "html" in cover_candidate["media_type"]:
                # Some EPUB 2 books point <meta name="cover"> at a cover XHTML page
                cover_html_path = _resolve_zip_path(opf_dir, cover_candidate["href"])
                cover_html = _read_member(cover_html_path)
                if cover_html:
                    m = re.search(
                        r'(?:src|href)\s*=\s*["\']([^"\']+\.(?:jpe?g|png|webp|gif))["\']',
                        cover_html.decode("utf-8", errors="ignore"),
                        re.IGNORECASE,
                    )
                    if m:
                        img_zip_path = _resolve_zip_path(posixpath.dirname(cover_html_path), m.group(1))
                        raw = _read_member(img_zip_path)
                        if raw:
                            cover_bytes = raw
                            cover_ext = _cover_ext_from_media_type("", m.group(1))

    slug = validate_book_slug(explicit_slug) if explicit_slug else slugify_filename(original_filename)
    parent_path = Path(dest_parent_dir).expanduser().resolve()
    parent_path.mkdir(parents=True, exist_ok=True)
    book_dir = (parent_path / slug).resolve()
    if book_dir.parent != parent_path:
        raise ValueError(f"Invalid book slug: {slug!r}")

    source_dir = book_dir / "source"
    assets_dir = book_dir / "output" / "assets"
    source_dir.mkdir(parents=True, exist_ok=True)
    assets_dir.mkdir(parents=True, exist_ok=True)

    dest_epub = source_dir / "book.epub"
    shutil.copy2(src_path, dest_epub)

    cover_rel = ""
    if cover_bytes:
        cover_dest = assets_dir / f"cover{cover_ext}"
        cover_dest.write_bytes(cover_bytes)
        cover_rel = f"assets/cover{cover_ext}"

    existing_meta: dict[str, Any] = {}
    book_json_path = book_dir / "book.json"
    if book_json_path.is_file():
        try:
            existing_meta = json.loads(book_json_path.read_text(encoding="utf-8"))
        except Exception:
            existing_meta = {}

    metadata: dict[str, Any] = {
        "slug": slug,
        "format": "epub",
        "source_filename": "book.epub",
        "title": title,
        "author": author,
        "language": language,
        "page_count": estimated_pages,
        "spine_count": spine_count,
        "cover": cover_rel,
        "default_font": existing_meta.get("default_font") or "default",
        "default_theme": existing_meta.get("default_theme") or "default",
    }

    book_json_path.write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    return {
        "ok": True,
        "slug": slug,
        "format": "epub",
        "source_filename": "book.epub",
        "title": title,
        "author": author,
        "page_count": estimated_pages,
        "spine_count": spine_count,
        "cover": cover_rel,
        "dest_dir": str(book_dir),
    }
