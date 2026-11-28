const BITS_TYPES = (
    Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Float16, Float32, Float64,
)

bytes_le(x) = collect(reinterpret(UInt8, [htol(x)]))
bytes_be(x) = collect(reinterpret(UInt8, [hton(x)]))

is_err(x, kind) = x isa DecodeError && x.kind === kind

# Allocation freedom is only a goal from Julia 1.14, which, among other things, no
# longer boxes un-inlined `Union` return values with pointerful members. On earlier
# versions, allocation tests are recorded as skipped instead of run.
const TEST_ALLOCATIONS = VERSION >= v"1.14-"

macro test_allocs(ex)
    test = TEST_ALLOCATIONS ? Symbol("@test") : Symbol("@test_skip")
    return Expr(:macrocall, test, __source__, esc(ex))
end

# Like `@test_throws err expr`, but compares the error with `==`, which ignores the type
# of the payloads of a `DecodeError` or `EncodeError`, so `DecodeError(EndOfInput)` is
# the error of any type
macro test_error(err, expr)
    return :(@test thrown_error(() -> $(esc(expr))) == $(esc(err)))
end

thrown_error(f) =
try
    f()
    nothing
catch e
    e
end

# Scratch memory to encode into, long enough for any value in these tests
const SCRATCH = MemoryView(zeros(UInt8, 64))

# Decode a T from the start of `mem`, and return it with the number of bytes used, or the
# error. Also check that `try_decode` and `try_decode_next` agree.
function try_decode_n(mem, ::Type{T}, e) where {T}
    r = try_decode_next(mem, 1, T, e)
    x = r isa DecodeError ? r : r[1]
    @test isequal(try_decode(mem, T, e), x)
    return r isa DecodeError ? r : (r[1], r[2] - 1)
end

@enum Fruit::UInt16 apple = 1 banana = 0x0203 cherry = 0xffff
@enum Small::UInt8 tiny = 3 wee = 200
# Contiguous enums are checked with a range check
@enum Signs::Int16 negative = -1 positive = 1 neutral = 0
@eval @enum Full8::Int8 $([:($(Symbol(:full, i + 128)) = $i) for i in -128:127]...)

# Primitive types of odd sizes. Since Julia 1.14, their size in memory is rounded up to a
# power of two bytes, but they are encoded in the bytes their bits need.
primitive type U24 24 end
Inscription.codec_scheme(::Type{U24}, ::Endianness) = BitsLoadable()
primitive type U144 144 end
Inscription.codec_scheme(::Type{U144}, ::Endianness) = BitsLoadable()
# The top bit must be zero
primitive type S24 24 end
Inscription.codec_scheme(::Type{S24}, ::Endianness) = BitsStorable()
Inscription.validate_bits(::Type{S24}, bytes::NTuple{3, UInt8}) = as_unsigned(bytes) < 0x00800000 ? nothing : Invalid()
# Wider than the largest unsigned integer. The top bit must be zero.
primitive type S144 144 end
Inscription.codec_scheme(::Type{S144}, ::Endianness) = BitsStorable()
function Inscription.validate_bits(::Type{S144}, bytes::NTuple{18, UInt8})
    top = NATIVE_ENDIAN === LittleEndian() ? bytes[18] : bytes[1]
    return top < 0x80 ? nothing : Invalid()
end
# BitsStorable, but doesn't implement `validate_bits`
primitive type NoCheck16 16 end
Inscription.codec_scheme(::Type{NoCheck16}, ::Endianness) = BitsStorable()

# The trait can't be declared for types that are neither primitive types nor isbits structs
struct Boxed
    x::Vector{UInt8}
end
Inscription.codec_scheme(::Type{Boxed}, ::Endianness) = BitsLoadable()

# The low 128 bits of a primitive value, as an integer
function low_bits(x::T) where {T}
    n = 8 * sizeof(T)
    isdefined(Base, :bitsizeof) && (n = Base.bitsizeof(T))
    return if n == 128
        Core.Intrinsics.bitcast(UInt128, x)
    elseif n < 128
        Core.Intrinsics.zext_int(UInt128, x)
    else
        Core.Intrinsics.trunc_int(UInt128, x)
    end
end

