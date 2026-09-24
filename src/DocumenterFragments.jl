module DocumenterFragments

import TOML
import Documenter
import Markdown
import MarkdownAST
using Documenter: makedocs, DocMeta

@static if VERSION >= v"1.11" # `public` keyword needs 1.11; eval keeps 1.10 parseable
    eval(Expr(:public, :build_fragment, :integrate_fragments))
end

struct FragmentMeta
    name::String
    modules::Vector{String}
    composedref_modules::Vector{String}
    doctest_setup::Union{Nothing, String}
    doctest_teardown::Union{Nothing, String}
    bibliography::Union{Nothing, String}
    page_entries::Vector{Any}
    dir::String
end

function read_fragment(dir::AbstractString)
    toml = TOML.parsefile(joinpath(dir, "fragment.toml"))
    name = toml["name"]
    modules = collect(String, get(toml, "modules", String[]))
    composedref_modules = collect(String, get(toml, "composedref_modules", String[]))
    setup = get(toml, "doctest_setup", nothing)
    teardown = get(toml, "doctest_teardown", nothing)
    bib = get(toml, "bibliography", nothing)
    bibfile = bib === nothing ? nothing : joinpath(dir, bib)
    entries = collect(Any, get(toml, "pages", Any[]))
    return FragmentMeta(name, modules, composedref_modules, setup, teardown, bibfile, entries, String(dir))
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

struct FragmentComposedRefs <: Documenter.Plugin
    integrated::Bool
    modules::Dict{String, Vector{Module}}
end

const STANDALONE_COMPOSEDREFS = ""

is_composedref(el) =
    el isa MarkdownAST.Link && occursin(r"^@composedref(\s|$)", el.destination)

function composedref_target(node, where)
    rest = strip(chopprefix(node.element.destination, "@composedref"))
    isempty(rest) || return String(rest)
    is_docstring_ref(node) && return first(node.children).element.code
    error(
        "The `@composedref` link \"$(inline_text(node))\" $where has no target. " *
            "Use code text ([`Widgets.make_widget`](@composedref)) or an explicit name " *
            "([the widget builder](@composedref Widgets.make_widget)).",
    )
end

function composedref_binding(target, mods, where)
    parts = Symbol.(split(target, '.'))
    length(parts) >= 2 || error(
        "`@composedref` target \"$target\" $where must be qualified with the module " *
            "supplying it, e.g. \"Widgets.make_widget\".",
    )
    i = findfirst(m -> nameof(m) === parts[1], mods)
    i === nothing && error(
        "`@composedref` target \"$target\" $where points into module \"$(parts[1])\", " *
            "but the fragment declares " *
            (
            isempty(mods) ? "no `composedref_modules`" :
                "only $(join(("\"$(nameof(m))\"" for m in mods), ", ")) as `composedref_modules`"
        ) *
            "; declare the module in fragment.toml.",
    )
    mod = mods[i]
    for p in parts[2:(end - 1)]
        isdefined(mod, p) && getfield(mod, p) isa Module || error(
            "`@composedref` target \"$target\" $where: \"$p\" is not a submodule of \"$mod\".",
        )
        mod = getfield(mod, p)
    end
    sym = parts[end]
    # aliasof: a target written through a reexport or const alias must yield the
    # canonical binding, so it dedupes with (and anchors identically to) the
    # directly-written form.
    binding = Documenter.DocSystem.aliasof(Documenter.DocSystem.binding(mod, sym))
    isempty(Documenter.DocSystem.getdocs(binding)) && error(
        "`@composedref` target \"$target\" $where: `$sym` " *
            (isdefined(mod, sym) ? "has no docstring" : "is not defined") *
            " in module \"$mod\".",
    )
    return binding
end

