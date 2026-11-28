# Types whose encodings have no maximal size

# Terminated by a NUL byte. `NUL_READS` counts the bytes its codec looks at.
struct NulTerminated
    s::String
end
const NUL_READS = Ref(0)

# Prefixed by its length
struct LengthPrefixed
    s::String
end

# A struct with a string between bounded fields, by proxy to a tuple
struct Entry
    id::UInt32
    name::LengthPrefixed
    alias::NulTerminated
    flag::Bool
end
const EntryTuple = Tuple{UInt32, LengthPrefixed, NulTerminated, Bool}
Inscription.codec_scheme(::Type{Entry}, ::Endianness) = Proxy{EntryTuple}()
Inscription.try_to_proxy(x::Entry, ::Endianness) = (x.id, x.name, x.alias, x.flag)
function Inscription.try_from_proxy(::Type{Entry}, t::EntryTuple, ::Endianness)
    return iszero(t[1]) ? Invalid() : Entry(t...)
end

# Recursive: a list, where each node is prefixed by whether it has a next node
struct Node
    x::UInt16
    next::Union{Node, Nothing}
end

for E in (LittleEndian, BigEndian)
    @eval begin
        Inscription.codec_max_encoded_size(::Type{NulTerminated}, ::$E) = Unbounded()
        function Inscription.codec_try_decode(input::DecodeInput, ::Type{NulTerminated}, ::$E)
            n = 0
            while true
                # At the end of the input, the terminator is missing
                byte = @? peek_byte(input, n + 1)
                NUL_READS[] += 1
                byte === nothing && return @? require_bytes(input, n + 1)
                byte == 0x00 && break
                n += 1
            end
            return (NulTerminated(String(@? require_bytes(input, n))), n + 1)
        end
        function Inscription.codec_try_encode!(output::EncodeOutput, x::NulTerminated, ::$E)
            '\0' in x.s && return Invalid()
            n = ncodeunits(x.s)
            mem = @? reserve_bytes(output, n + 1)
            copyto!(mem, 1, codeunits(x.s), 1, n)
            mem[n + 1] = 0x00
            return n + 1
        end

        Inscription.codec_max_encoded_size(::Type{LengthPrefixed}, ::$E) = Unbounded()
        function Inscription.codec_try_decode(input::DecodeInput, ::Type{LengthPrefixed}, e::$E)
            (len, n, rest) = @? decode_field(input, UInt64, e)
            bytes = @? require_bytes(rest, len)
            return (LengthPrefixed(String(bytes)), n + length(bytes))
        end
        function Inscription.codec_try_encode!(output::EncodeOutput, x::LengthPrefixed, e::$E)
            len = ncodeunits(x.s)
            (n, rest) = @? encode_field(output, UInt64(len), e)
            mem = @? reserve_bytes(rest, len)
            copyto!(mem, 1, codeunits(x.s), 1, len)
            return n + len
        end

        Inscription.codec_max_encoded_size(::Type{Node}, ::$E) = Unbounded()
        function Inscription.codec_try_decode(input::DecodeInput, ::Type{Node}, e::$E)
            ((x, more), n, rest) = @? decode_field(input, Tuple{UInt16, Bool}, e)
            more || return (Node(x, nothing), n)
            (next, m, _) = @? decode_field(rest, Node, e)
            return (Node(x, next), n + m)
        end
        function Inscription.codec_try_encode!(output::EncodeOutput, x::Node, e::$E)
            (n, rest) = @? encode_field(output, (x.x, x.next !== nothing), e)
            x.next === nothing && return n
            (m, _) = @? encode_field(rest, x.next, e)
            return n + m
        end
    end
end

Base.:(==)(a::Node, b::Node) = a.x == b.x && a.next == b.next

const UNBOUNDED_VALUES = (
    [NulTerminated(""), NulTerminated("hello"), NulTerminated("x"^300)],
    [LengthPrefixed(""), LengthPrefixed("hello\0"), LengthPrefixed("y"^300)],
    [(0x01020304, LengthPrefixed("ab"), true), (0x00000000, LengthPrefixed(""), false)],
    [(NulTerminated("a"), NulTerminated("b")), (NulTerminated(""), NulTerminated("cde"))],
    [
        Entry(0x00000001, LengthPrefixed("ab"), NulTerminated("c"), true),
        Entry(0x00000002, LengthPrefixed(""), NulTerminated(""), false),
    ],
    [Node(0x0001, nothing), Node(0x0002, Node(0x0003, Node(0x0004, nothing)))],
)

# Encode with growing memory
function encode_unbounded(x, e)
    io = VecWriter()
    n = store(io, x, e)
    @test n == length(io.vec)
    return collect(io.vec)
end

single_bytes(bytes) = ChunkedReader([[b] for b in bytes])
readers_of(bytes) = (
    CursorReader(bytes), single_bytes(bytes), BufReader(IOBuffer(bytes), 3),
    ChunkedReader([bytes[i:min(i + 4, end)] for i in 1:5:length(bytes)]),
    BufferIO.expandable(BoundedReader(bytes, 2)), BoundedReader(bytes, length(bytes) + 1),
)

