using Documenter, Inscription

# This code is executed in the environment in which doctests in the package's
# docstrings run. Use it to define global variables that docstrings can refer
# to.
meta = quote
    using Inscription, BufferIO
    using MemoryViews: MemoryView
end

DocMeta.setdocmeta!(Inscription, :DocTestSetup, meta; recursive = true)

makedocs(
    modules = [Inscription],
    repo = Documenter.Remotes.GitHub("BioJulia", "Inscription.jl"),
    sitename = "Inscription.jl",
    # The API reference is deliberately a single page, so exempt it from the size limits
    format = Documenter.HTML(; size_threshold_ignore = ["reference.md"]),
    doctest = true,
    # These two pages are recommended, you can add more as you wish
    pages = [
        "Inscription" => "index.md",
        "Usage" => "usage.md",
        "Examples" => "examples.md",
        "Implementing a type" => "custom.md",
        "Reference" => "reference.md",
    ],
    authors = "Jakob Nybo Andersen",
    checkdocs = :public,
    # The functions in these modules have docstrings for the REPL, but are deliberately
    # left out of the reference page, since they just forward to Inscription's functions.
    checkdocs_ignored_modules = [Inscription.Little, Inscription.Big],
)

deploydocs(;
    repo = "github.com/BioJulia/Inscription.jl.git",
    push_preview = true,
    deps = nothing,
    make = nothing,
)
