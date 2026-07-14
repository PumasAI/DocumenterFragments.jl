# DocumenterFragments

Tooling for building a Documenter site as independent *fragments*. Each package
keeps its own slice of the documentation in its own repository, builds and checks
it on its own CI, and the fragment is later composed into a full site without
source changes.

## How a fragment is laid out

A fragment lives in a package's `docs/` directory:

```
MyPackage/
  Project.toml
  docs/
    fragment.toml      declarative metadata (see below)
    make.jl            one-liner calling build_fragment
    src/
      introduction.md
      docstrings.md     an @autodocs page over the package's modules
      assets/...        images and other page assets (travel with the pages)
```

`docs/make.jl` is just:

```julia
using DocumenterFragments: build_fragment
build_fragment(@__DIR__)
```

There is no `using MyPackage`; `build_fragment` loads the modules named in
`fragment.toml` and resolves docstring references against them (see "Module scope").

## fragment.toml

```toml
name = "Widgets"                          # section title in the main site and standalone sitename
modules = ["Widgets", "WidgetsCore"]      # drives @autodocs coverage / checkdocs
doctest_setup = "using Widgets, TestData" # applied via DocMeta.setdocmeta!

[[pages]]
title = "Introduction"
file = "introduction.md"

[[pages]]
title = "Functions"
  [[pages.children]]
  title = "Reading data"
  file = "functions/read.md"
```

The metadata is the single source of truth: `build_fragment` reads it for the
standalone build, and the main site build reads the same file to assemble its
navigation, union the module lists, and replay each fragment's doctest setup.

Placement in the larger site is deliberately absent: the mount path (e.g.
`/widgets/`) and anchor namespace prefix are assigned by the main site at
composition time. Each fragment normally gets its own mount, but several can share
one (see "Sharing a mount").

## Docstring coverage

A fragment owns its docstring page (an `@autodocs`/`@docs` page listed in
`fragment.toml`). `build_fragment` runs `makedocs` with the modules and a hard
`checkdocs` (it does not downgrade `missing_docs` to a warning), so a docstring
attached to a name in those modules that appears on no page fails the fragment's
own CI. At composition the page and its modules travel into the main site, so
coverage is re-checked there with no separately-maintained per-module page.

The check only bites when docstrings are placed selectively. `@autodocs` over a
whole module splices everything, so nothing is ever missing and the check passes
trivially; curated `@docs` blocks (or `@autodocs` with `Pages`/`Filter`) make it
fail when a new docstring is left unplaced. Choose the policy per fragment. The
level is the `checkdocs` keyword on `build_fragment` (`:all` default, or
`:exports`/`:public`/`:none`); match the `@autodocs` visibility (`Private`) to it.

## Module scope

A fragment's docstring references (`` [`make_widget`](@ref) ``) resolve against the
fragment's own modules, not against whatever else happens to be loaded. For each
fragment, the build loads the modules named in `fragment.toml`, creates a small
scope module that `using`s exactly those, and points Documenter's `CurrentModule`
at it (via an injected `@meta` block on each page). So:

- The fragment author writes no `using`; the metadata module list is the only
  place packages are named.
- Resolution is identical standalone and composed: a ref that only resolves
  because another package is co-loaded in the main site fails the fragment's own
  CI instead of silently binding to the wrong docstring.

## Composition into the main site

The main site's `make.jl` calls `integrate_fragments`, listing each fragment with the mount
path it assigns:

```julia
using DocumenterFragments: integrate_fragments

c = integrate_fragments(main_src, [
    (; dir = "…/Widgets.jl/docs", mount = "widgets"),
    (; dir = "…/Gadgets.jl/docs", mount = "gadgets"),
])

makedocs(;
    modules = c.modules,                                   # union of all fragments' modules
    pages = Any["Home"=>"index.md"; [f.pages for f in c.fragments]],
    source = main_src,
    plugins = [c.namespacing],                             # applies anchor namespacing
    # ...usual HTML options...
)
```

`integrate_fragments` copies each fragment's sources (pages and assets together) into
`main_src/<mount>/`, runs `DocMeta.setdocmeta!` for each fragment's modules, and
returns the unioned module list, a `fragments` vector carrying each fragment's
mount-prefixed page tree, and a `namespacing` plugin. The pages are returned per
fragment rather than pre-merged so the main site controls where each section sits
in its navigation. The main site then runs a single `makedocs`, so the whole site
shares one theme, one search index and one navigation tree.

The `namespacing` plugin must be passed in `plugins`; without it fragment pages
build un-namespaced and collide (see "Anchor namespacing").

`integrate_fragments` assigns each fragment a unique anchor namespace derived from
its `mount`, so the caller only chooses mounts. The namespace never appears in a
URL or in anything an author writes (`@ref` links are rewritten automatically), so
it is not a spec option.

### Sharing a mount

Several fragments can share one mount to produce flat, intermixed URLs (e.g.
`Widgets` and `WidgetsPlots` both under `/widgets/`, giving `/widgets/introduction`
and `/widgets/plots` side by side):

```julia
c = integrate_fragments(main_src, [
    (; dir = "…/Widgets.jl/docs", mount = "widgets"),
    (; dir = "…/WidgetsPlots.jl/docs", mount = "widgets"),
])
```

Each fragment's sources are merged into the shared `main_src/<mount>/`, and its
module scope and anchor namespace are applied to its own pages only. So docstring
references resolve against the fragment that authored them, and each fragment keeps
its own namespace even though the pages sit side by side: a `## Examples` heading in
one does not collide with a `## Examples` in the other. The integrator makes the
per-fragment namespaces unique automatically (fragments sharing a mount cannot each
derive a unique namespace from it), so this needs no coordination.

