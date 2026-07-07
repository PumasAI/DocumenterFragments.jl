using Pkg, TOML

if isempty(ARGS)
    error("Usage: julia ensure.jl <project-path>")
end
Pkg.activate(ARGS[1])

function manifest_has_correct_julia_version()
    manifest_file = joinpath(dirname(Base.active_project()), "Manifest.toml")
    isfile(manifest_file) || return false
    version = VersionNumber(TOML.parsefile(manifest_file)["julia_version"])
    return version.major == VERSION.major && version.minor == VERSION.minor
end

is_manifest_current = @static if VERSION < v"1.11.0-DEV.1135"
    Pkg.is_manifest_current()
else
    Pkg.is_manifest_current(dirname(Base.active_project()))
end

if is_manifest_current === true && manifest_has_correct_julia_version()
    Pkg.instantiate()
else
    Pkg.update()
end
Pkg.precompile()
