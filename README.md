# <img src="./assets/sticker.svg" width="30%" align="right" /> Inscription.jl

[![Latest Release](https://img.shields.io/github/release/BioJulia/Inscription.jl.svg)](https://github.com/BioJulia/Inscription.jl/releases/latest)
[![MIT license](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/BioJulia/Inscription.jl/blob/master/LICENSE)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://biojulia.github.io/Inscription.jl/dev)
[![](https://codecov.io/gh/BioJulia/Inscription.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/BioJulia/Inscription.jl)

Inscription.jl provides fast, zero-allocation abstractions for reading and writing values to byte arrays (via [MemoryViews.jl](https://github.com/BioJulia/MemoryViews.jl)) or to I/O (via [BufferIO.jl](https://github.com/BioJulia/BufferIO.jl)).

It can be considered a more powerful version of Base's `read(::IO, T)`, `write(::IO, ::T)`, or a safer `unsafe_load`/`unsafe_store!`.
Alternatively, it can be viewed as an extension that allows writing arbitrary values of any type into the buffers provided by BufferIO.jl.

You might want to use this package if you find yourself:
* Using `unsafe_load`, `unsafe_store!` a lot,
* Care about how much `write(::IO, ::Float32)` allocates or the speed of `print(::IO, ::Int32)` is,
* Find yourself writing non-`UInt8` data into `Vector{UInt8}`s for IO performance reasons.

You probably don't need this package if:
* Mostly do I/O by writing strings or raw arrays e.g. to log files,
* Read/write specific formats like JSON, in which case you should use a package specific to that format.

The major design goals of this package are:
1. High performance. The abstractions of this package should be roughly on par with manual implementations using pointer operations and `reinterpret`. Users should rarely be discouraged from using Inscription abstractions due to performance.
2. Present a hard-to-misuse API. Inscription APIs avoid making important behaviour implicit, such as platform endianness, platform-dependent struct padding, or performance traps due to slow fallback definitions. It attempts to guide users away from bugs.

Explicit **non**-goals of this package are:
1. A simple API. This package prefers semantically consistent, precise, efficient, and hard-to-misuse APIs over easy APIs.
2. Reading/writing any type automatically via introspection, like Serialization.jl does.
3. Reading/writing nested types like nested dicts, common in e.g. JSON, TOML and BSON formats.
4. Support for any specific format like JSON or CSV. Instead, this package is for generic I/O of individual values, and can be used to implement formats.

## Example
```julia
# Explicitly opt-into little endian encodings/decodings
using BufferIO, Inscription.Little

data = UInt8.('a':'z')
u16s = zeros(UInt16, 50)

# Load from an AbstractBufReader:
rdr = CursorReader(data)
u32 = load(rdr, UInt32) # one value
(n_u16s_loaded, _) = load_all!(rdr, u16s) # many values

# Or, load from an array
u32 = decode(data, UInt32)

# Store into a writer
wtr = VecWriter()
store(wtr, u32)

# Store into a byte array
n_u16s_written = encode_all!(data, view(u16s, 1:n_u16s_loaded))
```

## Comparison to other packages
* **JSON.jl / TOML/jl / BSON/jl**: Inscription.jl is lower level, in that it attempts only to read/write individual values. Inscription.jl would typically be used to implement binary formats like BSON or BAM.
* **BufferIO.jl**: models I/O via buffers of bytes (`UInt8`), and is more low level. Inscription.jl builds on, and depends on BufferIO.jl, and extends an analogous model of I/O for non-`UInt8` types
* **Serialization.jl** specifies a specific format, whereas Inscription.jl is format agnostic. Also, Serialization.jl works with any Julia type, whereas reading/writing must be implemented per type in Inscription.jl's abstractions.

## Contributing
We appreciate contributions from users including reporting bugs, fixing
issues, improving performance and adding new features.

See the [contributing files](https://github.com/BioJulia/Contributing) for detailed
contributor and maintainer guidelines and the code of conduct.

## Questions?
If you have a question about contributing or using BioJulia software,
join us on [the Julia Slack workspace](https://julialang.org/slack/), or visit the
[Bio category on Julia Discourse](https://discourse.julialang.org/c/domain/bio).
