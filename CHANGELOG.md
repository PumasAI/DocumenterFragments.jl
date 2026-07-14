# DocumenterFragments.jl changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Multiple fragments can now share a single mount; colliding file paths raise a clear error [#4](https://github.com/PumasAI/DocumenterFragments.jl/pull/4).

## [0.1.1](https://github.com/PumasAI/DocumenterFragments.jl/releases/tag/v0.1.1) - 2026-07-13

- Fixed `build_fragment` skipping doctests by default; doctests now run as part of the strict standalone build [#1](https://github.com/PumasAI/DocumenterFragments.jl/pull/1).
