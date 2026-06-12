from pathlib import Path
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
MKDOCS = ROOT / "mkdocs.yml"

STALE_TEXT = (
    "architecture/proposed-patterns.md",
    "proposed-patterns.md",
    "Proposed Patterns",
)


class MkdocsNavLoader(yaml.SafeLoader):
    pass


def construct_unknown(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    return None


MkdocsNavLoader.add_multi_constructor("", construct_unknown)


def iter_markdown_files():
    yield ROOT / "README.md"
    yield from sorted(DOCS.rglob("*.md"))


def collect_nav_pages(node):
    pages = set()
    if isinstance(node, str):
        if node.endswith(".md"):
            pages.add(node.replace("\\", "/"))
    elif isinstance(node, list):
        for item in node:
            pages.update(collect_nav_pages(item))
    elif isinstance(node, dict):
        for value in node.values():
            pages.update(collect_nav_pages(value))
    return pages


def main():
    errors = []

    mkdocs = yaml.load(MKDOCS.read_text(encoding="utf-8"), Loader=MkdocsNavLoader)
    nav_pages = collect_nav_pages(mkdocs.get("nav", []))
    docs_pages = {
        path.relative_to(DOCS).as_posix()
        for path in DOCS.rglob("*.md")
    }

    missing_from_nav = sorted(docs_pages - nav_pages)
    if missing_from_nav:
        errors.append("Docs pages missing from mkdocs nav:")
        errors.extend(f"  - {page}" for page in missing_from_nav)

    missing_files = sorted(page for page in nav_pages if not (DOCS / page).exists())
    if missing_files:
        errors.append("mkdocs nav entries missing files:")
        errors.extend(f"  - {page}" for page in missing_files)

    for path in iter_markdown_files():
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()

        if not lines or not lines[0].startswith("# "):
            errors.append(f"{rel}: first line must be a single H1 heading")

        h1_count = sum(1 for line in lines if line.startswith("# "))
        if h1_count != 1:
            errors.append(f"{rel}: expected exactly one H1 heading, found {h1_count}")

        for index, line in enumerate(lines, start=1):
            if line.rstrip() != line:
                errors.append(f"{rel}:{index}: trailing whitespace")
            if "\t" in line:
                errors.append(f"{rel}:{index}: tab character")

        for stale in STALE_TEXT:
            if stale in text:
                errors.append(f"{rel}: stale reference to {stale}")

    if errors:
        print("Documentation style validation failed:")
        print("\n".join(errors))
        return 1

    print("Documentation style validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