@testset "Unbounded: max_encoded_size" begin
    for T in (NulTerminated, Entry, EntryTuple, Node, Tuple{Tuple{UInt8, Node}, UInt8})
        @test (@inferred max_encoded_size(T, LittleEndian())) === Unbounded()
    end
    @test Little.max_encoded_size(Entry) === Unbounded()
    @test (@inferred max_encoded_size(Tuple{UInt8, UInt32}, LittleEndian())) === 5
end

@testset "Unbounded: $(eltype(xs)), $(nameof(typeof(e)))" for xs in UNBOUNDED_VALUES, e in (LittleEndian(), BigEndian())
    T = eltype(xs)
    all_bytes = reduce(vcat, [encode_unbounded(x, e) for x in xs])
    for x in xs
        bytes = encode_unbounded(x, e)
        len = length(bytes)
        # Memory
        @test decode(bytes, T, e) == x
        @test decode_next([0xff; bytes; 0xff], 2, T, e) == (x, len + 2)
        @test decode_exact(bytes, T, e) == x
        @test is_err(try_decode_exact([bytes; 0xff], T, e), TrailingData)
        for k in 0:(len - 1)
            @test is_err(try_decode(bytes[1:k], T, e), k == 0 ? EndOfInput : Truncated)
            @test try_encode!(zeros(UInt8, k), x, e) == EncodeError(InsufficientSpace)
            @test_throws LightBoundsError encode!(zeros(UInt8, k), x, e)
        end
        out = fill(0xee, len + 2)
        @test encode!(out, 2, x, e) == len
        @test out == [0xee; bytes; 0xee]
        # Readers
        for io in readers_of([bytes; 0x77])
            @test load(io, T, e) == x
            @test read(io) == [0x77]
        end
        for io in readers_of([bytes; 0x77])
            io isa BoundedReader && continue
            @test load_exact(io, len, T, e) == x
            @test read(io) == [0x77]
        end
        # Truncated data consumes nothing
        for k in 0:min(len - 1, 40), io in readers_of(bytes[1:k])
            @test is_err(try_load(io, T, e), k == 0 ? EndOfInput : Truncated)
            @test is_err(try_load(io, T, e), k == 0 ? EndOfInput : Truncated)
            @test read(io) == bytes[1:k]
        end
        # A reader whose buffer is too small throws, and consumes nothing
        if len > 2
            io = BoundedReader(bytes, 2)
            @test_throws IOError load(io, T, e)
            @test first(get_buffer(io)) == first(bytes)
        end
        # A bounded writer that has just enough room
        data = UInt8[]
        io = BoundedWriter(data, len)
        @test store(io, x, e) == len
        len > 1 && @test_throws IOError store(BoundedWriter(UInt8[], len - 1), x, e)
        io = BufWriter(IOBuffer(), 2)
        @test store(io, x, e) == len
    end
    # Bulk
    dst = similar(xs)
    @test decode_every!(dst, all_bytes, e) == length(all_bytes) && dst == xs
    @test decode_all!(similar(xs), all_bytes[1:(end - 1)], e) ==
        (length(xs) - 1, length(all_bytes) - length(encode_unbounded(last(xs), e)))
    out = similar(all_bytes)
    @test encode_every!(out, xs, e) == length(out) && out == all_bytes
    for f in (load_every!, load_all!), io in readers_of(all_bytes)
        dst = similar(xs)
        n = f(io, dst, e)
        @test n == (f === load_every! ? length(all_bytes) : (length(xs), length(all_bytes)))
        @test dst == xs && eof(io)
    end
    for io in readers_of(all_bytes[1:(end - 1)])
        @test_error DecodeError(Truncated) load_every!(io, similar(xs), e)
    end
    for io in (VecWriter(), VecWriter(undef, 1), VecWriter(undef, 20))
        @test store_every(io, xs, e) == length(all_bytes)
        @test io.vec == all_bytes
    end
    io = VecWriter()
    @test store_all(io, xs, e) == (length(xs), length(all_bytes)) && io.vec == all_bytes
end

@testset "Unbounded: invalid values" begin
    e = LittleEndian()
    # All-or-nothing also if a proxy is rejected after its bytes were buffered
    bytes = encode_unbounded((0x00000000, LengthPrefixed("ab"), NulTerminated("c"), true), e)
    for io in readers_of(bytes)
        @test is_err(try_load(io, Entry, e), InvalidData)
        @test load_all!(io, Vector{Entry}(undef, 2), e) == (0, 0)
        @test_error DecodeError(InvalidData) load_every!(io, Vector{Entry}(undef, 1), e)
        @test read(io) == bytes
    end
    io = VecWriter()
    bad = (UInt8(1), NulTerminated("a\0b"))
    @test try_store(io, bad, e) == EncodeError(InvalidValue)
    @test store_all(io, [(UInt8(1), NulTerminated("a")), bad], e) == (1, 3)
    @test io.vec == [0x01, UInt8('a'), 0x00]
    # Corrupt lengths neither throw nor allocate in proportion to the length
    for len in (typemax(UInt64), UInt64(typemax(Int)), UInt64(1) << 40)
        bytes = [reinterpret(UInt8, [htol(len)]); 0x01]
        @test is_err(try_decode(bytes, LengthPrefixed, e), Truncated)
        T = Tuple{UInt8, LengthPrefixed}
        for io in (CursorReader([0x01; bytes]), BufReader(IOBuffer([0x01; bytes])))
            @test is_err(try_load(io, T, e), Truncated)
            @test (@allocated try_load(io, T, e)) < 10^6
        end
    end
