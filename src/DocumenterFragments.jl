module DocumenterFragments

import TOML
import Documenter
import MarkdownAST
using Documenter: makedocs, DocMeta

@static if VERSION >= v"1.11" # `public` keyword needs 1.11; eval keeps 1.10 parseable
    eval(Expr(:public, :build_fragment, :integrate_fragments))
end

struct FragmentMeta
    name::String
    modules::Vector{String}
    doctest_setup::Union{Nothing, String}
    bibliography::Union{Nothing, String}
    page_entries::Vector{Any}
    dir::String
end

function read_fragment(dir::AbstractString)
    toml = TOML.parsefile(joinpath(dir, "fragment.toml"))
    name = toml["name"]
    modules = collect(String, get(toml, "modules", String[]))
    setup = get(toml, "doctest_setup", nothing)
    bib = get(toml, "bibliography", nothing)
    bibfile = bib === nothing ? nothing : joinpath(dir, bib)
    entries = collect(Any, get(toml, "pages", Any[]))
    return FragmentMeta(name, modules, setup, bibfile, entries, String(dir))
end

function slugify(s)
    s = strip(String(s))
    s = replace(s, r"\s+" => "-")
    s = replace(s, r"[^0-9A-Za-z_\-]" => "")
    return s
end

documenter_pages(meta::FragmentMeta; prefix::AbstractString = "") =
    parse_pages(meta.page_entries; prefix)

function parse_pages(entries; prefix::AbstractString = "")
    return Any[parse_page(e; prefix) for e in entries]
end

function parse_page(e; prefix::AbstractString)
    title = e["title"]
    return if haskey(e, "children")
        title => parse_pages(e["children"]; prefix)
    else
        file = e["file"]
        title => (isempty(prefix) ? file : joinpath(prefix, file))
    end
end

function inline_text(node)
    io = IOBuffer()
    collect_inline_text!(io, node)
    return String(take!(io))
end

function collect_inline_text!(io, node)
    el = node.element
    el isa MarkdownAST.Text ? print(io, el.text) :
        el isa MarkdownAST.Code ? print(io, el.code) : nothing
    for c in node.children
        collect_inline_text!(io, c)
    end
    return
end

function namespace_heading!(node, prefix)
    kids = collect(node.children)
    return if length(kids) == 1 &&
            kids[1].element isa MarkdownAST.Link &&
            startswith(kids[1].element.destination, "@id ")
        id = strip(chopprefix(kids[1].element.destination, "@id "))
        kids[1].element.destination = "@id $prefix-$id"
    else
        slug = Documenter.slugify(inline_text(node))
        link = MarkdownAST.Node(MarkdownAST.Link("@id $prefix-$slug", ""))
        for k in kids
            push!(link.children, k)
        end
        push!(node.children, link)
    end
end

is_docstring_ref(node) =
    length(node.children) == 1 && first(node.children).element isa MarkdownAST.Code

function namespace_ref!(node, prefix)
    el = node.element
    startswith(el.destination, "@ref") || return
    is_docstring_ref(node) && return
    rest = strip(chopprefix(el.destination, "@ref"))
    key =
        isempty(rest) ? Documenter.slugify(inline_text(node)) :
        startswith(rest, '"') ? Documenter.slugify(strip(rest, '"')) : rest
    return el.destination = "@ref $prefix-$key"
end

function namespace_ast!(node, prefix)
    el = node.element
    if el isa MarkdownAST.Heading
        namespace_heading!(node, prefix)
        return
    elseif el isa MarkdownAST.Link
        namespace_ref!(node, prefix)
    end
    for c in node.children
        namespace_ast!(c, prefix)
    end
    return
end

# The same gate DocumenterCitations' `CollectCitations` uses to recognize a
# citation link.
is_citation(el) =
    el isa MarkdownAST.Link && startswith(lowercase(el.destination), "@cite")

