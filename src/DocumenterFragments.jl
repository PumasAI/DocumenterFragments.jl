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
    page_entries::Vector{Any}
    dir::String
end

function read_fragment(dir::AbstractString)
    toml = TOML.parsefile(joinpath(dir, "fragment.toml"))
    name = toml["name"]
    modules = collect(String, get(toml, "modules", String[]))
    setup = get(toml, "doctest_setup", nothing)
    entries = collect(Any, get(toml, "pages", Any[]))
    return FragmentMeta(name, modules, setup, entries, String(dir))
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

struct FragmentNamespaces <: Documenter.Plugin
    prefixes::Vector{Pair{String, String}}
end
FragmentNamespaces() = FragmentNamespaces(Pair{String, String}[])

function namespace_for(path, prefixes)
    p = replace(String(path), '\\' => '/')
    for (mount, ns) in prefixes
        (p == mount || startswith(p, mount * "/")) && return ns
    end
    return nothing
end

abstract type FragmentNamespacing <: Documenter.Builder.DocumentPipeline end
Documenter.Selectors.order(::Type{FragmentNamespacing}) = 1.5
function Documenter.Selectors.runner(::Type{FragmentNamespacing}, doc)
    haskey(doc.plugins, FragmentNamespaces) || return
    prefixes = Documenter.getplugin(doc, FragmentNamespaces).prefixes
    isempty(prefixes) && return
    ordered = sort(prefixes; by = p -> length(first(p)), rev = true)
    for (path, page) in doc.blueprint.pages
        ns = namespace_for(path, ordered)
        ns === nothing && continue
        for child in collect(page.mdast.children)
            namespace_ast!(child, ns)
        end
    end
    return
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

function set_currentmodule!(srcdir, scopename; page_meta = ())
    lines = ["CurrentModule = $(scopename)"]
    for (k, v) in page_meta
        push!(lines, "$k = $v")
    end
    block = "```@meta\n" * join(lines, "\n") * "\n```\n\n"
    for (root, _, files) in walkdir(srcdir)
        for f in files
            endswith(f, ".md") || continue
            p = joinpath(root, f)
            write(p, block * read(p, String))
        end
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

"""
    build_fragment(dir; kwargs...) -> build_dir

Build the documentation fragment at `dir` into a standalone Documenter site and
return the output directory.

The fragment's `fragment.toml` supplies its name, the modules to document
(loaded automatically, so `make.jl` needs no `using`), an optional
`doctest_setup`, and the page tree. Keyword arguments mirror the relevant
`Documenter.makedocs`/`Documenter.HTML` options (`doctest`, `warnonly`,
`checkdocs`, `prettyurls`, `repolink`, `page_meta`, ...); any extra keywords are
forwarded to `makedocs`.
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
        kwargs...,
    )
    meta = read_fragment(dir)
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
        remotes = nothing,
        format = Documenter.HTML(; prettyurls, edit_link = nothing, repolink, inventory_version),
        kwargs...,
    )
    return build
end

default_namespace(mount) = slugify(replace(String(mount), '/' => '-'))

function prepare_fragment!(
        main_src::AbstractString,
        dir::AbstractString,
        mount::AbstractString;
        slug::AbstractString = default_namespace(mount),
        module_map = Dict{String, Module}(),
        page_meta = (),
    )
    meta = read_fragment(dir)
    mods = resolve_modules(meta, module_map)
    apply_doctestsetup!(meta, mods)
    scopename = make_scope(mods, slug)

    dest = joinpath(main_src, mount)
    cp(joinpath(dir, "src"), dest)
    set_currentmodule!(dest, scopename; page_meta)

    return (
        pages = meta.name => documenter_pages(meta; prefix = mount),
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
end

"""
    integrate_fragments(main_src, specs; module_map = Dict{String,Module}()) -> Integration

Integrate several fragments into a main site's source tree rooted at `main_src`.

Each spec names a fragment `dir` and the `mount` path to place it under (plus
optional `slug`, `page_meta`, and `detach`). For every fragment the sources are
copied under its mount, its module scope and doctest setup are established, and
any pages listed in `detach` are pulled out for the integrator to reroute. Each
module must be owned by exactly one fragment.

Returns an [`Integration`](@ref) whose `fragments` are [`IntegratedFragment`](@ref)s
(each carrying `pages`, `detached`, `modules`, ...), the combined `modules`, and a
`namespacing` plugin to pass to `makedocs` so anchors and cross-references stay
unique across fragments.
"""
function integrate_fragments(main_src::AbstractString, specs; module_map = Dict{String, Module}())
    validate_module_ownership(specs)
    prefixes = Pair{String, String}[]
    fragments = map(specs) do spec
        slug = hasproperty(spec, :slug) ? spec.slug : default_namespace(spec.mount)
        page_meta = hasproperty(spec, :page_meta) ? spec.page_meta : ()
        prep = prepare_fragment!(main_src, spec.dir, spec.mount; slug, module_map, page_meta)
        push!(prefixes, spec.mount => slug)

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
    return Integration(fragments, modules, FragmentNamespaces(prefixes))
end

end