# Julia accepts bit widths that are not a multiple of 8 since 1.14.
const HAS_NARROW = VERSION ≥ v"1.14.0-"
if HAS_NARROW
    @eval begin
        # Bit widths that are not a multiple of 8 can't be encoded as their bits with a
        # byte order, since that would need padding bits
        primitive type U22 22 end
        Inscription.codec_scheme(::Type{U22}, ::Endianness) = BitsLoadable()
        primitive type U5 5 end
        Inscription.codec_scheme(::Type{U5}, ::Endianness) = BitsLoadable()
        primitive type U30 30 end
        Inscription.codec_scheme(::Type{U30}, ::Endianness) = BitsLoadable()
        primitive type S12 12 end
        Inscription.codec_scheme(::Type{S12}, ::Endianness) = BitsStorable()
        Inscription.validate_bits(::Type{S12}, bytes::NTuple{2, UInt8}) = nothing

        # The design's example of a hand-written codec for a narrow type
        primitive type U29 29 end
        U29(x::UInt32) = Core.Intrinsics.trunc_int(U29, x)
        Base.UInt32(x::U29) = Core.Intrinsics.zext_int(UInt32, x)
    end
    # Codecs are defined for concrete encoding types only, so one per byte order
    for E in (LittleEndian, BigEndian)
        @eval begin
            Inscription.codec_max_encoded_size(::Type{U29}, ::$E) = Val(4)
            function Inscription.codec_try_decode(input::DecodeInput, ::Type{U29}, e::$E)
                (raw, n, _) = @? decode_field(input, UInt32, e)
                raw > 0x1fffffff && return Invalid()
                return (U29(raw), n)
            end
            function Inscription.codec_try_encode!(output::EncodeOutput, x::U29, e::$E)
                (n, _) = @? encode_field(output, UInt32(x), e)
                return n
            end
        end
    end
end

# A custom encoding defined by a format package
struct CBool <: Encoding end
Inscription.codec_max_encoded_size(::Type{Bool}, ::CBool) = Val(1)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{Bool}, ::CBool)
    b = @? require_bytes(input, 1)
    return (!iszero(b[1]), 1)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::Bool, ::CBool)
    mem = @? reserve_bytes(output, 1)
    mem[1] = x
    return 1
end

# A codec that reports whether its own `@boundscheck` blocks ran. `@inbounds` at the call
# of `try_decode` or `encode!` must not reach into the codec.
struct Probe <: Encoding end
Inscription.codec_max_encoded_size(::Type{Bool}, ::Probe) = Val(1)
@inline function Inscription.codec_try_decode(input::DecodeInput, ::Type{Bool}, ::Probe)
    @? require_bytes(input, 1)
    checked = false
    @boundscheck checked = true
    return (checked, 1)
end
@inline function Inscription.codec_try_encode!(output::EncodeOutput, ::Bool, ::Probe)
    mem = @? reserve_bytes(output, 1)
    checked = false
    @boundscheck checked = true
    mem[1] = checked
    return 1
end

# An impure codec, which fails every other call. Bulk functions that throw must retry the
# element that failed, and use it if the retry succeeds.
struct Flaky <: Encoding end
const FLAKY_CALLS = Ref(0)
flaky_fails() = isodd(FLAKY_CALLS[] += 1)
Inscription.codec_max_encoded_size(::Type{Int8}, ::Flaky) = Val(1)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{Int8}, ::Flaky)
    b = @? require_bytes(input, 1)
    flaky_fails() && return Invalid()
    return (b[1] % Int8, 1)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::Int8, ::Flaky)
    mem = @? reserve_bytes(output, 1)
    flaky_fails() && return Invalid()
    mem[1] = x % UInt8
    return 1
end

# A codec that breaks its contract, by returning byte counts out of range
struct Liar <: Encoding end
Inscription.codec_max_encoded_size(::Type{<:Union{Int8, Int16, Int64, UInt8, UInt16}}, ::Liar) = Val(2)
# More bytes than the input has, which ends after `max_encoded_size` bytes
Inscription.codec_try_decode(::DecodeInput, ::Type{Int8}, ::Liar) = (Int8(0), 3)
Inscription.codec_try_encode!(output::EncodeOutput, ::Int8, ::Liar) = length(output.mem) + 1
# A negative count
Inscription.codec_try_decode(::DecodeInput, ::Type{Int16}, ::Liar) = (Int16(0), -1)
Inscription.codec_try_encode!(::EncodeOutput, ::Int16, ::Liar) = -1
# Zero, which would make loops until the end of the data never end
Inscription.codec_try_decode(::DecodeInput, ::Type{Int64}, ::Liar) = (Int64(0), 0)
Inscription.codec_try_encode!(::EncodeOutput, ::Int64, ::Liar) = 0
# More bytes than `max_encoded_size`. The input and output end after `max_encoded_size`
# bytes, so this is caught.
Inscription.codec_try_decode(::DecodeInput, ::Type{UInt8}, ::Liar) = (0x00, 3)
Inscription.codec_try_encode!(::EncodeOutput, ::UInt8, ::Liar) = 3
# More bytes than the input or output has, on the slow path, where it is shorter than
# `max_encoded_size`
Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt16}, ::Liar) = (0x0000, length(input.mem) + 1)
Inscription.codec_try_encode!(output::EncodeOutput, ::UInt16, ::Liar) = length(output.mem) + 1
Inscription.codec_max_encoded_size(::Type{Int32}, ::Liar) = 4