# A `@bibliography` block body mixes `Field = value` settings with explicit
# citation keys. Both are classified with the parser DocumenterCitations itself
# uses, so that a multi-line field value is not mistaken for a list of keys. Two
# things change for a composed site, neither of which the fragment can decide for
# itself: `*` means "every entry of my bibliography", which after merging would
# reach across fragments, and an unscoped block means "everything cited in this
# site", which likewise now spans fragments, so it is scoped to the fragment's
# own pages.
function scope_bibliography_block!(node, ctx)
    fields = String[]
    entries = String[]
    scoped = false
    for (ex, str) in Documenter.parseblock(node.element.code, nothing, nothing; raise = false)
        entry = String(strip(str))
        if Documenter.isassign(ex)
            ex.args[1] === :Pages && (scoped = true)
            push!(fields, entry)
        elseif entry == "*"
            append!(entries, ctx.bib_keys)
        else
            push!(entries, entry)
        end
    end
    scoped || push!(fields, "Pages = [$(join(map(repr, ctx.pages), ", "))]")
    return node.element.code = join([fields; entries], '\n') * '\n'
end

is_bibliography_block(el) =
    el isa MarkdownAST.CodeBlock && occursin(r"^@bibliography", el.info)

function has_canonical_block(node)
    is_bibliography_block(node.element) && return is_canonical(node.element.code)
    return any(has_canonical_block, node.children)
end

function prepare_citations!(node, ctx)
    el = node.element
    if is_citation(el)
        ctx.citations[] += 1
        return
    elseif is_bibliography_block(el)
        scope_bibliography_block!(node, ctx)
        return
    elseif el isa Documenter.DocsNode
        # Docstring ASTs hang off the element, not off the page tree.
        for mdast in el.mdasts
            prepare_citations!(mdast, ctx)
        end
    end
    for c in node.children
        prepare_citations!(c, ctx)
    end
    return
end

struct FragmentNamespaces <: Documenter.Plugin
    page_slugs::Vector{Pair{String, String}}
    bibliography_keys::Dict{String, Vector{String}}
end
FragmentNamespaces(page_slugs = Pair{String, String}[]) =
    FragmentNamespaces(page_slugs, Dict{String, Vector{String}}())

strip_ext(path) = splitext(replace(String(path), '\\' => '/'))[1]

function namespace_for(path, page_slugs)
    key = strip_ext(path)
    for (page, ns) in page_slugs
        strip_ext(page) == key && return ns
    end
    return nothing
end

abstract type FragmentNamespacing <: Documenter.Builder.DocumentPipeline end
Documenter.Selectors.order(::Type{FragmentNamespacing}) = 1.5
function Documenter.Selectors.runner(::Type{FragmentNamespacing}, doc)
    haskey(doc.plugins, FragmentNamespaces) || return
    page_slugs = Documenter.getplugin(doc, FragmentNamespaces).page_slugs
    isempty(page_slugs) && return
    for (path, page) in doc.blueprint.pages
        ns = namespace_for(path, page_slugs)
        ns === nothing && continue
        for child in collect(page.mdast.children)
            namespace_ast!(child, ns)
        end
    end
    return
end

# Runs after ExpandTemplates (2.0), so that citations spliced in from docstrings
# are seen too, and before DocumenterCitations' CollectCitations (2.11).
abstract type FragmentCitations <: Documenter.Builder.DocumentPipeline end
Documenter.Selectors.order(::Type{FragmentCitations}) = 2.05
function Documenter.Selectors.runner(::Type{FragmentCitations}, doc)
    haskey(doc.plugins, FragmentNamespaces) || return
    namespaces = Documenter.getplugin(doc, FragmentNamespaces)
    isempty(namespaces.page_slugs) && return
    citations = Ref(0)
    main_canonical = false
    for (path, page) in doc.blueprint.pages
        ns = namespace_for(path, namespaces.page_slugs)
        if ns === nothing
            main_canonical |= has_canonical_block(page.mdast)
            continue
        end
        ctx = (;
            bib_keys = get(namespaces.bibliography_keys, ns, String[]),
            pages = sibling_pages(path, ns, namespaces.page_slugs),
            citations,
        )
        for child in collect(page.mdast.children)
            prepare_citations!(child, ctx)
        end
    end
    citations[] > 0 && !main_canonical && error(
        "Fragment pages carry citations, but no canonical `@bibliography` block was found " *
            "outside the fragments. A fragment's own blocks may not be canonical, so the " *
            "main site must hold the bibliography: add an unscoped ```@bibliography``` " *
            "block to one of its pages.",
    )
    return
