# DocumenterFragments.jl changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Fragments can declare a `doctest_teardown` in `fragment.toml`, applied as Documenter's `DocTestTeardown`.

## [0.2.1](https://github.com/PumasAI/DocumenterFragments.jl/releases/tag/v0.2.1) - 2026-09-03

- Fragments can link to docstrings of declared `composedref_modules` with `@composedref` links, resolved into real links at composition [#11](https://github.com/PumasAI/DocumenterFragments.jl/pull/11).

## [0.2.0](https://github.com/PumasAI/DocumenterFragments.jl/releases/tag/v0.2.0) - 2026-09-01

- Breaking: `build_fragment` now defaults to `checkdocs = :public` instead of `:all` [#10](https://github.com/PumasAI/DocumenterFragments.jl/pull/10).

## [0.1.3](https://github.com/PumasAI/DocumenterFragments.jl/releases/tag/v0.1.3) - 2026-08-26

- Fragments can declare a `bibliography` in `fragment.toml`, whose entries are merged into the composed site [#7](https://github.com/PumasAI/DocumenterFragments.jl/pull/7).

## [0.1.2](https://github.com/PumasAI/DocumenterFragments.jl/releases/tag/v0.1.2) - 2026-07-14

- Multiple fragments can now share a single mount; colliding file paths raise a clear error [#4](https://github.com/PumasAI/DocumenterFragments.jl/pull/4).

## [0.1.1](https://github.com/PumasAI/DocumenterFragments.jl/releases/tag/v0.1.1) - 2026-07-13

- Fixed `build_fragment` skipping doctests by default; doctests now run as part of the strict standalone build [#1](https://github.com/PumasAI/DocumenterFragments.jl/pull/1).