# Decimal digits of a `UInt8`, without a terminator. The value is decided by the byte
# after its last digit, or by 3 digits.
struct Decimal <: Encoding end
Inscription.codec_max_encoded_size(::Type{UInt8}, ::Decimal) = Val(3)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Decimal)
    @? require_bytes(input, 1)
    value = 0
    n = 0
    while n < 3
        byte = @? peek_byte(input, n + 1)
        (byte === nothing || !(UInt8('0') ≤ byte ≤ UInt8('9'))) && break
        value = 10 * value + (byte - UInt8('0'))
        n += 1
    end
    (n == 0 || value > 255) && return Invalid()
    return (UInt8(value), n)
end

# A length byte, followed by that many bytes, each 0x01. Decodes to the length. Counts its
# calls, to check that a reader buffers the bytes it asks for at once.
struct Prefixed <: Encoding end
const PREFIXED_CALLS = Ref(0)
Inscription.codec_max_encoded_size(::Type{UInt64}, ::Prefixed) = Val(256)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt64}, ::Prefixed)
    PREFIXED_CALLS[] += 1
    k = Int((@? require_bytes(input, 1))[1])
    bytes = @? require_bytes(input, 1 + k)
    all(==(0x01), bytes[2:end]) || return Invalid()
    return (UInt64(k), 1 + k)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::UInt64, ::Prefixed)
    x ≤ 255 || return Invalid()
    mem = @? reserve_bytes(output, 1 + Int(x))
    mem[1] = x % UInt8
    fill!(mem[2:end], 0x01)
    return 1 + Int(x)
end

# Asks for more bytes than its `max_encoded_size`, which it never gets
struct Greedy <: Encoding end
Inscription.codec_max_encoded_size(::Type{UInt8}, ::Greedy) = Val(2)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Greedy)
    b = @? require_bytes(input, 3)
    return (b[3], 3)
end
function Inscription.codec_try_encode!(output::EncodeOutput, ::UInt8, ::Greedy)
    @? reserve_bytes(output, 3)
    return Invalid()
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::UInt8, ::Decimal)
    s = string(x)
    mem = @? reserve_bytes(output, ncodeunits(s))
    copyto!(mem, codeunits(s))
    return ncodeunits(s)
end

# An 8-bit character set, which can't encode most `Char`s
struct Latin1 <: Encoding end
is_latin1(c::Char) = isvalid(c) && codepoint(c) ≤ 0xff
Inscription.codec_max_encoded_size(::Type{Char}, ::Latin1) = Val(1)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{Char}, ::Latin1)
    b = @? require_bytes(input, 1)
    return (Char(b[1]), 1)
end
function Inscription.codec_try_encode!(output::EncodeOutput, c::Char, ::Latin1)
    is_latin1(c) || return Invalid()
    mem = @? reserve_bytes(output, 1)
    mem[1] = codepoint(c) % UInt8
    return 1
end
# Pairs of characters, encoded one by one, so an invalid second character is only found
# after the first is written
Inscription.codec_max_encoded_size(::Type{Tuple{Char, Char}}, ::Latin1) = Val(2)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{Tuple{Char, Char}}, e::Latin1)
    (a, n, input) = @? decode_field(input, Char, e)
    (b, m, _) = @? decode_field(input, Char, e)
    return ((a, b), n + m)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::Tuple{Char, Char}, e::Latin1)
    (a, output) = @? encode_field(output, x[1], e)
    (b, _) = @? encode_field(output, x[2], e)
    return a + b
end

# Structs that opt in
struct Header
    magic::UInt32
    version::UInt16
    flags::UInt8
    kind::UInt8
end
Inscription.codec_scheme(::Type{Header}, ::Endianness) = BitsLoadable()
struct Nested
    header::Header
    x::Float32
    y::Int16
    z::Int16
end
Inscription.codec_scheme(::Type{Nested}, ::Endianness) = BitsLoadable()
# The fields are checked, and then that the fruit is `apple` unless `on`
struct Flagged
    on::Bool
    other::UInt8
    fruit::Fruit
