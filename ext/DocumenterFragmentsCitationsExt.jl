module DocumenterFragmentsCitationsExt

import DocumenterFragments
using DocumenterCitations: CitationBibliography

DocumenterFragments.with_bibliography(plugins, bibfile) =
    any(p -> p isa CitationBibliography, plugins) ? plugins :
    [plugins; CitationBibliography(bibfile)]

# Reading through the plugin rather than Bibliography directly applies the same
# key normalization the final plugin will apply.
DocumenterFragments.read_entries(bibfile) = CitationBibliography(bibfile).entries

# The bibliographic fields an entry groups into structs, `date` and `in` among
# them, are where drift between two copies of an entry usually is, so report the
# differing leaf rather than a struct full of empty strings.
grouped(value) =
    isstructtype(typeof(value)) &&
    !isempty(fieldnames(typeof(value))) &&
    all(t -> t === String, fieldtypes(typeof(value)))

function differences(a, b, prefix = "")
    found = Tuple{String, Any, Any}[]
    for field in fieldnames(typeof(a))
        left, right = getfield(a, field), getfield(b, field)
        left == right && continue
        path = "$prefix$field"
        if grouped(left) && typeof(left) === typeof(right)
            append!(found, differences(left, right, "$path."))
        else
            push!(found, (path, left, right))
        end
    end
    return found
end

function conflict_message(key, differing, other, owner)
    io = IOBuffer()
    print(
        io,
        "Citation key \"$key\" is supplied by both $other and $owner, but the entries differ:",
    )
    for (path, left, right) in differing
        print(io, "\n  $path\n    $other: $(repr(left))\n    $owner: $(repr(right))")
    end
    print(
        io,
        "\nA key shared between fragments, or with the main site, must carry the same entry " *
            "everywhere; reconcile the `.bib` files, or rename the key in one of them.",
    )
    return String(take!(io))
end

# Two contributors may supply the same key. That is expected when an entry was
# copied from a common source, and then the merged bibliography carries it once
# and both cite it; it is a mistake when the entries have drifted apart, which
# nothing downstream would notice.
function validate_shared_keys(base, contributions)
    seen = Dict{String, Tuple{String, Any}}()
    base === nothing || for (key, entry) in base.entries
        seen[key] = ("the main site", entry)
    end
    for (owner, entries) in contributions
        for (key, entry) in entries
            if haskey(seen, key)
                other, existing = seen[key]
                differing = differences(existing, entry)
                isempty(differing) || error(conflict_message(key, differing, other, owner))
            else
                seen[key] = (owner, entry)
            end
        end
    end
    return
end

merged_entries(contributions) = merge((last(c) for c in contributions)...)

# The main site passed no bibliography of its own, so the composed one is
# entirely the fragments'. `_entries` is DocumenterCitations' deliberate, if
# undocumented, hook for combining several bib files; `bibfile` is then only a
# label for its log messages.
function DocumenterFragments.merge_citations(::Nothing, contributions)
    validate_shared_keys(nothing, contributions)
    return CitationBibliography(
        "the fragment bibliographies";
        _entries = merged_entries(contributions),
    )
end

# A site holds exactly one `CitationBibliography`, so the fragments' entries have
# to be merged into the main site's. It is immutable, hence the rebuild from the
# options the main site chose.
function DocumenterFragments.merge_citations(base::CitationBibliography, contributions)
    validate_shared_keys(base, contributions)
    return CitationBibliography(
        base.bibfile;
        style = base.style,
        insert_css = base.insert_css,
        show_hover = base.show_hover,
        show_backlinks = base.show_backlinks,
        _entries = merge(base.entries, merged_entries(contributions)),
    )
end

end
