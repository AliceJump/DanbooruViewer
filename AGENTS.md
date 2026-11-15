# Frontend work

This is a Flutter/Dart application. Keep its Android and Web behavior compatible
with the Flutter version pinned in the workflows; the UI skill's newer SDK
examples do not require an SDK migration.

Use the installed **ui-ux-pro-max** skill for UI changes. The selected upstream
is [UI/UX Pro Max v2.15.0](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/releases/tag/v2.15.0),
commit `a38d04c3d5c298c851dbe5e6ee1965ee3de42cb5`, licensed under MIT. Locate the
installed skill by its `name: ui-ux-pro-max` frontmatter rather than a fixed
personal installation path. Its local search data and scripts are part of the
skill; a copied SKILL.md alone is incomplete.

Read [the project frontend decisions](docs/frontend-design.md) before applying
generic style recommendations. Use Flutter stack guidance and targeted UX
queries. Treat automatic design-system output as suggestions and verify that
the product matches a browsing tool before applying it.

Preserve the indexed completion service, bounded metadata cache, request
generation guards, favorites storage and media lifecycle. Reuse the shared
gallery/search components and semantic theme colors. Keep keyboard, touch,
large text and short-window behavior functional.

For substantive UI changes, run `flutter analyze --no-fatal-infos` and the
relevant widget regressions. Check both themes and small/large viewports. Build
completion assets with `python scripts/build_completion_index.py` before a fresh
Flutter checkout is tested or built. See RELEASE_GUIDE.md for publishing.
