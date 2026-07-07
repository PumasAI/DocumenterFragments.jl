ensure_env := "julia --startup-file=no .format/ensure.jl"

# List available recipes
default:
    @just --list

# Instantiate the self-contained Runic environment, reusing it when it is current
[private]
format-setup:
    {{ ensure_env }} .format

# Format all Julia code in place with Runic
format: format-setup
    julia --startup-file=no --project=.format .format/runic.jl --inplace .

# Check formatting without modifying files (mirrors CI)
check-format: format-setup
    julia --startup-file=no --project=.format .format/runic.jl --check --diff .

# Run the test suite
test:
    julia --startup-file=no --project=. -e 'import Pkg; Pkg.test()'