end

# A reader that gives at most `k` bytes per fill, and counts them
mutable struct Trickle <: IO
    const data::Vector{UInt8}
    pos::Int
    const k::Int
end
Base.eof(t::Trickle) = t.pos > length(t.data)
function Base.readbytes!(t::Trickle, dst::MutableMemoryView{UInt8}, nb::Integer = length(dst))
    n = min(t.k, nb, length(dst), length(t.data) - t.pos + 1)
    copyto!(dst, 1, t.data, t.pos, n)
    t.pos += n
    return n
end

@testset "Unbounded: linear, and waits for no more than needed" begin
    e = LittleEndian()
    xs = [NulTerminated("a"^1000) for _ in 1:20]
    bytes = reduce(vcat, [encode_unbounded(x, e) for x in xs])
    for k in (1, 7, 512)
        NUL_READS[] = 0
        @test load(BufReader(Trickle(bytes, 1, k)), NulTerminated, e) == xs[1]
        @test NUL_READS[] == 1001
        NUL_READS[] = 0
        dst = similar(xs)
        load_every!(BufReader(Trickle(bytes, 1, k)), dst, e)
        @test dst == xs
        @test NUL_READS[] ≤ 2 * length(bytes)
    end
    # Reading byte by byte, no byte after the encoding is read
    trickle = Trickle([bytes; 0x01], 1, 1)
    load(BufReader(trickle), NulTerminated, e)
    @test trickle.pos == 1002
    bytes = encode_unbounded(LengthPrefixed("abc"), e)
    trickle = Trickle([bytes; bytes], 1, 1)
    load(BufReader(trickle), LengthPrefixed, e)
    @test trickle.pos == length(bytes) + 1
end

# Keeps a view across reads that reach no further than an earlier read, which must not
# invalidate it, see `DecodeInput`
struct KeepsView <: Encoding end
Inscription.codec_max_encoded_size(::Type{Vector{UInt8}}, ::KeepsView) = Unbounded()
function Inscription.codec_try_decode(input::DecodeInput, ::Type{Vector{UInt8}}, ::KeepsView)
    (len, n, rest) = @? decode_field(input, UInt8, BigEndian())
    view = @? require_bytes(rest, 4 + Int(len))
    @? require_bytes(input, 3)
    @? peek_byte(rest, 4 + Int(len))
    (x, _, rest2) = @? decode_field(rest, UInt16, BigEndian())
    @? decode_field(rest2, Tuple{UInt8, Bool}, BigEndian())
    x == UInt16(view[1]) << 8 | view[2] || return Invalid()
    return (collect(view), n + length(view))
end

@testset "Unbounded: valid views" begin
    bytes = [0x03; 0x01:0x03; 0x01; 0x05:0x07]
    for io in readers_of(bytes)
        @test load(io, Vector{UInt8}, KeepsView()) == bytes[2:end]
    end
    @test decode(bytes, Vector{UInt8}, KeepsView()) == bytes[2:end]
end

# Refilling the buffer doesn't allocate. Before Julia 1.14, `get_nonempty_buffer` does.
if VERSION ≥ v"1.14.0-"
    function load_until_error(io, ::Type{T}, e) where {T}
        n = 0
        while !(try_load(io, T, e) isa DecodeError)
            n += 1
        end
        return n
    end
    refill_allocs(io, ::Type{T}, e) where {T} = @allocated load_until_error(io, T, e)
    bulk_allocs(io, dst, e) = @allocated load_all!(io, dst, e)
    @testset "Refilling doesn't allocate" begin
        bytes = collect(codeunits("aé€x"^1000))
        for (T, e) in ((Char, UTF8()), (UInt32, BigEndian()), (Tuple{UInt8, UInt32}, LittleEndian()))
            refill_allocs(BufReader(IOBuffer(bytes), 16), T, e)
            @test_allocs refill_allocs(BufReader(IOBuffer(bytes), 16), T, e) ≤ 64
        end
        dst = Vector{Char}(undef, 4000)
        bulk_allocs(BufReader(IOBuffer(bytes), 16), dst, UTF8())
        @test_allocs bulk_allocs(BufReader(IOBuffer(bytes), 16), dst, UTF8()) ≤ 64
    end
end
