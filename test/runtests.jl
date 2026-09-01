using Test
using DocumenterFragments
using DocumenterFragments: build_fragment, integrate_fragments, namespace_ast!
using DocumenterFragments: scope_bibliography_block!
import Documenter
import DocumenterCitations
import MarkdownAST
import Markdown
using Logging

global_logger(ConsoleLogger(stderr, Logging.Warn))
silent_build(args...; kwargs...) = with_logger(NullLogger()) do
    build_fragment(args...; kwargs...)
end

module FragmentA
    export foo
    "The `foo` function of Fragment A."
    function foo end
end

module FragmentB
    export bar
    "The `bar` function of Fragment B."
    function bar end
end

module FragmentXref
    export baz
    "The `baz` function of Fragment Xref."
    function baz end
end

module FragmentMissing
    export mfun
    "The `mfun` function, deliberately not spliced into any page."
    function mfun end
end

module FragmentInternal
    "An internal helper, deliberately not spliced into any page."
    function ifun end
end

VERSION >= v"1.11" && include("fragment_public_module.jl")

module FragmentCite
    export cited
    "Function `cited` follows the conventions of [Lamport1994](@cite)."
    function cited end
end

module FragmentDoctest
    export qux
    """
        qux()

    ```jldoctest
    julia> 1 + 1
    3
    ```
    """
    function qux end
end

const FIXTURES = joinpath(@__DIR__, "fixtures")
const MODULE_MAP = Dict(
    "FragmentA" => FragmentA,
    "FragmentB" => FragmentB,
    "FragmentXref" => FragmentXref,
    "FragmentMissing" => FragmentMissing,
    "FragmentInternal" => FragmentInternal,
    "FragmentDoctest" => FragmentDoctest,
    "FragmentCite" => FragmentCite,
)
VERSION >= v"1.11" && (MODULE_MAP["FragmentPublic"] = FragmentPublic)

readbuilt(build, parts...) = read(joinpath(build, parts...), String)

reset_doctestmeta!() =
    foreach(m -> delete!(Documenter.DocMeta.getdocmeta(m), :DocTestSetup), values(MODULE_MAP))

function link_destinations(md, prefix)
    ast = convert(MarkdownAST.Node, Markdown.parse(md))
    for child in collect(ast.children)
        namespace_ast!(child, prefix)
    end
    dests = String[]
    walk(n) =
        (
        n.element isa MarkdownAST.Link && push!(dests, n.element.destination);
        foreach(walk, n.children)
    )
    foreach(walk, ast.children)
    return dests
end

@testset "namespace_ast! rewrites headings and section refs" begin
    @test link_destinations("# Introduction", "fraga") == ["@id fraga-Introduction"]
    @test link_destinations("# [Title](@id Custom)", "fraga") == ["@id fraga-Custom"]
    @test link_destinations("see [Examples](@ref) here", "fraga") == ["@ref fraga-Examples"]
    @test link_destinations("[x](@ref Plots-NCA)", "fraga") == ["@ref fraga-Plots-NCA"]
    @test link_destinations("[x](@ref \"Some Header\")", "fraga") ==
        ["@ref fraga-Some-Header"]
end

@testset "namespace_ast! leaves docstring refs and code blocks alone" begin
    @test link_destinations("call [`foo`](@ref) now", "fraga") == ["@ref"]
    @test link_destinations("```@autodocs\nModules = [X]\n```\n", "fraga") == String[]
end

function scoped_block(code; bib_keys = String[], pages = String[])
    node = MarkdownAST.Node(MarkdownAST.CodeBlock("@bibliography", code))
    scope_bibliography_block!(node, (; bib_keys, pages, citations = Ref(0)))
    return node.element.code
end

@testset "a @bibliography block is scoped to its fragment for composition" begin
    fields = "Pages = [\n    \"a.md\",\n]\nCanonical = false\nSorting = :nyt"
    @test scoped_block(fields * "\nKnuth1984\n") == fields * "\nKnuth1984\n"
    @test scoped_block("Pages = []\n*\n"; bib_keys = ["Handbook"]) ==
        "Pages = []\nHandbook\n"
    @test scoped_block("Canonical = false\nKnuth1984\n"; pages = ["a.md", "b.md"]) ==
        "Canonical = false\nPages = [\"a.md\", \"b.md\"]\nKnuth1984\n"