end
Inscription.codec_scheme(::Type{Flagged}, ::Endianness) = BitsStorable()
function Inscription.validate_bits(::Type{Flagged}, bytes::NTuple{4, UInt8})
    x = reinterpret(Flagged, bytes)
    return x.on || x.fruit === apple ? nothing : Invalid()
end
struct Outer
    a::Flagged
    b::Flagged
end
Inscription.codec_scheme(::Type{Outer}, ::Endianness) = BitsStorable()
Inscription.validate_bits(::Type{Outer}, ::NTuple{8, UInt8}) = nothing
# Types of size zero are rejected, also as fields
struct Empty end
Inscription.codec_scheme(::Type{Empty}, ::Endianness) = BitsLoadable()
struct WithEmpty
    a::UInt32
    e::Empty
end
Inscription.codec_scheme(::Type{WithEmpty}, ::Endianness) = BitsLoadable()

# Structs that can't be bits types
struct Padded
    a::UInt8
    b::UInt32
end
Inscription.codec_scheme(::Type{Padded}, ::Endianness) = BitsLoadable()
struct LoadableWithBool
    a::Bool
end
Inscription.codec_scheme(::Type{LoadableWithBool}, ::Endianness) = BitsLoadable()
struct WithChar
    c::Char
end
Inscription.codec_scheme(::Type{WithChar}, ::Endianness) = BitsLoadable()
# Doesn't opt in
struct Plain
    x::UInt32
end
struct WithPlain
    p::Plain
end
Inscription.codec_scheme(::Type{WithPlain}, ::Endianness) = BitsLoadable()
struct WithPadded
    p::Padded
end
Inscription.codec_scheme(::Type{WithPadded}, ::Endianness) = BitsLoadable()
# Has padding on some platforms only: `b` follows 4 bytes, and is aligned to 8 on x86-64
struct Misaligned
    a::UInt32
    b::UInt64
end
Inscription.codec_scheme(::Type{Misaligned}, ::Endianness) = BitsLoadable()
# Its size, 12, is not a multiple of 8
struct TrailingPadding
    a::UInt64
    b::UInt32
end
Inscription.codec_scheme(::Type{TrailingPadding}, ::Endianness) = BitsLoadable()
# `h` follows 2 bytes, but contains a `UInt32`
struct MisalignedNested
    a::UInt16
    h::Header
end
Inscription.codec_scheme(::Type{MisalignedNested}, ::Endianness) = BitsLoadable()
# No padding on x86-64, where `U256` is aligned to 16 bytes, but a platform could align it
# to 32 bytes, its size
primitive type U256 256 end
Inscription.codec_scheme(::Type{U256}, ::Endianness) = BitsLoadable()
struct WithU256
    a::UInt128
    b::U256
end
Inscription.codec_scheme(::Type{WithU256}, ::Endianness) = BitsLoadable()
# Widths that are not powers of two are rejected on every Julia version, also where the
# bits of a `U24` fill its 3 bytes
struct WithU24
    x::U24
end
Inscription.codec_scheme(::Type{WithU24}, ::Endianness) = BitsLoadable()
# Accepted: ordered from largest to smallest, or with a field for the padding
struct Ordered
    b::UInt64
    a::UInt32
    c::UInt16
    d::UInt8
    e::UInt8
end
Inscription.codec_scheme(::Type{Ordered}, ::Endianness) = BitsLoadable()
struct ExplicitPadding
    a::UInt32
    pad::UInt32
    b::UInt64
end
Inscription.codec_scheme(::Type{ExplicitPadding}, ::Endianness) = BitsLoadable()
struct WithU256Aligned
    b::U256
    a::UInt128
    c::UInt128
end
Inscription.codec_scheme(::Type{WithU256Aligned}, ::Endianness) = BitsLoadable()

# An even byte, with a hand-written codec for the byte orders, which rejects odd bytes
# both ways
struct Even
    x::UInt8
end
for E in (LittleEndian, BigEndian)
    @eval begin
        Inscription.codec_max_encoded_size(::Type{Even}, ::$E) = Val(1)
        function Inscription.codec_try_decode(input::DecodeInput, ::Type{Even}, ::$E)
            b = @? require_bytes(input, 1)
            return iseven(b[1]) ? (Even(b[1]), 1) : Invalid()
        end
        function Inscription.codec_try_encode!(output::EncodeOutput, x::Even, ::$E)
            iseven(x.x) || return Invalid()
            mem = @? reserve_bytes(output, 1)
            mem[1] = x.x
            return 1
        end
    end
end

# A struct with a tuple field
struct WithTuple
    t::NTuple{2, UInt16}
    x::UInt32