# Both builds hold a page with the target docstring (composed, the page of the
# fragment owning the module; standalone, the generated page of docstrings
# available at composition), so a composedref is resolved into a link to its
# anchor there. The links
# are resolved here rather than left to Documenter's `@ref` machinery, since that
# resolves relative to a module scope (the page's `CurrentModule`, or for a
# docstring-embedded ref the docstring's module) in which the dependency is not
# necessarily a reachable name.
function resolve_composedref!(node, ctx)
    target = composedref_target(node, ctx.where)
    ctx.mods === nothing && error(
        "The `@composedref` link \"$target\" $(ctx.where) does not belong to a fragment, " *
            "so no `composedref_modules` apply. Composedref links can only be authored " *
            "within fragments; on a main-site page, use a plain docstring `@ref` instead.",
    )
    binding = composedref_binding(target, ctx.mods, ctx.where)
    object = Documenter.find_object(ctx.doc, binding, Union{})
    object === nothing && error(
        "`@composedref` target \"$target\" $(ctx.where) has a docstring, but it is " *
            (
            ctx.integrated ?
                "not included on any page of the composed site; whoever provides " *
                "\"$(binding.mod)\" (the fragment owning it, or the main site's own pages) " *
                "must place it on one of its docstring pages." :
                "missing from the generated \"$COMPOSEDREFS_PAGE\" page. This can happen " *
                "when the link only comes into existence during the build (e.g. produced " *
                "by an `@eval` block), which the pre-build scan cannot see; otherwise " *
                "please report a bug in DocumenterFragments."
        ),
    )
    docsnode = ctx.doc.internal.objects[object]
    pagekey = relpath(docsnode.page.build, ctx.doc.user.build)
    targetpage = ctx.doc.blueprint.pages[pagekey]
    node.element = Documenter.PageLink(targetpage, Documenter.slugify(object))
    return
end

function resolve_composedrefs!(node, ctx)
    el = node.element
    if is_composedref(el)
        resolve_composedref!(node, ctx)
        return
    elseif el isa Documenter.DocsNode
        inner = (; ctx..., where = "in a docstring included on page \"$(ctx.path)\"")
        for mdast in el.mdasts
            resolve_composedrefs!(mdast, inner)
        end
    end
    for c in collect(node.children)
        resolve_composedrefs!(c, ctx)
    end
    return
end

# Runs after ExpandTemplates (2.0), so composedrefs inside spliced docstrings are seen
# and the docstring objects to link to are registered, and before CrossReferences
# (3.0), which must never see a raw `@composedref`.
abstract type FragmentComposedRefResolution <: Documenter.Builder.DocumentPipeline end
Documenter.Selectors.order(::Type{FragmentComposedRefResolution}) = 2.5
function Documenter.Selectors.runner(::Type{FragmentComposedRefResolution}, doc)
    haskey(doc.plugins, FragmentComposedRefs) || return
    composedrefs = Documenter.getplugin(doc, FragmentComposedRefs)
    if !composedrefs.integrated && haskey(doc.blueprint.pages, COMPOSEDREFS_PAGE)
        page = doc.blueprint.pages[COMPOSEDREFS_PAGE]
        mods = get(composedrefs.modules, STANDALONE_COMPOSEDREFS, Module[])
        for child in collect(page.mdast.children)
            is_composedrefdocs(child.element) &&
                expand_composedrefdocs!(child, page, mods, doc)
        end
    end
    page_slugs = haskey(doc.plugins, FragmentNamespaces) ?
        Documenter.getplugin(doc, FragmentNamespaces).page_slugs : Pair{String, String}[]
    for (path, page) in doc.blueprint.pages
        ns = composedrefs.integrated ? namespace_for(path, page_slugs) : STANDALONE_COMPOSEDREFS
        mods = ns === nothing ? nothing : get(composedrefs.modules, ns, Module[])
        ctx = (; integrated = composedrefs.integrated, mods, path, where = "on page \"$path\"", doc)
        for child in collect(page.mdast.children)
            resolve_composedrefs!(child, ctx)
        end
    end
    return
end