end

@testset "page_meta injects extra lines into the CurrentModule block" begin
    dir = mktempdir()
    write(joinpath(dir, "page.md"), "# Title\n")
    DocumenterFragments.set_currentmodule!(dir, :ScopeMod; page_meta = ("Draft" => false,))
    out = read(joinpath(dir, "page.md"), String)
    @test startswith(out, "```@meta\nCurrentModule = ScopeMod\nDraft = false\n```\n")
    @test occursin("# Title", out)
end

@testset "standalone build is un-namespaced: Fragment A" begin
    reset_doctestmeta!()
    build = mktempdir()
    build_fragment(joinpath(FIXTURES, "fragment_a"); build, module_map = MODULE_MAP)

    @test isfile(joinpath(build, "introduction", "index.html"))
    @test isfile(joinpath(build, "assets", "plot.png"))

    intro = readbuilt(build, "introduction", "index.html")
    @test occursin("href=\"#Examples\"", intro)
    @test occursin("assets/plot.png", intro)
end

@testset "generated home page is marked as standalone-only" begin
    reset_doctestmeta!()
    build = mktempdir()
    build_fragment(joinpath(FIXTURES, "fragment_a"); build, module_map = MODULE_MAP)
    home = readbuilt(build, "index.html")
    @test occursin("github.com/PumasAI/DocumenterFragments.jl", home)
    @test occursin("for the standalone fragment build only", home)
    @test occursin("not be present once the fragment is integrated into the full site", home)
end

@testset "standalone build is un-namespaced: Fragment B" begin
    reset_doctestmeta!()
    build = mktempdir()
    build_fragment(joinpath(FIXTURES, "fragment_b"); build, module_map = MODULE_MAP)
    overview = readbuilt(build, "overview", "index.html")
    @test occursin("href=\"#Examples\"", overview)
end

@testset "cross-package reference fails the fragment build" begin
    reset_doctestmeta!()
    build = mktempdir()
    @test_throws "cross_references" silent_build(
        joinpath(FIXTURES, "fragment_xref");
        build,
        module_map = MODULE_MAP,
    )
end

@testset "fragment resolves refs without any name in Main" begin
    reset_doctestmeta!()
    @test !isdefined(Main, :foo)
    build = mktempdir()
    build_fragment(joinpath(FIXTURES, "fragment_a"); build, module_map = MODULE_MAP)
    @test occursin("foo", readbuilt(build, "introduction", "index.html"))
    @test !isdefined(Main, :foo)
end

@testset "a docstring ref outside the fragment's modules fails" begin
    reset_doctestmeta!()
    @test_throws "cross_references" silent_build(
        joinpath(FIXTURES, "fragment_leak");
        build = mktempdir(),
        module_map = MODULE_MAP,
    )
end

@testset "an undocumented docstring fails the fragment build" begin
    reset_doctestmeta!()
    @test_throws "missing_docs" silent_build(
        joinpath(FIXTURES, "fragment_missing");
        build = mktempdir(),
        module_map = MODULE_MAP,
    )
end

@testset "unexported docstrings pass the default checkdocs" begin
    reset_doctestmeta!()
    build = build_fragment(
        joinpath(FIXTURES, "fragment_internal");
        build = mktempdir(),
        module_map = MODULE_MAP,
    )
    @test isfile(joinpath(build, "overview", "index.html"))
end

VERSION >= v"1.11" && @testset "public docstrings still fail the default checkdocs" begin
    reset_doctestmeta!()
    @test_throws "missing_docs" silent_build(
        joinpath(FIXTURES, "fragment_public");
        build = mktempdir(),
        module_map = MODULE_MAP,
    )
end

@testset "checkdocs knob can relax the coverage check" begin
    reset_doctestmeta!()
    build = build_fragment(
        joinpath(FIXTURES, "fragment_missing");
        build = mktempdir(),
        checkdocs = :none,
        module_map = MODULE_MAP,
    )
    @test isfile(joinpath(build, "overview", "index.html"))