end
Inscription.codec_scheme(::Type{WithTuple}, ::Endianness) = BitsLoadable()

# Proxied types
# Valid only if `lo ≤ hi`, encoded as a tuple
struct Span
    lo::UInt16
    hi::UInt16
end
Inscription.codec_scheme(::Type{Span}, ::Endianness) = Proxy{NTuple{2, UInt16}}()
Inscription.try_to_proxy(x::Span, ::Endianness) = (x.lo, x.hi)
function Inscription.try_from_proxy(::Type{Span}, (lo, hi)::NTuple{2, UInt16}, ::Endianness)
    return lo ≤ hi ? Span(lo, hi) : Invalid()
end
# Has padding in memory, but not in its encoding
struct Sparse
    a::UInt8
    b::UInt32
end
Inscription.codec_scheme(::Type{Sparse}, ::Endianness) = Proxy{Tuple{UInt8, UInt32}}()
Inscription.try_to_proxy(x::Sparse, ::Endianness) = (x.a, x.b)
Inscription.try_from_proxy(::Type{Sparse}, (a, b)::Tuple{UInt8, UInt32}, ::Endianness) = Sparse(a, b)
# Encodings of varying size, with an encoding other than the byte orders
struct Glyph
    c::Char
end
Inscription.codec_scheme(::Type{Glyph}, ::UTF8) = Proxy{Char}()
Inscription.try_to_proxy(x::Glyph, ::UTF8) = x.c
Inscription.try_from_proxy(::Type{Glyph}, c::Char, ::UTF8) = Glyph(c)
# A proxy of a proxied type
struct Nest
    s::Span
end
Inscription.codec_scheme(::Type{Nest}, ::Endianness) = Proxy{Span}()
Inscription.try_to_proxy(x::Nest, ::Endianness) = x.s
Inscription.try_from_proxy(::Type{Nest}, s::Span, ::Endianness) = Nest(s)
# A proxy for every encoding, which works for the encodings of the proxy
struct Wrapped
    c::Char
end
Inscription.codec_scheme(::Type{Wrapped}, ::Encoding) = Proxy{Char}()
Inscription.try_to_proxy(x::Wrapped, ::Encoding) = x.c
Inscription.try_from_proxy(::Type{Wrapped}, c::Char, ::Encoding) = Wrapped(c)
# Only values that fit in the proxy can be encoded
struct Narrow
    x::Int
end
Inscription.codec_scheme(::Type{Narrow}, ::Endianness) = Proxy{UInt16}()
function Inscription.try_to_proxy(x::Narrow, ::Endianness)
    return 0 ≤ x.x ≤ typemax(UInt16) ? x.x % UInt16 : Invalid()
end
Inscription.try_from_proxy(::Type{Narrow}, x::UInt16, ::Endianness) = Narrow(Int(x))
# A proxy of a type that can't always be encoded
struct NestNarrow
    x::Narrow
end
Inscription.codec_scheme(::Type{NestNarrow}, ::Endianness) = Proxy{Narrow}()
Inscription.try_to_proxy(x::NestNarrow, ::Endianness) = x.x
Inscription.try_from_proxy(::Type{NestNarrow}, x::Narrow, ::Endianness) = NestNarrow(x)

# Proxies that can't be used
# Return `nothing` instead of `Invalid()`
struct NothingProxy
    x::UInt8
end
Inscription.codec_scheme(::Type{NothingProxy}, ::Endianness) = Proxy{UInt16}()
Inscription.try_to_proxy(::NothingProxy, ::Endianness) = nothing
Inscription.try_from_proxy(::Type{NothingProxy}, ::UInt16, ::Endianness) = nothing
struct AbstractProxied end
Inscription.codec_scheme(::Type{AbstractProxied}, ::Endianness) = Proxy{Integer}()
struct SelfProxied
    x::UInt8
end
Inscription.codec_scheme(::Type{SelfProxied}, ::Endianness) = Proxy{SelfProxied}()
struct NotTypeProxied end
Inscription.codec_scheme(::Type{NotTypeProxied}, ::Endianness) = Proxy{1}()
# `try_to_proxy` returns a `UInt8`, not the proxy type
struct WrongProxy
    x::UInt8
end
Inscription.codec_scheme(::Type{WrongProxy}, ::Endianness) = Proxy{UInt16}()
Inscription.try_to_proxy(x::WrongProxy, ::Endianness) = x.x
Inscription.try_from_proxy(::Type{WrongProxy}, x::UInt16, ::Endianness) = WrongProxy(x % UInt8)
# A field with a proxy is not encoded as its bits
struct WithProxied
    s::Span