end

# The fragment's own pages, relative to the page holding the block, which is how
# a `@bibliography` block's `Pages` are resolved.
function sibling_pages(path, ns, page_slugs)
    here = dirname(replace(String(path), '\\' => '/'))
    isempty(here) && (here = ".")
    return [relpath(page, here) for (page, slug) in page_slugs if slug == ns]
end

function load_module(name, module_map)
    haskey(module_map, name) && return module_map[name]
    sym = Symbol(name)
    return isdefined(Main, sym) ? getfield(Main, sym) : Base.require(Main, sym)
end

resolve_modules(meta::FragmentMeta, module_map) =
    Module[load_module(n, module_map) for n in meta.modules]

scope_identifier(key) =
    Symbol("DocumenterFragmentScope_" * replace(String(key), r"[^0-9A-Za-z_]" => "_"))

function make_scope(mods, key)
    name = scope_identifier(key)
    scope = Module(name)
    for mod in mods
        Core.eval(scope, Expr(:using, Expr(:., fullname(mod)...)))
    end
    Core.eval(Main, :($name = $scope))
    return name
end

function meta_block(scopename; page_meta = ())
    lines = ["CurrentModule = $(scopename)"]
    for (k, v) in page_meta
        push!(lines, "$k = $v")
    end
    return "```@meta\n" * join(lines, "\n") * "\n```\n\n"
end

prepend_block!(path, block) = write(path, block * read(path, String))

function markdown_files(srcdir)
    found = String[]
    for (root, _, files) in walkdir(srcdir)
        for f in files
            endswith(f, ".md") && push!(found, joinpath(root, f))
        end
    end
    return found
end

function set_currentmodule!(srcdir, scopename; page_meta = ())
    block = meta_block(scopename; page_meta)
    for path in markdown_files(srcdir)
        prepend_block!(path, block)
    end
    return
end

function apply_doctestsetup!(meta::FragmentMeta, mods)
    meta.doctest_setup === nothing && return
    expr = Meta.parse(meta.doctest_setup)
    for m in mods
        DocMeta.setdocmeta!(m, :DocTestSetup, expr; recursive = true)
    end
    return
end

function package_version(dir)
    project = joinpath(dirname(dir), "Project.toml")
    isfile(project) || return ""
    return get(TOML.parsefile(project), "version", "")
end

# Bibliographies are handled in the DocumenterCitations extension, so that a
# fragment that does not cite anything neither loads that package nor triggers
# its "No `bibfile`" warning. These fallbacks take varargs, so the extension's
# methods are the more specific ones and win wherever it is loaded.
citations_unavailable() = error(
    "A fragment declares a `bibliography` in its `fragment.toml`, which requires " *
        "DocumenterCitations. Add `import DocumenterCitations` to `make.jl`.",
)

with_bibliography(::Vararg{Any}) = citations_unavailable()
read_entries(::Vararg{Any}) = citations_unavailable()
merge_citations(::Vararg{Any}) = citations_unavailable()

function fragment_plugins(meta::FragmentMeta, plugins)
    meta.bibliography === nothing && return plugins
    return with_bibliography(plugins, meta.bibliography)
end