end

@testset "doctests run by default and fail on mismatch" begin
    reset_doctestmeta!()
    @test_throws "doctest error" silent_build(
        joinpath(FIXTURES, "fragment_doctest");
        build = mktempdir(),
        module_map = MODULE_MAP,
    )
end

@testset "doctest = false skips doctesting" begin
    reset_doctestmeta!()
    build = build_fragment(
        joinpath(FIXTURES, "fragment_doctest");
        build = mktempdir(),
        doctest = false,
        module_map = MODULE_MAP,
    )
    @test isfile(joinpath(build, "docstrings", "index.html"))
end

@testset "integrate_fragments into a main site" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    cp(joinpath(FIXTURES, "main_site", "src"), main_src)

    c = integrate_fragments(
        main_src,
        [
            (; dir = joinpath(FIXTURES, "fragment_a"), mount = "fraga"),
            (; dir = joinpath(FIXTURES, "fragment_b"), mount = "fragb"),
        ];
        module_map = MODULE_MAP,
    )

    @test [f.name for f in c.fragments] == ["Fragment A", "Fragment B"]
    @test c.modules == Module[FragmentA, FragmentB]

    build = mktempdir()
    Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build,
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = [c.namespacing],
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any["Home" => "index.md"; [f.pages for f in c.fragments]],
    )

    @test isfile(joinpath(build, "fraga", "introduction", "index.html"))
    @test isfile(joinpath(build, "fragb", "overview", "index.html"))
    @test isfile(joinpath(build, "fraga", "assets", "plot.png"))

    @test occursin("fraga-Examples", readbuilt(build, "fraga", "introduction", "index.html"))
    @test occursin("fragb-Examples", readbuilt(build, "fragb", "overview", "index.html"))
end

@testset "integrate_fragments detaches pages for the integrator to reroute" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    cp(joinpath(FIXTURES, "main_site", "src"), main_src)

    c = integrate_fragments(
        main_src,
        [(; dir = joinpath(FIXTURES, "fragment_a"), mount = "fraga", detach = ["docstrings.md"])];
        module_map = MODULE_MAP,
    )
    a = only(c.fragments)

    kept_files = [p.second for p in a.pages.second if p.second isa AbstractString]
    @test kept_files == ["fraga/introduction.md"]
    @test a.detached["docstrings.md"] == ("API" => "fraga/docstrings.md")

    build = mktempdir()
    Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build,
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = [c.namespacing],
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any[
            "Home" => "index.md",
            a.pages,
            "Reference" => Any["NCA" => a.detached["docstrings.md"].second],
        ],
    )

    @test isfile(joinpath(build, "fraga", "docstrings", "index.html"))
    @test occursin("foo", readbuilt(build, "fraga", "docstrings", "index.html"))
end

@testset "integrate_fragments rejects a module owned by two fragments" begin
    fa = joinpath(FIXTURES, "fragment_a")
    @test_throws "must be owned by exactly one fragment" integrate_fragments(
        joinpath(mktempdir(), "src"),
        [(; dir = fa, mount = "x"), (; dir = fa, mount = "y")];
        module_map = MODULE_MAP,
    )
end

@testset "two fragments merge under a shared mount" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    mkpath(main_src)
    write(joinpath(main_src, "index.md"), "# Main Site\n")

    c = integrate_fragments(
        main_src,
        [
            (; dir = joinpath(FIXTURES, "merge_alpha"), mount = "combined"),
            (; dir = joinpath(FIXTURES, "merge_beta"), mount = "combined"),
        ];
        module_map = MODULE_MAP,
    )

    @test [f.name for f in c.fragments] == ["Merge Alpha", "Merge Beta"]
    @test [f.pages.second[1].second for f in c.fragments] ==
        ["combined/alpha.md", "combined/beta.md"]
    @test c.namespacing.page_slugs ==
        ["combined/alpha.md" => "combined", "combined/beta.md" => "combined_2"]
    @test c.modules == Module[FragmentA, FragmentB]

    build = mktempdir()
    Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build,
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = [c.namespacing],
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any["Home" => "index.md"; [f.pages for f in c.fragments]],
    )

    @test isfile(joinpath(build, "combined", "alpha", "index.html"))
    @test isfile(joinpath(build, "combined", "beta", "index.html"))

    alpha = readbuilt(build, "combined", "alpha", "index.html")
    beta = readbuilt(build, "combined", "beta", "index.html")
    @test occursin("combined-Examples", alpha)
    @test occursin("combined_2-Examples", beta)
    @test occursin("foo", alpha)
    @test occursin("bar", beta)