The one real constraint is that file paths must not collide: the fragments' page
and asset paths (relative to each `src/`) are merged into one directory, so two
fragments both shipping `docstrings.md` is an error. `integrate_fragments` reports
the offending path and the fragment that introduced it; rename the file in one of
them.

### Rerouting pages

The main site can relocate individual fragment pages in its navigation. List a
page's fragment-relative path in the spec's `detach`, and `integrate_fragments` omits it from
that fragment's page tree and returns it under `f.detached`, keyed by that path:

```julia
c = integrate_fragments(main_src, [
    (; dir = "…/Widgets.jl/docs", mount = "widgets", detach = ["docstrings.md"]),
    (; dir = "…/Gadgets.jl/docs", mount = "gadgets", detach = ["docstrings.md"]),
])

pages = Any[
    "Home"=>"index.md",
    (f.pages for f in c.fragments)...,          # fragment sections, minus their detached pages
    "Docstring Index"=>Any[                      # gathered wherever the main site wants them
        f.name => f.detached["docstrings.md"].second for f in c.fragments
    ],
]
```

`f.detached["docstrings.md"]` is a `title => mounted-path` pair (the title the
fragment gave it, e.g. `"API" => "widgets/docstrings.md"`); reuse the title or
supply your own. Only the navigation position changes: the page still lives under
the fragment's mount, so its namespace, module scope and assets are unaffected.

`integrate_fragments` builds each fragment's module scope at runtime (see "Module scope"),
which advances the method world age. Call `makedocs` as a top-level statement in
`make.jl`, as above, so it runs in the new world and sees those scopes. If you wrap
the build in a function, call it as `Base.invokelatest(makedocs; ...)`.

Two invariants the integrator enforces:

- Each module is owned by exactly one fragment. `integrate_fragments` errors if two fragments
  declare the same module, since `DocMeta.setdocmeta!` is last-writer-wins and
  Documenter rejects a docstring spliced from two places. (Name-level check;
  overlapping submodule trees via `recursive = true` are backstopped by
  Documenter's own duplicate-docstring error.)
- The main site's docs environment is a superset of every fragment's: a
  fragment's `doctest_setup` must load in both its own `docs/Project.toml` and the
  main site's docs env, so a new `doctest_setup` dependency is also a main-site
  env change.

Because everything moves as one subtree and Documenter recomputes its own internal
links (inter-page links, `@ref`, inserted images) for each build, those survive the
move under `/<mount>/` with no rewriting. Manually written relative links (e.g. a
raw `<img src="../assets/x.png">`) are not recomputed and can break on integration
if the main site's `prettyurls` differs from the standalone build they were authored
against. `build_fragment` takes a `prettyurls` keyword (default `true`); whichever
value a fragment builds with, the main site's `makedocs` should use the same.

## Anchor namespacing and cross-package links

Documenter resolves section references across the whole doc set, so two fragments
that both define a `## Examples` section would collide once composed. The
`namespacing` plugin from `integrate_fragments` registers a build stage (a
`Documenter.Builder.DocumentPipeline` stage, ordered before cross-reference
resolution) that walks each fragment page's parsed `MarkdownAST` and, for that
fragment's assigned namespace, rewrites headings to carry an explicit `@id`
prefixed with the namespace (`widgets-...`) and prefixes matching section
`@ref`/`@id` link targets. It operates on the typed `MarkdownAST` Documenter
already built, not on the Markdown text, so code blocks, spans, and docstring refs
are recognized by node type and left untouched, with no parsing round-trip. This
is the same extension mechanism DocumenterInterLinks uses to resolve `@extref`
links.

Namespacing is a placement concern, so it happens only at composition. A
standalone fragment build is un-namespaced: it builds like an ordinary small
Documenter site, with clean anchors (`#Examples`). This loses nothing, because a
single fragment's CI catches exactly the same content errors either way:

- broken intra-fragment links, missing docstrings, failing doctests and duplicate
  headers within the fragment all fail the standalone build.
- a link to a section owned by another package (a main site often does this
  freely, e.g. one package linking to a Plots section) fails the standalone build
  too, because the target id simply does not exist in the fragment.
- a namespace collision between two fragments is invisible to any single fragment
  by definition, so it is checked only at composition.

So the split is: the fragment CI validates content; the main site assigns
placement (mounts, and a unique namespace per fragment) and validates
cross-fragment policy. In v1 this is intentional: fragments stay decoupled and do
not coordinate anchor names.

Future extension (not implemented): cross-fragment links via DocumenterInterLinks.
Documenter writes an `objects.inv` inventory per build, and DocumenterInterLinks
can load another fragment's inventory (including from a committed local `.toml`)
and resolve `[text](@extref widgets-...)` links against it. The per-fragment
namespacing already makes every anchor globally unique, so this can be added
without redesign.

## Warnings

Builds are configured to be quiet and strict, so a warning in CI is a real signal
rather than expected noise. `build_fragment` keeps `warnonly` empty (so Documenter
checks like `missing_docs` and `cross_references` are hard errors, see "Docstring
coverage"), sets `repolink = nothing` to drop the navbar repo-link warning under
`remotes = nothing`, and synthesizes a minimal `index.md` landing page for the
standalone build when a fragment has none. Run CI with `--depwarn=error` to also
make deprecations fatal.

`DocMeta.setdocmeta!` is left to warn on overwrite (it warns on any re-set, not
just a changed value). The warning is kept on because its meaningful case is two
fragments putting a different doctest setup on the same module, or a shared
submodule via `recursive`. The cost is that a second build in the same process
(an iterative rebuild) also warns; clear `DocTestSetup` between builds if that
matters.