# Obscure enough that a fragment can still have a page of its own called
# "references.md"; it only ever exists in the standalone build.
const REFERENCES_PAGE = "documenterfragments_references.md"
const BIBLIOGRAPHY_FENCE = r"^`{3,}@bibliography[^\n]*\n(.*?)^`{3,}"ms

function is_canonical(body)
    for (ex, _) in Documenter.parseblock(body, nothing, nothing; raise = false)
        Documenter.isassign(ex) && ex.args[1] === :Canonical &&
            return Core.eval(Main, ex.args[2]) == true
    end
    return true
end

bibliography_bodies(md) = (m[1] for m in eachmatch(BIBLIOGRAPHY_FENCE, md))

# A canonical block defines the anchors its entries are cited by, and a key can
# only be anchored once, so a fragment claiming them would take them from the
# composed site's own bibliography. Placement decides who is canonical, and the
# main site always wins, which the fragment's own build can already tell it.
function validate_bibliography_blocks(meta::FragmentMeta)
    for path in markdown_files(joinpath(meta.dir, "src"))
        any(is_canonical, bibliography_bodies(read(path, String))) && error(
            "Fragment \"$(meta.name)\" has a canonical `@bibliography` block in " *
                "\"$(relpath(path, meta.dir))\". A fragment cannot own the canonical " *
                "bibliography of the site it is composed into, which holds the anchors its " *
                "citations link to; add `Canonical = false` to the block. The standalone " *
                "build gets a generated \"$REFERENCES_PAGE\" page to resolve its citations.",
        )
    end
    return
end

references_placeholder() = """
# References

This references page was generated by [DocumenterFragments.jl](https://github.com/PumasAI/DocumenterFragments.jl)
for the standalone fragment build only, so that the fragment's citations resolve
and are checked here. Once the fragment is integrated it is not present, and the
full site is expected to carry the canonical bibliography itself.

```@bibliography
Pages = []
*
```
"""

# The fragment's citations need a canonical bibliography to point at, and the
# fragment is not allowed to be it, so its own build gets this stand-in, the same
# way it gets a home page.
function add_references_page!(pages, srcdir, name)
    path = joinpath(srcdir, REFERENCES_PAGE)
    isfile(path) && error(
        "Fragment \"$name\" declares a bibliography, so the standalone build needs to " *
            "generate \"$REFERENCES_PAGE\", but the fragment already ships that page. " *
            "Rename it.",
    )
    write(path, references_placeholder())
    return push!(pages, "References" => REFERENCES_PAGE)
end

"""
    build_fragment(dir; kwargs...) -> build_dir

Build the documentation fragment at `dir` into a standalone Documenter site and
return the output directory.

The fragment's `fragment.toml` supplies its name, the modules to document
(loaded automatically, so `make.jl` needs no `using`), an optional
`doctest_setup`, an optional `bibliography` file, and the page tree. Keyword
arguments mirror the relevant `Documenter.makedocs`/`Documenter.HTML` options
(`doctest`, `warnonly`, `checkdocs`, `prettyurls`, `plugins`, `page_meta`, ...);
any extra keywords are forwarded to `makedocs`.

A declared `bibliography` is turned into a `CitationBibliography` plugin unless
`plugins` already carries one. A generated `References` page is appended so that
the fragment's citations resolve in the standalone build; any `@bibliography`
blocks the fragment carries itself must be `Canonical = false`, since the
composed site owns the canonical bibliography.
"""
function build_fragment(
        dir::AbstractString;
        build = joinpath(dir, "build"),
        module_map = Dict{String, Module}(),
        doctest::Bool = true,
        warnonly = Symbol[],
        checkdocs::Symbol = :all,
        prettyurls::Bool = true,
        repolink = nothing,
        inventory_version = package_version(dir),
        page_meta = (),
        plugins = Documenter.Plugin[],
        kwargs...,
    )
    meta = read_fragment(dir)
    meta.bibliography === nothing || validate_bibliography_blocks(meta)
    mods = resolve_modules(meta, module_map)
    apply_doctestsetup!(meta, mods)
    scopename = make_scope(mods, meta.name)

    staged = mktempdir()
    staged_src = joinpath(staged, "src")
    cp(joinpath(dir, "src"), staged_src)

    pages = documenter_pages(meta)
    if !isfile(joinpath(staged_src, "index.md"))
        placeholder = """
        # $(meta.name)

        This home page was generated by [DocumenterFragments.jl](https://github.com/PumasAI/DocumenterFragments.jl)
        for the standalone fragment build only, and will not be present once the
        fragment is integrated into the full site.
        """
        write(joinpath(staged_src, "index.md"), placeholder)
        pushfirst!(pages, "Home" => "index.md")
    end
    meta.bibliography === nothing || add_references_page!(pages, staged_src, meta.name)
    set_currentmodule!(staged_src, scopename; page_meta)

    # invokelatest: make_scope bound the scope module into Main during this call, so
    # makedocs must run in the latest world age to resolve `CurrentModule = $scopename`.
    Base.invokelatest(
        makedocs;
        sitename = meta.name,
        modules = mods,
        pages,
        source = staged_src,
        build,
        doctest,
        warnonly,
        checkdocs,
        plugins = fragment_plugins(meta, plugins),
        remotes = nothing,
        format = Documenter.HTML(; prettyurls, edit_link = nothing, repolink, inventory_version),
        kwargs...,
    )
    return build