end

@testset "colliding filenames under a shared mount error clearly" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    cp(joinpath(FIXTURES, "main_site", "src"), main_src)

    @test_throws "colliding file paths" integrate_fragments(
        main_src,
        [
            (; dir = joinpath(FIXTURES, "fragment_a"), mount = "shared"),
            (; dir = joinpath(FIXTURES, "fragment_b"), mount = "shared"),
        ];
        module_map = MODULE_MAP,
    )
end

@testset "standalone build resolves a fragment's own bibliography" begin
    reset_doctestmeta!()
    build = build_fragment(
        joinpath(FIXTURES, "fragment_bib");
        build = mktempdir(),
        module_map = MODULE_MAP,
    )
    overview = readbuilt(build, "overview", "index.html")
    docstrings = readbuilt(build, "docstrings", "index.html")
    references = readbuilt(build, "documenterfragments_references", "index.html")

    @test occursin("for the standalone fragment build only", references)
    @test occursin("id=\"Knuth1984\"", references)
    @test occursin("The TeXbook", references)
    @test occursin("The Not So Short Introduction", overview)
    @test occursin("href=\"../documenterfragments_references/#Knuth1984\"", overview)
    @test occursin("href=\"../documenterfragments_references/#Lamport1994\"", docstrings)
end

@testset "a fragment may not own a canonical bibliography" begin
    reset_doctestmeta!()
    @test_throws "cannot own the canonical bibliography" silent_build(
        joinpath(FIXTURES, "bib_canonical");
        build = mktempdir(),
    )
    @test_throws "cannot own the canonical bibliography" integrate_fragments(
        joinpath(mktempdir(), "src"),
        [(; dir = joinpath(FIXTURES, "bib_canonical"), mount = "bibc")],
    )
end

@testset "fragments sharing a citation key share one entry" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    mkpath(main_src)
    write(joinpath(main_src, "index.md"), "# Main Site\n\n```@bibliography\n```\n")

    c = integrate_fragments(
        main_src,
        [
            (; dir = joinpath(FIXTURES, "bib_alpha"), mount = "biba"),
            (; dir = joinpath(FIXTURES, "bib_beta"), mount = "bibb"),
        ],
    )

    @test collect(keys(c.citations.entries)) == ["Handbook", "AlphaOnly", "BetaOnly"]
    @test c.plugins == Documenter.Plugin[c.namespacing, c.citations]

    build = mktempdir()
    Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build,
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = c.plugins,
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any["Home" => "index.md"; [f.pages for f in c.fragments]],
    )

    index = readbuilt(build, "index.html")
    alpha = readbuilt(build, "biba", "alpha", "index.html")
    beta = readbuilt(build, "bibb", "beta", "index.html")

    for key in ["Handbook", "AlphaOnly", "BetaOnly"]
        @test occursin("id=\"$key\"", index)
    end

    @test occursin("Only Alpha Cites This", alpha)
    @test !occursin("Only Beta Cites This", alpha)
    @test !occursin("id=\"Handbook\"", alpha)
    @test occursin("href=\"../../#Handbook\"", alpha)
    @test occursin("href=\"../../#Handbook\"", beta)
end

@testset "a citation key shared with a different entry errors" begin
    reset_doctestmeta!()
    conflicting() = integrate_fragments(
        joinpath(mktempdir(), "src"),
        [
            (; dir = joinpath(FIXTURES, "bib_alpha"), mount = "biba"),
            (; dir = joinpath(FIXTURES, "bib_conflict"), mount = "bibc"),
        ],
    )

    @test_throws "supplied by both fragment \"Bib Alpha\" and fragment \"Bib Conflict\"" conflicting()
    @test_throws "A Different Handbook Under the Same Key" conflicting()