function collect_composedref_targets!(targets, node, mods, where)
    if is_composedref(node.element)
        target = composedref_target(node, where)
        composedref_binding(target, mods, where)
        push!(targets, target)
        return
    end
    for c in node.children
        collect_composedref_targets!(targets, c, mods, where)
    end
    return
end

# The docstrings are scanned in their assembled form (`parsedoc`), the same one
# the pipeline stage later sees, so a link spanning an interpolation boundary in
# the raw docstring source is not missed.
function module_docstring_asts!(asts, mod)
    meta = Base.Docs.meta(mod; autoinit = false)
    if meta !== nothing
        for multidoc in values(meta)
            for docstr in values(multidoc.docs)
                push!(asts, convert(MarkdownAST.Node, Documenter.DocSystem.parsedoc(docstr)))
            end
        end
    end
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        sub = getfield(mod, name)
        sub isa Module && sub !== mod && parentmodule(sub) === mod &&
            module_docstring_asts!(asts, sub)
    end
    return asts
end

markdown_ast(md) = convert(MarkdownAST.Node, Markdown.parse(md))

function composedref_targets(srcdir, own_mods, composedref_mods)
    targets = String[]
    for path in markdown_files(srcdir)
        where = "on page \"$(relpath(path, srcdir))\""
        collect_composedref_targets!(
            targets, markdown_ast(read(path, String)), composedref_mods, where,
        )
    end
    for mod in own_mods
        where = "in a docstring of module \"$mod\""
        for ast in module_docstring_asts!(MarkdownAST.Node[], mod)
            collect_composedref_targets!(targets, ast, composedref_mods, where)
        end
    end
    return unique!(targets)
end

# Obscure enough that a fragment can still have a page of its own called
# "composedrefs.md"; it only ever exists in the standalone build.
const COMPOSEDREFS_PAGE = "documenterfragments_composedrefs.md"

composedrefs_placeholder(targets) = """
# Docstrings Available at Composition

This page was generated by [DocumenterFragments.jl](https://github.com/PumasAI/DocumenterFragments.jl)
for the standalone fragment build only. It collects the docstrings this fragment
references with `@composedref` links, so the links can be followed and checked
here. In the composed site the links lead to the pages of the fragment owning
each module, and this page is not present. Links within the collected docstrings
lead to their home doc set and are shown as plain text here.

```@composedrefdocs
$(join(targets, '\n'))
```
"""

is_composedrefdocs(el) =
    el isa MarkdownAST.CodeBlock && startswith(el.info, "@composedrefdocs")

function unwrap_link!(node)
    for child in collect(node.children)
        MarkdownAST.insert_before!(node, child)
    end
    MarkdownAST.unlink!(node)
    return
end

# The spliced copies are a standalone-only preview, so links that only work in
# their home doc set (`@ref`s among the dependency's own docstrings, `@cite`s
# into its bibliography, relative links to its pages or files) are flattened to
# their display content; only links with a scheme (https, mailto, ...) survive.
function demote_docstring_links!(node)
    el = node.element
    if el isa MarkdownAST.Link && !occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", el.destination)
        unwrap_link!(node)
        return
    end
    for c in collect(node.children)
        demote_docstring_links!(c)
    end
    return
end