end

default_namespace(mount) = slugify(replace(String(mount), '/' => '-'))

function merge_fragment_src!(src, dest, mount, fragname)
    copied = String[]
    for (root, _, files) in walkdir(src)
        for f in files
            rel = normpath(joinpath(relpath(root, src), f))
            target = joinpath(dest, rel)
            isfile(target) && error(
                "Fragment \"$fragname\" mounted at \"$mount\" contributes file \"$rel\", " *
                    "but that path already exists under the mount (from another fragment " *
                    "sharing this mount, or the main site). Fragments sharing a mount must " *
                    "not have colliding file paths; rename the file in one of them.",
            )
            mkpath(dirname(target))
            cp(joinpath(root, f), target)
            push!(copied, rel)
        end
    end
    return copied
end

function prepare_fragment!(
        main_src::AbstractString,
        dir::AbstractString,
        mount::AbstractString;
        slug::AbstractString = default_namespace(mount),
        module_map = Dict{String, Module}(),
        page_meta = (),
    )
    meta = read_fragment(dir)
    meta.bibliography === nothing || validate_bibliography_blocks(meta)
    mods = resolve_modules(meta, module_map)
    apply_doctestsetup!(meta, mods)
    scopename = make_scope(mods, slug)

    dest = joinpath(main_src, mount)
    copied = merge_fragment_src!(joinpath(dir, "src"), dest, mount, meta.name)

    block = meta_block(scopename; page_meta)
    for rel in copied
        endswith(rel, ".md") || continue
        prepend_block!(joinpath(dest, rel), block)
    end

    return (
        pages = meta.name => documenter_pages(meta; prefix = mount),
        page_paths = [replace(joinpath(mount, rel), '\\' => '/') for rel in copied if endswith(rel, ".md")],
        modules = mods,
        meta = meta,
    )
end

function validate_module_ownership(specs)
    owner = Dict{String, String}()
    for spec in specs
        for m in read_fragment(spec.dir).modules
            haskey(owner, m) && error(
                "Module \"$m\" is claimed by both fragment \"$(owner[m])\" and " *
                    "fragment \"$(spec.mount)\"; each module must be owned by exactly one fragment.",
            )
            owner[m] = spec.mount
        end
    end
    return
end

function split_tree(tree, detach)
    kept = Any[]
    detached = Pair{String, String}[]
    for entry in tree
        title, val = entry.first, entry.second
        if val isa AbstractString
            push!(val in detach ? detached : kept, title => val)
        else
            subkept, subdetached = split_tree(val, detach)
            append!(detached, subdetached)
            isempty(subkept) || push!(kept, title => subkept)
        end
    end
    return kept, detached