end
Inscription.codec_scheme(::Type{WithProxied}, ::Endianness) = BitsLoadable()
# Bits schemes are only for the byte orders
struct BitsEverywhere
    x::UInt8
end
Inscription.codec_scheme(::Type{BitsEverywhere}, ::Encoding) = BitsLoadable()

# Tuples of each kind: bits types, and tuples encoded element by element, because they
# have padding, an element type has a hand-written codec, or is a bits type that can't be
# a field of one
const BITS_TUPLES = (
    NTuple{2, UInt16}, Tuple{Header, UInt64}, Tuple{Tuple{UInt8, UInt8}, UInt16},
    Tuple{Fruit, Bool, Small}, Tuple{Flagged, Int32}, Tuple{UInt8},
)
const ELEMENTWISE_TUPLES = (
    Tuple{UInt8, UInt32}, Tuple{UInt16, UInt8}, Tuple{Bool, UInt32, S24}, Tuple{Even, UInt16},
    Tuple{Tuple{UInt8, UInt32}, Bool}, Tuple{U144, Flagged},
)
if HAS_NARROW
    @eval begin
        struct WithNarrow
            x::U30
        end
        Inscription.codec_scheme(::Type{WithNarrow}, ::Endianness) = BitsLoadable()
    end
end

# A reader of chunks that throws when it runs out, instead of returning EOF. It stands in
# for a socket whose peer waits for a reply: filling more would block forever.
mutable struct StallingReader <: AbstractBufReader
    chunks::Vector{Vector{UInt8}}
    buffer::Vector{UInt8}
end
StallingReader(chunks) = StallingReader(collect(Vector{UInt8}, chunks), UInt8[])
BufferIO.get_buffer(x::StallingReader) = ImmutableMemoryView(x.buffer)
function BufferIO.fill_buffer(x::StallingReader)
    isempty(x.chunks) && error("would block")
    chunk = popfirst!(x.chunks)
    append!(x.buffer, chunk)
    return length(chunk)
end
function BufferIO.consume(x::StallingReader, n::Int)
    in(n, 0:length(x.buffer)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    deleteat!(x.buffer, 1:n)
    return nothing
end
Base.close(::StallingReader) = nothing

# Codecs whose `Invalid`s have payloads
@enum ParseError::UInt8 NoDigits Overflow
@enum Level::UInt8 low high
@enum TaggedError::UInt8 Untagged
@enum RangeError::UInt8 OutOfRange
struct EvenBits
    raw::UInt16
end
struct NotAscii
    c::Char
end

# Up to `ndigits(typemax(T))` decimal digits of an unsigned integer. A codec that fails
# for several reasons, which its payloads tell apart.
struct Digits <: Encoding end
const DIGIT_TYPES = Union{UInt8, UInt16}
# The sizes are literals, since `ndigits` is not constant-folded
max_digits(::Type{UInt8}) = 3
max_digits(::Type{UInt16}) = 5
Inscription.codec_max_encoded_size(::Type{T}, ::Digits) where {T <: DIGIT_TYPES} = Val(max_digits(T))
Inscription.codec_decode_invalid_type(::Type{<:DIGIT_TYPES}, ::Digits) = ParseError
function Inscription.codec_try_decode(input::DecodeInput, ::Type{T}, ::Digits) where {T <: DIGIT_TYPES}
    value = 0
    n = 0
    while n < max_digits(T)
        byte = @? peek_byte(input, n + 1)
        (byte === nothing || !(UInt8('0') ≤ byte ≤ UInt8('9'))) && break
        value = 10 * value + (byte - UInt8('0'))
        n += 1
    end
    n == 0 && return Invalid(NoDigits)
    value > typemax(T) && return Invalid(Overflow)
    return (T(value), n)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::DIGIT_TYPES, ::Digits)
    s = string(x)
    mem = @? reserve_bytes(output, ncodeunits(s))
    copyto!(mem, codeunits(s))
    return ncodeunits(s)
end

# Two numbers, separated by a comma. It passes on the payloads of the numbers, and has
# none for a missing comma.
struct DigitPair
    a::UInt8
    b::UInt8
end
Inscription.codec_max_encoded_size(::Type{DigitPair}, ::Digits) = Val(7)
Inscription.codec_decode_invalid_type(::Type{DigitPair}, ::Digits) = Union{Nothing, ParseError}
function Inscription.codec_try_decode(input::DecodeInput, ::Type{DigitPair}, e::Digits)
    (a, n, input) = @? decode_field(input, UInt8, e)
    (@? peek_byte(input, 1)) === UInt8(',') || return Invalid{Union{Nothing, ParseError}}(nothing)
    (_, _, input) = @? decode_field(input, UInt8, LittleEndian())
    (b, m, _) = @? decode_field(input, UInt8, e)
    return (DigitPair(a, b), n + 1 + m)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::DigitPair, e::Digits)
    (n, output) = @? encode_field(output, x.a, e)
    (_, output) = @? encode_field(output, UInt8(','), LittleEndian())
    (m, _) = @? encode_field(output, x.b, e)
    return n + 1 + m