end

@testset "an unscoped @bibliography block is scoped to its own fragment" begin
    reset_doctestmeta!()
    unscoped(name, page) = let dir = joinpath(mktempdir(), name), src = joinpath(dir, "src", page)
        cp(joinpath(FIXTURES, name), dir)
        write(src, replace(read(src, String), r"^Pages = \[\]\n"m => ""))
        dir
    end

    main_src = joinpath(mktempdir(), "src")
    mkpath(main_src)
    write(joinpath(main_src, "index.md"), "# Main Site\n\n```@bibliography\n```\n")

    c = integrate_fragments(
        main_src,
        [
            (; dir = unscoped("bib_alpha", "alpha.md"), mount = "biba"),
            (; dir = unscoped("bib_beta", "beta.md"), mount = "bibb"),
        ],
    )

    build = mktempdir()
    Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build,
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = c.plugins,
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any["Home" => "index.md"; [f.pages for f in c.fragments]],
    )

    alpha = readbuilt(build, "biba", "alpha", "index.html")
    beta = readbuilt(build, "bibb", "beta", "index.html")

    @test occursin("Only Alpha Cites This", alpha)
    @test !occursin("Only Beta Cites This", alpha)
    @test occursin("Only Beta Cites This", beta)
    @test !occursin("Only Alpha Cites This", beta)
end

@testset "composition needs a canonical bibliography outside the fragments" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    mkpath(main_src)
    write(joinpath(main_src, "index.md"), "# Main Site\n")

    c = integrate_fragments(
        main_src,
        [(; dir = joinpath(FIXTURES, "bib_alpha"), mount = "biba")],
    )

    @test_throws "the main site must hold the bibliography" Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build = mktempdir(),
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = c.plugins,
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any["Home" => "index.md"; [f.pages for f in c.fragments]],
    )
end

@testset "the main site's own bibliography is merged in too" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    mkpath(main_src)
    write(
        joinpath(main_src, "index.md"),
        """
        # Main Site

        The site itself cites [MainSiteWork](@cite).

        ```@bibliography
        ```
        """,
    )

    c = integrate_fragments(
        main_src,
        [(; dir = joinpath(FIXTURES, "fragment_bib"), mount = "bib")];
        module_map = MODULE_MAP,
        citations = DocumenterCitations.CitationBibliography(
            joinpath(FIXTURES, "main_site", "references.bib"),
        ),
    )

    @test collect(keys(c.citations.entries)) ==
        ["MainSiteWork", "Knuth1984", "Lamport1994", "Oetiker2021"]

    build = mktempdir()
    Base.invokelatest(
        Documenter.makedocs;
        sitename = "Main Site",
        modules = c.modules,
        source = main_src,
        build,
        doctest = false,
        warnonly = Symbol[],
        remotes = nothing,
        plugins = c.plugins,
        format = Documenter.HTML(; prettyurls = true, edit_link = nothing, repolink = nothing, inventory_version = ""),
        pages = Any["Home" => "index.md"; [f.pages for f in c.fragments]],
    )

    index = readbuilt(build, "index.html")
    @test occursin("id=\"MainSiteWork\"", index)
    @test occursin("id=\"Lamport1994\"", index)
    @test occursin(
        "href=\"../../#Lamport1994\"",
        readbuilt(build, "bib", "docstrings", "index.html"),
    )
end

@testset "fragments without a bibliography get no citation plugin" begin
    reset_doctestmeta!()
    main_src = joinpath(mktempdir(), "src")
    cp(joinpath(FIXTURES, "main_site", "src"), main_src)

    c = integrate_fragments(
        main_src,
        [(; dir = joinpath(FIXTURES, "fragment_a"), mount = "fraga")];
        module_map = MODULE_MAP,
    )

    @test c.citations === nothing
    @test c.plugins == Documenter.Plugin[c.namespacing]
end
