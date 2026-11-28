@testset "@inbounds" begin
    mem = MemoryView([0x01, 0x02, 0x03, 0x04, 0x05])
    # `@inbounds` only has an effect if the call is inlined, so the functions must
    # specialize on the type.
    decode_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds decode(mem, i, T, e)
    try_decode_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds try_decode(mem, i, T, e)
    next_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds try_decode_next(mem, i, T, e)
    encode_inbounds!(mem, i, x, e) = @inbounds encode!(mem, i, x, e)
    try_encode_inbounds!(mem, i, x, e) = @inbounds try_encode!(mem, i, x, e)
    start_inbounds(mem, ::Type{T}, e) where {T} = @inbounds decode(mem, T, e)
    exact_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds decode_exact(mem, i, T, e)
    little_inbounds(mem, i) = @inbounds Little.decode_next(mem, i, UInt16)

    # In bounds, the results are the same as without `@inbounds`
    for (T, e, _) in CODEC_CASES, i in 1:(length(mem) + 1 - max_encoded_size(T, e))
        @test isequal(try_decode_inbounds(mem, i, T, e), try_decode(mem, i, T, e))
        @test isequal(next_inbounds(mem, i, T, e), try_decode_next(mem, i, T, e))
    end
    @test decode_inbounds(mem, 2, UInt32, BigEndian()) === 0x02030405
    @test start_inbounds(mem, UInt16, BigEndian()) === 0x0102
    @test exact_inbounds(mem, 4, UInt16, BigEndian()) === 0x0405
    # Whether bytes remain is always checked
    @test_error DecodeError(TrailingData) exact_inbounds(mem, 1, UInt16, BigEndian())
    @test little_inbounds(mem, 4) === (0x0504, 6)
    v = zeros(UInt8, 6)
    @test encode_inbounds!(MemoryView(v), 3, 0x01020304, BigEndian()) === 4
    @test v == [0x00, 0x00, 0x01, 0x02, 0x03, 0x04]
    @test try_encode_inbounds!(MemoryView(v), 1, 0x0807, LittleEndian()) === 2
    @test v == [0x07, 0x08, 0x01, 0x02, 0x03, 0x04]

    # The data is still validated
    @test_error DecodeError(InvalidData) decode_inbounds(MemoryView([0x02]), 1, Bool, LittleEndian())
    @test_error DecodeError(InvalidData) decode_inbounds(MemoryView([0x00, 0x00]), 1, Fruit, LittleEndian())
    @test_error DecodeError(InvalidData) decode_inbounds(MemoryView([0x00, 0x00, 0x02, 0x03]), 1, Flagged, BigEndian())
    @test try_decode_inbounds(MemoryView([0x02]), 1, Bool, LittleEndian()) == DecodeError(InvalidData)
    @test try_decode_inbounds(MemoryView([0x00, 0x00]), 1, Fruit, LittleEndian()) == DecodeError(InvalidData)
    @test try_decode_inbounds(MemoryView([0x00, 0x00, 0x02, 0x03]), 1, Flagged, BigEndian()) == DecodeError(InvalidData)

    # The checks of a hand-written codec are its own, and always run
    @test try_decode(MemoryView([0x00]), Bool, Probe()) === true
    @test try_decode_inbounds(MemoryView([0x00]), 1, Bool, Probe()) === true
    v = zeros(UInt8, 1)
    @test encode_inbounds!(MemoryView(v), 1, false, Probe()) === 1
    @test v == [0x01]
    # `store` skips its redundant length check, but not those of a codec
    io = VecWriter()
    @test store(io, false, Probe()) == 1
    @test io.vec == [0x01]

    if ELIDES_BOUNDSCHECKS
        # The length checks of the throwing functions are skipped. This breaks the
        # contract of `@inbounds`, which is only memory-safe here because the views
        # are within a larger memory.
        backing = MemoryView([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        short = backing[3:4]
        @test try_decode(short, 2, UInt32, BigEndian()) == DecodeError(Truncated)
        # The `try_` functions ignore `@inbounds`
        @test try_decode_inbounds(short, 2, UInt32, BigEndian()) == DecodeError(Truncated)
        @test next_inbounds(short, 2, UInt32, BigEndian()) == DecodeError(Truncated)
        @test try_decode_inbounds(short, 3, UInt32, BigEndian()) == DecodeError(EndOfInput)
        @test_throws LightBoundsError try_decode_inbounds(short, 0, UInt32, BigEndian())
        @test try_encode_inbounds!(backing[1:2], 2, 0xaabbccdd, BigEndian()) == EncodeError(InsufficientSpace)
        @test_throws LightBoundsError try_encode_inbounds!(backing[1:2], 4, 0xaabbccdd, BigEndian())
        @test decode_inbounds(short, 3, UInt16, BigEndian()) === 0x0506
        @test start_inbounds(short, UInt32, LittleEndian()) === 0x06050403
        @test little_inbounds(short, 2) === (0x0504, 4)
        @test try_encode!(backing[1:2], 2, 0xaabbccdd, BigEndian()) == EncodeError(InsufficientSpace)
        @test_throws LightBoundsError encode!(backing[1:2], 2, 0xaabbccdd, BigEndian())
        @test encode_inbounds!(backing[1:2], 2, 0xa1b1c1d1, BigEndian()) === 4
        @test collect(backing) == [0x01, 0xa1, 0xb1, 0xc1, 0xd1, 0x06, 0x07, 0x08]
    end
end

@testset "Codec contract checks" begin
    decode_inbounds(mem, ::Type{T}, e) where {T} = @inbounds decode(mem, T, e)
    encode_inbounds!(mem, x, e) = @inbounds encode!(mem, x, e)
    mem = MemoryView(zeros(UInt8, 10))
    for T in (Int8, Int16, Int64, UInt8, UInt16)
        @test_throws ErrorException try_decode(mem, T, Liar())
        @test_throws ErrorException try_decode_next(mem, 1, T, Liar())
        @test_throws ErrorException decode_inbounds(mem, T, Liar())
        @test_throws ErrorException decode_all!(MemoryView(zeros(T, 3)), mem, Liar())
        @test_throws ErrorException try_encode!(mem, zero(T), Liar())
        @test_throws ErrorException encode_inbounds!(mem, zero(T), Liar())
        @test_throws ErrorException encode_all!(mem, MemoryView(zeros(T, 3)), Liar())
        @test_throws ErrorException decode_every!(MemoryView(zeros(T, 3)), mem, Liar())
        @test_throws ErrorException encode_every!(mem, MemoryView(zeros(T, 3)), Liar())
        # Nothing is consumed from the reader or writer
        io = CursorReader(zeros(UInt8, 10))
        @test_throws ErrorException try_load(io, T, Liar())
        @test_throws ErrorException load_into!(io, MemoryView(zeros(T, 3)), Liar())
        @test load_all!(io, MemoryView(zeros(UInt8, 20)), LittleEndian()) == (10, 10)
        io = VecWriter()
        @test_throws ErrorException store(io, zero(T), Liar())
        @test_throws ErrorException store_every(io, MemoryView(zeros(T, 3)), Liar())
        @test_throws ErrorException store_into(io, MemoryView(zeros(T, 3)), Liar())
        @test_throws ErrorException store_all(io, MemoryView(zeros(T, 3)), Liar())
        @test isempty(io.vec)
    end
    # Counts beyond `max_encoded_size` are caught, since the input and output end there
    @test_throws ErrorException try_decode(MemoryView(zeros(UInt8, 2)), UInt8, Liar())
    @test_throws ErrorException try_encode!(MemoryView(zeros(UInt8, 2)), 0x00, Liar())
    # Also on the slow path, where the input or output is shorter
    @test_throws ErrorException try_decode(MemoryView(zeros(UInt8, 1)), UInt16, Liar())
    @test_throws ErrorException try_encode!(MemoryView(zeros(UInt8, 1)), 0x0000, Liar())
    # A `codec_max_encoded_size` that doesn't return a positive `Val`
    @test_throws ErrorException max_encoded_size(Int32, Liar())
    msg = try
        try_decode(mem, Int16, Liar())
    catch e
        sprint(showerror, e)
    end
    @test occursin("`codec_try_decode` for `Int16` with `Liar()` broke its contract", msg)
    @test occursin("byte count of -1", msg)
    # A count of zero is caught also on the slow path
    @test_throws ErrorException try_decode(MemoryView(zeros(UInt8, 1)), Int64, Liar())
    @test_throws ErrorException try_encode!(MemoryView(zeros(UInt8, 1)), Int64(0), Liar())
    @test_throws ErrorException try_load(CursorReader([0x00]), Int64, Liar())
    # The codec is not called when there are no bytes
    @test is_err(try_load(CursorReader(UInt8[]), Int64, Liar()), EndOfInput)
end

@testset "Memory-like arguments" begin
    bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
    mem = MemoryView(bytes)
    # The same results as with a `MemoryView`
    for b in (bytes, Memory{UInt8}(bytes), view(bytes, 1:6))
        @test try_decode(b, UInt32, BigEndian()) === try_decode(mem, UInt32, BigEndian())
        @test try_decode(b, 3, UInt32, BigEndian()) === try_decode(mem, 3, UInt32, BigEndian())
        @test try_decode(b, 4, UInt32, BigEndian()) == DecodeError(Truncated)
        @test decode(b, UInt16, LittleEndian()) === 0x0201
        @test decode(b, 5, UInt16, LittleEndian()) === 0x0605
        @test try_decode_next(b, 2, UInt16, BigEndian()) === (0x0203, 4)
        @test decode_next(b, 5, UInt16, BigEndian()) === (0x0506, 7)
    end
    @test decode(view(bytes, 3:6), UInt16, BigEndian()) === 0x0304
    v = zeros(UInt8, 5)
    @test try_encode!(v, 0x0102, BigEndian()) === 2
    @test try_encode!(v, 4, 0x0304, BigEndian()) === 2
    @test try_encode!(v, 5, 0x0304, BigEndian()) == EncodeError(InsufficientSpace)
    @test v == [0x01, 0x02, 0x00, 0x03, 0x04]
    @test encode!(view(v, 2:5), 'é', UTF8()) === 2
    @test encode!(v, 5, 0x09, BigEndian()) === 1
    @test v == [0x01, 0xc3, 0xa9, 0x03, 0x09]

    # Bulk functions
    dst = zeros(UInt16, 3)
    @test decode_all!(dst, bytes, LittleEndian()) == (3, 6)
    @test dst == [0x0201, 0x0403, 0x0605]
    out = zeros(UInt8, 6)
    @test encode_all!(out, dst, BigEndian()) == (3, 6)
    @test out == [0x02, 0x01, 0x04, 0x03, 0x06, 0x05]
    dst = zeros(UInt16, 2)
    @test load_into!(CursorReader(bytes), dst, LittleEndian()) == (2, 4)
    @test dst == [0x0201, 0x0403]
    dst = zeros(UInt16, 4)
    @test load_all!(CursorReader(bytes), dst, BigEndian()) == (3, 6)
    @test dst[1:3] == [0x0102, 0x0304, 0x0506]
    dst = zeros(UInt16, 3)
    @test load_every!(CursorReader(bytes), dst, BigEndian()) == 6
    @test dst == [0x0102, 0x0304, 0x0506]
    dst = zeros(UInt16, 2)
    @test decode_every!(dst, bytes, BigEndian()) == 4
    @test dst == [0x0102, 0x0304]
    out = zeros(UInt8, 4)
    @test encode_every!(out, dst, LittleEndian()) == 4
    @test out == [0x02, 0x01, 0x04, 0x03]
    io = VecWriter()
    @test store_every(io, ['a', 'é'], UTF8()) == 3
    @test store_into(io, ['b'], UTF8()) == (1, 1)
    @test store_all(io, ['c'], UTF8()) == (1, 1)
    @test io.vec == [0x61, 0xc3, 0xa9, 0x62, 0x63]
    # The convenience modules
    @test Little.decode(bytes, 2, UInt16) === 0x0302
    dst = zeros(UInt16, 3)
    @test Big.load_every!(CursorReader(bytes), dst) == 6
    @test dst == [0x0102, 0x0304, 0x0506]

    # Strings are not converted implicitly, since that allocates
    s = "abcdef"
    for x in (s, SubString(s, 2), codeunits(s))
        @test_throws ArgumentError try_decode(x, UInt8, LittleEndian())
        @test_throws ArgumentError decode(x, 2, UInt8, LittleEndian())
        @test_throws ArgumentError try_decode_next(x, 1, Char, UTF8())
        @test_throws ArgumentError decode_all!(zeros(UInt8, 2), x, LittleEndian())
        @test_throws ArgumentError store_every(VecWriter(), x, LittleEndian())
        @test_throws ArgumentError decode_every!(zeros(UInt8, 2), x, LittleEndian())
        @test_throws ArgumentError store_into(VecWriter(), x, LittleEndian())
    end
    @test_throws ArgumentError encode_all!(zeros(UInt8, 4), "ab", UTF8())
    # Memory of the wrong element type or mutability is an error, not an infinite
    # recursion
    @test_throws TypeError try_decode(Int8[1, 2], UInt8, LittleEndian())
    @test_throws TypeError try_decode(MemoryView(Int8[1, 2]), UInt8, LittleEndian())
    @test_throws TypeError encode!(ImmutableMemoryView(zeros(UInt8, 2)), 0x01, LittleEndian())
    @test_throws TypeError decode_all!(ImmutableMemoryView(zeros(UInt8, 2)), bytes, LittleEndian())
    @test_throws TypeError load_every!(CursorReader(bytes), ImmutableMemoryView(zeros(UInt16, 2)), LittleEndian())
    # Not memory at all
    @test_throws MethodError try_decode(0x01:0x05, UInt8, LittleEndian())

    # Converting a `Vector` doesn't allocate
    decode_vector(v, i) = decode(v, i, UInt32, LittleEndian())
    encode_vector!(v, x) = encode!(v, 2, x, BigEndian())
    decode_vector(bytes, 2)
    encode_vector!(v, 0x0102)
    @test_allocs (@allocated decode_vector(bytes, 2)) == 0
    @test_allocs (@allocated encode_vector!(v, 0x0102)) == 0
end

@testset "Little and Big" begin
    for (M, E) in ((Little, LittleEndian()), (Big, BigEndian()))
        bytes = [0x01, 0x02, 0x03, 0x04, 0x05]
        @test M.try_decode(MemoryView(bytes), UInt32) === try_decode(MemoryView(bytes), UInt32, E)
        @test M.decode(MemoryView(bytes), UInt16) === decode(MemoryView(bytes), UInt16, E)
        @test M.try_decode(MemoryView(bytes), 2, UInt32) === try_decode(MemoryView(bytes), 2, UInt32, E)
        @test M.decode(MemoryView(bytes), 4, UInt16) === decode(MemoryView(bytes), 4, UInt16, E)
        @test M.try_decode_next(MemoryView(bytes), 2, UInt32) === try_decode_next(MemoryView(bytes), 2, UInt32, E)
        @test M.decode_next(MemoryView(bytes), 4, UInt16) === decode_next(MemoryView(bytes), 4, UInt16, E)
        @test M.try_decode_exact(MemoryView(bytes), 2, UInt32) === try_decode_exact(MemoryView(bytes), 2, UInt32, E)
        @test M.try_decode_exact(MemoryView(bytes), UInt16) == DecodeError(TrailingData)
        @test M.decode_exact(MemoryView(bytes)[1:2], UInt16) === decode_exact(MemoryView(bytes)[1:2], UInt16, E)
        @test M.decode_exact(MemoryView(bytes), 4, UInt16) === decode_exact(MemoryView(bytes), 4, UInt16, E)
        @test M.load_exact(CursorReader(bytes), 4, UInt32) === load_exact(CursorReader(bytes), 4, UInt32, E)
        @test M.try_load_exact(CursorReader(bytes), 5, UInt32) == DecodeError(TrailingData)
        a = zeros(UInt8, 4)
        b = zeros(UInt8, 4)
        @test M.encode!(MemoryView(a), 0x0102) == encode!(MemoryView(b), 0x0102, E)
        @test a == b
        @test M.encode!(MemoryView(a), 3, 0x0304) == encode!(MemoryView(b), 3, 0x0304, E)
        @test a == b
        @test M.try_encode!(MemoryView(a), 0x0506) == try_encode!(MemoryView(b), 0x0506, E)
        @test a == b
        @test M.try_encode!(MemoryView(a), 4, 0x0708) === try_encode!(MemoryView(b), 4, 0x0708, E) == EncodeError(InsufficientSpace)
        @test M.load(CursorReader(bytes), UInt32) === load(CursorReader(bytes), UInt32, E)
        @test M.try_load(CursorReader(bytes), UInt64) == DecodeError(Truncated)
        w1 = VecWriter()
        w2 = VecWriter()
        @test M.store(w1, 0x0102) == store(w2, 0x0102, E)
        @test M.try_store(w1, 0x0304) === try_store(w2, 0x0304, E) === 2
        @test M.try_encode!(SCRATCH, 0x0102) === M.encode!(SCRATCH, 0x0102) === 2
        @test M.store_every(w1, MemoryView(UInt16[1, 2])) == store_every(w2, MemoryView(UInt16[1, 2]), E)
        @test w1.vec == w2.vec
        d1 = zeros(UInt16, 3)
        d2 = zeros(UInt16, 3)
        @test M.decode_all!(MemoryView(d1), MemoryView(bytes)) == decode_all!(MemoryView(d2), MemoryView(bytes), E)
        @test d1 == d2
        @test M.encode_all!(MemoryView(a), MemoryView(d1)) == encode_all!(MemoryView(b), MemoryView(d2), E)
        @test a == b
        @test M.load_into!(CursorReader(bytes), MemoryView(d1)) == load_into!(CursorReader(bytes), MemoryView(d2), E)
        @test M.load_all!(CursorReader(bytes), MemoryView(d1)) == load_all!(CursorReader(bytes), MemoryView(d2), E)
        @test d1 == d2
        @test M.load_every!(CursorReader(bytes), MemoryView(d1)[1:2]) == load_every!(CursorReader(bytes), MemoryView(d2)[1:2], E)
        @test d1 == d2
        @test M.decode_every!(MemoryView(d1)[1:2], MemoryView(bytes)) == decode_every!(MemoryView(d2)[1:2], MemoryView(bytes), E)
        @test d1 == d2
        @test M.encode_every!(MemoryView(a), MemoryView(d1)[1:2]) == encode_every!(MemoryView(b), MemoryView(d2)[1:2], E)
        @test a == b
        @test M.store_into(w1, MemoryView(d1)) == store_into(w2, MemoryView(d2), E)
        @test M.store_all(w1, MemoryView(d1)) == store_all(w2, MemoryView(d2), E)
        @test w1.vec == w2.vec
    end
    @test_throws ArgumentError Little.store(VecWriter(), 'a')
end

@testset "DecodeError" begin
    @test DecodeError(Truncated) isa DecodeError{Nothing}
    # The payload types of most codecs make errors that hold no references
    @test Base.allocatedinline(DecodeError{Nothing})
    @test Base.allocatedinline(DecodeError{ParseError})
    @test Base.allocatedinline(DecodeError{Union{Nothing, ParseError}})
    @test DecodeError <: Exception
    for kind in (EndOfInput, Truncated, InvalidData, TrailingData)
        str = sprint(showerror, DecodeError(kind))
        @test startswith(str, "DecodeError: ")
        @test !occursin("payload", str)
    end
end

@testset "EncodeError" begin
    @test EncodeError(InvalidValue) isa EncodeError{Nothing}
    @test Base.allocatedinline(EncodeError{Nothing})
    @test EncodeError <: Exception
    for kind in (InsufficientSpace, InvalidValue)
        str = sprint(showerror, EncodeError(kind))
        @test startswith(str, "EncodeError: ")
        @test !occursin("payload", str)
    end
end

@testset "Allocations" begin
    function sum_loads(io)
        s = UInt64(0)
        while true
            x = try_load(io, UInt32, BigEndian())
            x isa DecodeError && break
            s += x
        end
        return s
    end
    function sum_chars(io)
        s = UInt32(0)
        while true
            x = try_load(io, Char, UTF8())
            x isa DecodeError && break
            s += reinterpret(UInt32, x)
        end
        return s
    end
    store_loop(io, n) = (
        for i in 1:n
            store(io, i % UInt32, LittleEndian())
        end; nothing
    )
    function sum_exact(io)
        s = UInt64(0)
        while true
            x = try_load_exact(io, 4, UInt32, BigEndian())
            x isa DecodeError && break
            s += x
        end
        return s
    end
    data = rand(UInt8, 1001)
    sum_exact(CursorReader(data))
    @test_allocs (@allocated sum_exact(CursorReader(data))) ≤ 64
    sum_loads(CursorReader(data))
    sum_chars(CursorReader(data))
    @test_allocs (@allocated sum_loads(CursorReader(data))) ≤ 64 # the reader itself
    @test_allocs (@allocated sum_chars(CursorReader(data))) ≤ 64
    io = VecWriter(sizehint!(UInt8[], 4000))
    store_loop(io, 1)
    empty!(io.vec)
    @test_allocs (@allocated store_loop(io, 900)) == 0
    function sum_indexed(mem)
        s = UInt64(0)
        i = 1
        while i ≤ length(mem) - 3
            s += @inbounds decode(mem, i, UInt32, LittleEndian())
            s += decode(mem, i, UInt32, BigEndian())
            i += 4
        end
        return s
    end
    sum_indexed(ImmutableMemoryView(data))
    @test_allocs (@allocated sum_indexed(ImmutableMemoryView(data))) == 0
    bulk_allocs(dst, mem) = @allocated decode_all!(dst, mem, BigEndian())
    dst = MemoryView(zeros(UInt32, 250))
    mem = ImmutableMemoryView(data)
    bulk_allocs(dst, mem)
    @test_allocs bulk_allocs(dst, mem) == 0
    # Returning an `EncodeError` doesn't allocate
    function count_invalid(io, chars)
        k = 0
        for c in chars
            try_store(io, c, Latin1()) isa EncodeError && (k += 1)
        end
        return k
    end
    chars = MemoryView(rand(['a', 'λ'], 100))
    io = VecWriter(sizehint!(UInt8[], 200))
    count_invalid(io, chars)
    @test_allocs (@allocated count_invalid(io, chars)) == 0
end