end

# ASCII characters, with different payload types for decoding and encoding
struct Ascii <: Encoding end
Inscription.codec_max_encoded_size(::Type{Char}, ::Ascii) = Val(1)
Inscription.codec_decode_invalid_type(::Type{Char}, ::Ascii) = UInt8
Inscription.codec_encode_invalid_type(::Type{Char}, ::Ascii) = NotAscii
function Inscription.codec_try_decode(input::DecodeInput, ::Type{Char}, ::Ascii)
    b = (@? require_bytes(input, 1))[1]
    b < 0x80 || return Invalid(b)
    return (Char(b), 1)
end
function Inscription.codec_try_encode!(output::EncodeOutput, c::Char, ::Ascii)
    isascii(c) || return Invalid(NotAscii(c))
    mem = @? reserve_bytes(output, 1)
    mem[1] = codepoint(c) % UInt8
    return 1
end

# A bits type whose low bit must be set
primitive type Odd16 16 end
Odd16(x::UInt16) = reinterpret(Odd16, x)
Inscription.codec_scheme(::Type{Odd16}, ::Endianness) = BitsStorable()
Inscription.codec_decode_invalid_type(::Type{Odd16}, ::Endianness) = EvenBits
function Inscription.validate_bits(::Type{Odd16}, bytes::NTuple{2, UInt8})
    raw = as_unsigned(bytes)
    return isodd(raw) ? nothing : Invalid(EvenBits(raw))
end
# A struct of bits types, which passes on the payloads of its fields. It must be `high`
# if `flag` is set.
struct Tagged
    v::Odd16
    flag::Bool
    level::Level
end
Inscription.codec_scheme(::Type{Tagged}, ::Endianness) = BitsStorable()
Inscription.codec_decode_invalid_type(::Type{Tagged}, ::Endianness) = TaggedError
function Inscription.validate_bits(::Type{Tagged}, bytes::NTuple{4, UInt8})
    x = reinterpret(Tagged, bytes)
    return (!x.flag || x.level === high) ? nothing : Invalid(Untagged)
end
const TAGGED_PAYLOADS = Union{Nothing, EvenBits, TaggedError}
# A proxy, whose own payloads are those of its conversions
struct Bounded
    x::Odd16
end
Inscription.codec_scheme(::Type{Bounded}, ::Endianness) = Proxy{Odd16}()
Inscription.codec_decode_invalid_type(::Type{Bounded}, ::Endianness) = RangeError
Inscription.codec_encode_invalid_type(::Type{Bounded}, ::Endianness) = RangeError
in_bounds(x::Odd16) = reinterpret(UInt16, x) < 0x1000
function Inscription.try_to_proxy(x::Bounded, ::Endianness)
    return in_bounds(x.x) ? x.x : Invalid(OutOfRange)
end
function Inscription.try_from_proxy(::Type{Bounded}, x::Odd16, ::Endianness)
    return in_bounds(x) ? Bounded(x) : Invalid(OutOfRange)
end

# Codecs that break the contract of payloads, by returning payloads of types not declared
struct Undeclared <: Encoding end
Inscription.codec_max_encoded_size(::Type{UInt8}, ::Undeclared) = Val(1)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Undeclared)
    b = (@? require_bytes(input, 1))[1]
    return iszero(b) ? Invalid(:zero) : (b, 1)
end
function Inscription.codec_try_encode!(output::EncodeOutput, x::UInt8, ::Undeclared)
    iszero(x) && return Invalid(:zero)
    (@? reserve_bytes(output, 1))[1] = x
    return 1
end
# Passes on the payloads of a field, without declaring them
Inscription.codec_max_encoded_size(::Type{UInt16}, ::Undeclared) = Val(3)
function Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt16}, ::Undeclared)
    (x, n, _) = @? decode_field(input, UInt8, Digits())
    return (UInt16(x), n)
end
# Declares payloads, but returns `Invalid()`, which is only allowed if they include `Nothing`
struct Bare <: Encoding end
Inscription.codec_max_encoded_size(::Type{UInt8}, ::Bare) = Val(1)
Inscription.codec_decode_invalid_type(::Type{UInt8}, ::Bare) = ParseError
function Inscription.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Bare)
    b = (@? require_bytes(input, 1))[1]
    b == 0xff && return Invalid(Overflow)
    b == 0x00 && return Invalid()
    return (b, 1)