# Replicates what Documenter's `@docs` expander does for each docstring, without
# its restriction to `modules`, which the composedref modules are deliberately
# not part of: their docstring coverage is not this fragment's to check, and
# their doctests must not run here.
function expand_composedrefdocs!(node, page, mods, doc)
    codeblock = node.element
    where = "on page \"$COMPOSEDREFS_PAGE\""
    docsnodes = MarkdownAST.Node[]
    for line in split(codeblock.code, '\n'; keepempty = false)
        target = String(strip(line))
        binding = composedref_binding(target, mods, where)
        object = Documenter.Object(binding, Union{})
        # Two targets can normalize to one binding (a reexported alias, or a
        # module in both `modules` and `composedref_modules` whose docstring a
        # fragment page already placed); the object is spliced only once and
        # every link resolves to that one copy.
        haskey(doc.internal.objects, object) && continue
        anchor = Documenter.anchor_add!(
            doc.internal.docs, object, Documenter.slugify(object), page.build,
        )
        docsnode = Documenter.DocsNode(anchor, object, page)
        for docstr in Documenter.DocSystem.getdocs(binding)
            md = Documenter.DocSystem.parsedoc(docstr)
            ast = convert(MarkdownAST.Node, md)
            doc.user.highlightsig && Documenter.highlightsig!(ast)
            Documenter.recursive_heading_to_bold!(ast)
            demote_docstring_links!(ast)
            push!(docsnode.mdasts, ast)
            push!(docsnode.results, docstr)
            push!(docsnode.metas, md.meta)
        end
        push!(get!(doc.internal.bindings, binding, Documenter.Object[]), object)
        doc.internal.objects[object] = docsnode
        push!(docsnodes, MarkdownAST.Node(docsnode))
    end
    node.element = Documenter.DocsNodesBlock(codeblock)
    for docsnode in docsnodes
        push!(node.children, docsnode)
    end
    return
end

function add_composedrefs_page!(pages, srcdir, name, targets)
    path = joinpath(srcdir, COMPOSEDREFS_PAGE)
    isfile(path) && error(
        "Fragment \"$name\" uses `@composedref` links, so the standalone build needs to " *
            "generate \"$COMPOSEDREFS_PAGE\", but the fragment already ships that page. " *
            "Rename it.",
    )
    write(path, composedrefs_placeholder(targets))
    return push!(pages, "Docstrings Available at Composition" => COMPOSEDREFS_PAGE)
end

function load_module(name, module_map)
    haskey(module_map, name) && return module_map[name]
    sym = Symbol(name)
    return isdefined(Main, sym) ? getfield(Main, sym) : Base.require(Main, sym)
end

load_modules(names, module_map) = Module[load_module(n, module_map) for n in names]

resolve_modules(meta::FragmentMeta, module_map) = load_modules(meta.modules, module_map)

scope_identifier(key) =
    Symbol("DocumenterFragmentScope_" * replace(String(key), r"[^0-9A-Za-z_]" => "_"))

# Composedref modules are deliberately not made reachable from the scope: a plain
# `@ref` must never resolve into them, so a fragment cannot pass standalone with a
# ref that only the composed site could carry.
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
    set_doctestmeta!(mods, :DocTestSetup, meta.doctest_setup)
    set_doctestmeta!(mods, :DocTestTeardown, meta.doctest_teardown)
    return
end

function set_doctestmeta!(mods, key, code)
    code === nothing && return
    expr = Meta.parse(code)
    for m in mods
        DocMeta.setdocmeta!(m, key, expr; recursive = true)
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
`doctest_setup` and `doctest_teardown`, an optional `bibliography` file, and the
page tree. Keyword arguments mirror the relevant
`Documenter.makedocs`/`Documenter.HTML` options (`doctest`, `warnonly`,
`checkdocs`, `prettyurls`, `plugins`, `page_meta`, ...); any extra keywords are
forwarded to `makedocs`. Unlike `makedocs`, `checkdocs`
defaults to `:public`, so unexported internal docstrings do not have to be
spliced into any page.

A declared `bibliography` is turned into a `CitationBibliography` plugin unless
`plugins` already carries one. A generated `References` page is appended so that
the fragment's citations resolve in the standalone build; any `@bibliography`
blocks the fragment carries itself must be `Canonical = false`, since the
composed site owns the canonical bibliography.