end

struct IntegratedFragment
    name::String
    mount::String
    slug::String
    pages::Pair{String, Vector{Any}}
    detached::Dict{String, Pair{String, String}}
    modules::Vector{Module}
end

struct Integration
    fragments::Vector{IntegratedFragment}
    modules::Vector{Module}
    namespacing::FragmentNamespaces
    citations::Union{Nothing, Documenter.Plugin}
    plugins::Vector{Documenter.Plugin}
end

function Integration(fragments, modules, namespacing, citations)
    plugins = Documenter.Plugin[namespacing]
    citations === nothing || push!(plugins, citations)
    return Integration(fragments, modules, namespacing, citations, plugins)
end

function disambiguate!(taken, base)
    key = base
    n = 1
    while key in taken
        n += 1
        key = "$(base)_$n"
    end
    push!(taken, key)
    return key
end

"""
    integrate_fragments(main_src, specs; module_map = Dict{String,Module}()) -> Integration

Integrate several fragments into a main site's source tree rooted at `main_src`.

Each spec names a fragment `dir` and the `mount` path to place it under (plus
optional `page_meta` and `detach`). For every fragment the sources are copied
under its mount, its module scope and doctest setup are established, a unique
anchor namespace is assigned, and any pages listed in `detach` are pulled out for
the integrator to reroute. Each module must be owned by exactly one fragment.
Several fragments may share a mount, provided their file paths do not collide.

Fragments declaring a `bibliography` have their entries merged into one
`CitationBibliography`, keeping their citation keys as written. A key supplied by
more than one fragment must carry the same entry everywhere, or the merge errors.
Pass an existing plugin as `citations` to contribute the main site's own
bibliography and its style.

Returns an [`Integration`](@ref) whose `fragments` are [`IntegratedFragment`](@ref)s
(each carrying `pages`, `detached`, `modules`, ...), the combined `modules`, and the
`plugins` to pass to `makedocs` so anchors, cross-references and citations stay
unique across fragments.
"""
function integrate_fragments(
        main_src::AbstractString,
        specs;
        module_map = Dict{String, Module}(),
        citations = nothing,
    )
    validate_module_ownership(specs)
    page_slugs = Pair{String, String}[]
    bibliography_keys = Dict{String, Vector{String}}()
    contributions = Tuple{String, Any}[]
    slugs_taken = Set{String}()
    fragments = map(specs) do spec
        slug = disambiguate!(slugs_taken, default_namespace(spec.mount))
        page_meta = hasproperty(spec, :page_meta) ? spec.page_meta : ()
        prep = prepare_fragment!(main_src, spec.dir, spec.mount; slug, module_map, page_meta)
        for path in prep.page_paths
            push!(page_slugs, path => slug)
        end
        if prep.meta.bibliography !== nothing
            entries = read_entries(prep.meta.bibliography)
            push!(contributions, ("fragment \"$(prep.meta.name)\"", entries))
            bibliography_keys[slug] = collect(keys(entries))
        end

        detach = hasproperty(spec, :detach) ?
            Set(joinpath(spec.mount, f) for f in spec.detach) : Set{String}()
        kept, detached = split_tree(prep.pages.second, detach)
        detached_pages = Dict{String, Pair{String, String}}(
            chopprefix(path, spec.mount * "/") => (title => path) for (title, path) in detached
        )

        IntegratedFragment(
            prep.pages.first,
            spec.mount,
            slug,
            prep.pages.first => kept,
            detached_pages,
            prep.modules,
        )
    end
    modules = unique(reduce(vcat, (f.modules for f in fragments); init = Module[]))
    return Integration(
        fragments,
        modules,
        FragmentNamespaces(page_slugs, bibliography_keys),
        isempty(contributions) ? citations : merge_citations(citations, contributions),
    )
end

end