end
# Primitive types whose `validate_bits` returns a payload of the wrong type, or a Bool
primitive type WrongPayload8 8 end
Inscription.codec_scheme(::Type{WrongPayload8}, ::Endianness) = BitsStorable()
Inscription.validate_bits(::Type{WrongPayload8}, bytes::NTuple{1, UInt8}) = iszero(bytes[1]) ? Invalid(1) : nothing
primitive type BoolValidated8 8 end
Inscription.codec_scheme(::Type{BoolValidated8}, ::Endianness) = BitsStorable()
Inscription.validate_bits(::Type{BoolValidated8}, bytes::NTuple{1, UInt8}) = !iszero(bytes[1])

# The bytes `x` encodes to
encoding(x, e) = (buf = zeros(UInt8, max_encoded_size(typeof(x), e)); buf[1:encode!(buf, x, e)])

# A type, an encoding and a value of the type, for each kind of codec. The tests of
# properties that every codec has use these. The byte orders share their codecs, so they
# alternate.
const CODEC_CASES = let
    s24 = decode([0x01, 0x02, 0x03], S24, BigEndian())
    u144 = decode(collect(0x01:0x12), U144, BigEndian())
    cases = Any[
        # Primitive types
        (UInt8, LittleEndian(), 0x2a),
        (UInt32, BigEndian(), 0x01020304),
        (Int128, LittleEndian(), Int128(-12345)),
        (Float16, BigEndian(), Float16(1.5)),
        (Bool, LittleEndian(), true),
        (Fruit, BigEndian(), banana),
        (Signs, LittleEndian(), negative),
        (U24, BigEndian(), decode([0x01, 0x02, 0x83], U24, BigEndian())),
        (S24, LittleEndian(), s24),
        (S144, BigEndian(), decode(collect(0x01:0x12), S144, BigEndian())),
        # Structs
        (Header, LittleEndian(), Header(0x01020304, 0x0506, 0x07, 0x08)),
        (Flagged, BigEndian(), Flagged(true, 0x05, cherry)),
        (Outer, LittleEndian(), Outer(Flagged(true, 0x05, cherry), Flagged(false, 0x07, apple))),
        # Hand-written codecs
        (Even, BigEndian(), Even(0x04)),
        (Bool, CBool(), true),
        (Char, UTF8(), '€'),
        (Char, Latin1(), 'é'),
        (Tuple{Char, Char}, Latin1(), ('a', 'é')),
        # Tuples, which are bits types, or encoded element by element
        (Tuple{Fruit, Bool, Small}, LittleEndian(), (banana, true, wee)),
        (Tuple{Bool, UInt32, S24}, BigEndian(), (true, 0x01020304, s24)),
        (Tuple{U144, Flagged}, LittleEndian(), (u144, Flagged(false, 0x07, apple))),
        (Tuple{Even, UInt16}, BigEndian(), (Even(0x04), 0x0102)),
        # Proxies
        (Span, LittleEndian(), Span(0x0102, 0x0304)),
        (Sparse, BigEndian(), Sparse(0x01, 0x02030405)),
        (Glyph, UTF8(), Glyph('€')),
        (Nest, BigEndian(), Nest(Span(0x0102, 0x0304))),
        (Wrapped, Latin1(), Wrapped('é')),
        (Tuple{Span, UInt8}, LittleEndian(), (Span(0x0001, 0x0002), 0x03)),
        # Codecs with payloads
        (UInt16, Digits(), 0x1234),
        (DigitPair, Digits(), DigitPair(12, 255)),
        (Char, Ascii(), 'a'),
        (Odd16, LittleEndian(), Odd16(0x0123)),
        (Tagged, BigEndian(), Tagged(Odd16(0x0101), true, high)),
        (Tuple{Odd16, Bool, Level}, LittleEndian(), (Odd16(0x0003), false, low)),
        (Tuple{Bool, Odd16}, BigEndian(), (true, Odd16(0x0005))),
        (Bounded, LittleEndian(), Bounded(Odd16(0x0011))),
    ]
    HAS_NARROW && push!(cases, (U29, LittleEndian(), U29(0x01234567)))
    cases
end

# Whether `@inbounds` elides `@boundscheck` blocks. `--check-bounds=yes`, which `Pkg.test`
# uses, keeps them.
const ELIDES_BOUNDSCHECKS = Base.JLOptions().check_bounds != 1