`@composedref` links into modules declared as `composedref_modules` are validated
against the loaded modules and resolved to a generated `Docstrings Available at
Composition` page collecting the referenced docstrings, standing in for the pages
of the fragments that carry them in the composed site.
"""
function build_fragment(
        dir::AbstractString;
        build = joinpath(dir, "build"),
        module_map = Dict{String, Module}(),
        doctest::Bool = true,
        warnonly = Symbol[],
        checkdocs::Symbol = :public,
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
    composedref_mods = load_modules(meta.composedref_modules, module_map)
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
    targets = composedref_targets(staged_src, mods, composedref_mods)
    isempty(targets) || add_composedrefs_page!(pages, staged_src, meta.name, targets)
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
        plugins = vcat(
            fragment_plugins(meta, plugins),
            FragmentComposedRefs(false, Dict(STANDALONE_COMPOSEDREFS => composedref_mods)),
        ),
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
    composedref_mods = load_modules(meta.composedref_modules, module_map)
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
        composedref_modules = composedref_mods,
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

function is_module_or_ancestor(candidate, mod)
    while true
        candidate === mod && return true
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
    return
end

# Provision is checked on the loaded modules themselves, not on names, so
# same-named modules stay distinct and a submodule (`Widgets.Internals`) counts as
# provided by whoever provides its parent.
function validate_composedref_provision(checks, providers)
    for (fragname, mod) in checks
        any(p -> is_module_or_ancestor(p, mod), providers) || error(
            "Fragment \"$fragname\" declares composedref module \"$mod\", but neither a " *
                "fragment in this composition nor `main_modules` provides that module (or " *
                "a parent of it), so its `@composedref` targets would have no docstrings " *
                "to land on. Include the fragment documenting it, or pass " *
                "`main_modules = [$mod]` to `integrate_fragments` if the main site's own " *
                "pages document it.",
        )
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
    composedrefs::FragmentComposedRefs
    citations::Union{Nothing, Documenter.Plugin}
    plugins::Vector{Documenter.Plugin}
end

function Integration(fragments, modules, namespacing, composedrefs, citations)
    plugins = Documenter.Plugin[namespacing, composedrefs]
    citations === nothing || push!(plugins, citations)
    return Integration(fragments, modules, namespacing, composedrefs, citations, plugins)
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

A fragment's `@composedref` links are resolved into ordinary docstring links, to
the pages of whichever fragment owns the target module, or to the main site's own
docstring pages for modules listed in `main_modules` (pass the same modules to
`makedocs`). Every declared `composedref_module` must be provided one of these two
ways, or the integration errors.

Returns an [`Integration`](@ref) whose `fragments` are [`IntegratedFragment`](@ref)s
(each carrying `pages`, `detached`, `modules`, ...), the combined `modules`, and the
`plugins` to pass to `makedocs` so anchors, cross-references, dependency links and
citations stay unique and resolvable across fragments.
"""
function integrate_fragments(
        main_src::AbstractString,
        specs;
        module_map = Dict{String, Module}(),
        citations = nothing,
        main_modules = Module[],
    )
    validate_module_ownership(specs)
    page_slugs = Pair{String, String}[]
    bibliography_keys = Dict{String, Vector{String}}()
    composedref_modules = Dict{String, Vector{Module}}()
    composedref_checks = Tuple{String, Module}[]
    contributions = Tuple{String, Any}[]
    slugs_taken = Set{String}()
    fragments = map(specs) do spec
        slug = disambiguate!(slugs_taken, default_namespace(spec.mount))
        page_meta = hasproperty(spec, :page_meta) ? spec.page_meta : ()
        prep = prepare_fragment!(main_src, spec.dir, spec.mount; slug, module_map, page_meta)
        for path in prep.page_paths
            push!(page_slugs, path => slug)
        end
        isempty(prep.composedref_modules) || (composedref_modules[slug] = prep.composedref_modules)
        for mod in prep.composedref_modules
            push!(composedref_checks, (prep.meta.name, mod))
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
    validate_composedref_provision(composedref_checks, [modules; main_modules])
    return Integration(
        fragments,
        modules,
        FragmentNamespaces(page_slugs, bibliography_keys),
        FragmentComposedRefs(true, composedref_modules),
        isempty(contributions) ? citations : merge_citations(citations, contributions),
    )
end

end
