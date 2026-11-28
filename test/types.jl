@testset "Values that can't be encoded" begin
    encode_inbounds!(mem, i, x, e) = @inbounds encode!(mem, i, x, e)
    @test max_encoded_size(Char, Latin1()) == 1
    for c in ('a', 'é', '\u00ff')
        @test try_encode!(SCRATCH, c, Latin1()) === encode!(SCRATCH, c, Latin1()) === 1
    end
    for c in ('λ', '€', '\u0100', '\xff', '\ud800')
        @test try_encode!(SCRATCH, c, Latin1()) == EncodeError(InvalidValue)
        @test_error EncodeError(InvalidValue) encode!(SCRATCH, c, Latin1())
        for len in 0:2
            buf = fill(0xaa, len)
            @test try_encode!(MemoryView(buf), c, Latin1()) == EncodeError(InvalidValue)
            # Also when `mem` is too short, as this codec checks the value first
            @test_error EncodeError(InvalidValue) encode!(MemoryView(buf), c, Latin1())
            if len ≥ 1
                # The value is checked also in an `@inbounds` context
                @test_error EncodeError(InvalidValue) encode_inbounds!(MemoryView(buf), 1, c, Latin1())
            end
            # This codec checks the value before writing
            @test buf == fill(0xaa, len)
        end
        io = VecWriter()
        @test try_store(io, c, Latin1()) == EncodeError(InvalidValue)
        @test_error EncodeError(InvalidValue) store(io, c, Latin1())
        @test isempty(io.vec)
    end
    # Too little space for a valid value
    @test try_encode!(MemoryView(UInt8[]), 'a', Latin1()) == EncodeError(InsufficientSpace)
    @test_throws LightBoundsError encode!(MemoryView(UInt8[]), 'a', Latin1())
    io = VecWriter()
    @test try_store(io, 'é', Latin1()) === 1
    @test store(io, 'a', Latin1()) === 1
    @test io.vec == [0xe9, 0x61]

    # Bulk functions stop at the value
    src = ['a', 'b', 'λ', 'c']
    buf = fill(0xaa, 6)
    @test encode_all!(MemoryView(buf), MemoryView(src), Latin1()) == (2, 2)
    @test buf[1:2] == [0x61, 0x62]
    @test try_encode!(MemoryView(buf), 3, src[3], Latin1()) == EncodeError(InvalidValue)
    for cap in (1, 2, 3, 100)
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        @test_error EncodeError(InvalidValue) store_every(io, MemoryView(src), Latin1())
        flush(io)
        @test sink == [0x61, 0x62]
    end
    @test_error EncodeError(InvalidValue) store_every(VecWriter(), MemoryView(['λ']), Latin1())
    for cap in (1, 2, 3, 100)
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        @test store_all(io, MemoryView(src), Latin1()) == (2, 2)
        @test store_all(io, MemoryView(src), Latin1()) == (2, 2)
        flush(io)
        @test sink == [0x61, 0x62, 0x61, 0x62]
    end
    io = VecWriter()
    @test store_into(io, MemoryView(['λ']), Latin1()) == (0, 0)
    @test store_all(io, MemoryView(['λ']), Latin1()) == (0, 0)
    @test isempty(io.vec)
    buf = fill(0xaa, 6)
    @test_error EncodeError(InvalidValue) encode_every!(MemoryView(buf), MemoryView(src), Latin1())
    @test buf[1:2] == [0x61, 0x62]

    # A codec may write before it finds out that the value is invalid, but not beyond
    # `max_encoded_size` bytes
    T = Tuple{Char, Char}
    @test max_encoded_size(T, Latin1()) == 2
    @test try_encode!(SCRATCH, ('a', 'b'), Latin1()) === 2
    @test try_encode!(SCRATCH, ('a', 'λ'), Latin1()) == EncodeError(InvalidValue)
    @test try_encode!(SCRATCH, ('λ', 'a'), Latin1()) == EncodeError(InvalidValue)
    buf = fill(0xaa, 5)
    @test try_encode!(MemoryView(buf), 2, ('a', 'λ'), Latin1()) == EncodeError(InvalidValue)
    @test buf == [0xaa, 0x61, 0xaa, 0xaa, 0xaa]
    @test_error EncodeError(InvalidValue) encode!(MemoryView(buf), 2, ('b', 'λ'), Latin1())
    # When there is too little space, only bytes the encoding would cover are written
    buf = fill(0xaa, 3)
    @test try_encode!(MemoryView(buf), 3, ('a', 'b'), Latin1()) == EncodeError(InsufficientSpace)
    @test_throws LightBoundsError encode!(MemoryView(buf), 3, ('a', 'b'), Latin1())
    @test buf[1:2] == fill(0xaa, 2)
    @test encode!(MemoryView(buf), 2, ('a', 'b'), Latin1()) === 2
    @test decode(MemoryView(buf), 2, T, Latin1()) === ('a', 'b')
    # Bytes written for an invalid value are not stored
    io = VecWriter()
    @test try_store(io, ('a', 'λ'), Latin1()) == EncodeError(InvalidValue)
    @test isempty(io.vec)
    @test store(io, ('x', 'y'), Latin1()) == 2
    @test io.vec == [0x78, 0x79]
end

@testset "Structs" begin
    # BitsLoadable: the fields are in order, each in the byte order of the encoding
    h = Header(0x01020304, 0x0506, 0x07, 0x08)
    @test max_encoded_size(Header, LittleEndian()) == max_encoded_size(Header, BigEndian()) == 8
    le = [0x04, 0x03, 0x02, 0x01, 0x06, 0x05, 0x07, 0x08]
    be = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    for (e, bytes) in ((LittleEndian(), le), (BigEndian(), be))
        buf = fill(0xaa, 10)
        @test encode!(MemoryView(buf), 2, h, e) == 8
        @test buf[2:9] == bytes
        @test buf[[1, 10]] == [0xaa, 0xaa]
        @test try_decode_n(MemoryView(bytes), Header, e) === (h, 8)
        @test decode(MemoryView(buf), 2, Header, e) === h
        @test is_err(try_decode(MemoryView(bytes[1:7]), Header, e), Truncated)
        @test is_err(try_decode(MemoryView(UInt8[]), Header, e), EndOfInput)
        @test load(CursorReader(bytes), Header, e) === h
        w = VecWriter()
        @test store(w, h, e) == 8
        @test w.vec == bytes
    end
    # Nested structs
    n = Nested(h, 1.5f0, Int16(-2), Int16(3))
    @test max_encoded_size(Nested, BigEndian()) == 16
    n_be = [be; bytes_be(1.5f0); bytes_be(Int16(-2)); bytes_be(Int16(3))]
    buf = zeros(UInt8, 16)
    @test encode!(MemoryView(buf), n, BigEndian()) == 16
    @test buf == n_be
    @test decode(MemoryView(n_be), Nested, BigEndian()) === n
    # Bulk
    for e in (LittleEndian(), BigEndian())
        values = [Nested(Header(rand(UInt32), rand(UInt16), rand(UInt8), rand(UInt8)), rand(Float32), rand(Int16), rand(Int16)) for _ in 1:20]
        bytes = zeros(UInt8, 16 * 20 + 3)
        @test encode_all!(MemoryView(bytes), MemoryView(values), e) == (20, 320)
        @test [decode(MemoryView(bytes), 16 * (i - 1) + 1, Nested, e) for i in 1:20] == values
        dst = Vector{Nested}(undef, 25)
        @test decode_all!(MemoryView(dst), MemoryView(bytes), e) == (20, 320)
        @test dst[1:20] == values
        dst = Vector{Nested}(undef, 25)
        @test load_all!(ChunkedReader([bytes[i:min(i + 6, end)] for i in 1:7:length(bytes)]), MemoryView(dst), e) == (20, 320)
        @test dst[1:20] == values
        w = VecWriter()
        @test store_every(w, MemoryView(values), e) == 320
        @test w.vec == bytes[1:320]
    end

    # BitsStorable: the fields are checked, then the whole value
    @test try_decode_n(MemoryView([0x01, 0x00, 0x02, 0x03]), Flagged, BigEndian()) === (Flagged(true, 0x00, banana), 4)
    @test try_decode(MemoryView([0x00, 0x07, 0x01, 0x00]), Flagged, LittleEndian()) === Flagged(false, 0x07, apple)
    @test is_err(try_decode(MemoryView([0x02, 0x00, 0x00, 0x01]), Flagged, BigEndian()), InvalidData) # Bool
    @test is_err(try_decode(MemoryView([0x01, 0x00, 0x00, 0x00]), Flagged, BigEndian()), InvalidData) # Fruit
    @test is_err(try_decode(MemoryView([0x00, 0x00, 0x02, 0x03]), Flagged, BigEndian()), InvalidData) # invariant
    buf = zeros(UInt8, 4)
    @test encode!(MemoryView(buf), Flagged(true, 0x05, cherry), BigEndian()) == 4
    @test buf == [0x01, 0x05, 0xff, 0xff]
    # The fields of nested structs are checked too
    valid = [0x01, 0x00, 0x02, 0x03]
    breaks_invariant = [0x00, 0x00, 0x02, 0x03]
    @test decode(MemoryView([valid; valid]), Outer, BigEndian()) === Outer(Flagged(true, 0x00, banana), Flagged(true, 0x00, banana))
    @test is_err(try_decode(MemoryView([valid; breaks_invariant]), Outer, BigEndian()), InvalidData)
    @test is_err(try_decode(MemoryView([valid; [0x03, 0x00, 0x02, 0x03]]), Outer, BigEndian()), InvalidData)
    @test decode_all!(MemoryView(Vector{Outer}(undef, 3)), MemoryView([valid; valid; valid; breaks_invariant]), BigEndian()) == (1, 8)

    # Types of size zero are not supported, also by the bulk functions, which
    # divide by the size
    for e in (LittleEndian(), BigEndian())
        @test_throws ArgumentError encode!(MemoryView(UInt8[]), Empty(), e)
        @test_throws ArgumentError encode_all!(MemoryView(UInt8[0x00]), MemoryView([Empty()]), e)
        @test_throws ArgumentError store_every(VecWriter(), MemoryView([Empty()]), e)
        @test_throws ArgumentError load_into!(CursorReader([0x00]), MemoryView([Empty()]), e)
    end

    # Structs that can't be bits types
    for T in (
            Padded, LoadableWithBool, WithChar, WithPlain, WithPadded, Misaligned,
            TrailingPadding, MisalignedNested, WithU256, WithU24, Empty, WithEmpty,
            (HAS_NARROW ? (WithNarrow,) : ())...,
        )
        @test_throws ArgumentError max_encoded_size(T, LittleEndian())
        @test_throws ArgumentError try_decode(MemoryView(zeros(UInt8, 16)), T, BigEndian())
        @test_throws ArgumentError decode_all!(MemoryView(Vector{T}(undef, 1)), MemoryView(zeros(UInt8, 16)), BigEndian())
    end
    @test_throws ArgumentError encode!(MemoryView(zeros(UInt8, 8)), Padded(0x01, 0x02), LittleEndian())
    message(T) =
    try
        max_encoded_size(T, LittleEndian())
    catch e
        sprint(showerror, e)
    end
    @test occursin("`Padded` has padding on some or all platforms, so it can't be `BitsLoadable`: its field `b` follows 1 bytes of other fields, which is not a multiple of 4, the size of its type `UInt32`", message(Padded))
    @test occursin("`LoadableWithBool` is `BitsLoadable`, but its field `a` has the type `Bool`, which is `BitsStorable`", message(LoadableWithBool))
    @test occursin("field `c` of `WithChar` has the type `Char`, whose `codec_scheme` with `LittleEndian()` is `Manual`", message(WithChar))
    @test occursin("field `p` of `WithPlain` has the type `Plain`", message(WithPlain))
    @test occursin("`Padded` has padding", message(WithPadded))
    HAS_NARROW && @test occursin("whose bit width 30 is not a power of two of at least 8", message(WithNarrow))
    @test occursin("field `b` follows 4 bytes of other fields, which is not a multiple of 8", message(Misaligned))
    @test occursin("its fields have 12 bytes, which is not a multiple of 8, the size of its largest primitive field", message(TrailingPadding))
    @test occursin("field `h` follows 2 bytes of other fields, which is not a multiple of 4, the size of the largest primitive field of its type `Header`", message(MisalignedNested))
    @test occursin("field `b` follows 16 bytes of other fields, which is not a multiple of 32, the size of its type `U256`", message(WithU256))
    @test occursin("whose bit width 24 is not a power of two of at least 8", message(WithU24))
    # The stricter rule rejects `WithU256` although it has no padding on this platform
    @test fieldoffset(WithU256, 2) == 16 && sizeof(WithU256) == 48 || Base.datatype_alignment(U256) == 32

    # The padding check is available on its own, independent of the codec scheme
    is_padding_free = Inscription.is_padding_free
    for T in (Ordered, ExplicitPadding, WithU256Aligned, Plain, Header, Tuple{UInt8, UInt8, UInt16}, UInt64, Empty)
        @test is_padding_free(T)
    end
    for T in (Padded, WithPadded, Misaligned, TrailingPadding, MisalignedNested, WithU256, WithU24, Tuple{UInt8, UInt16})
        @test !is_padding_free(T)
    end
    @test_throws ArgumentError is_padding_free(Vector{UInt8})
    @test_throws ArgumentError is_padding_free(Integer)
    @test is_padding_free(Ordered) === @inferred (() -> is_padding_free(Ordered))()
    # Accepted structs round-trip
    for x in (
                Ordered(0x0102030405060708, 0x090a0b0c, 0x0d0e, 0x0f, 0x10),
                ExplicitPadding(0x01020304, 0x00000000, 0x05060708090a0b0c),
                WithU256Aligned(reinterpret(U256, ntuple(UInt8, 32)), 0x01, 0x02),
            ), e in (LittleEndian(), BigEndian())
        buf = zeros(UInt8, sizeof(x))
        @test encode!(buf, x, e) == sizeof(x)
        @test decode(buf, typeof(x), e) === x
    end
    # Not opted in: no codec
    @test_throws ArgumentError max_encoded_size(Plain, LittleEndian())
end

@testset "Tuples" begin
    s24 = decode([0x01, 0x02, 0x03], S24, BigEndian())
    u144 = decode(collect(0x01:0x12), U144, BigEndian())
    values = (
        (0x0102, 0x0304),
        (Header(0x01020304, 0x0506, 0x07, 0x08), 0x090a0b0c0d0e0f10),
        ((0x01, 0x02), 0x0304),
        (banana, true, wee),
        (Flagged(true, 0x05, cherry), Int32(-2)),
        (0x2a,),
        (0x01, 0x02030405),
        (0x0102, 0x03),
        (true, 0x01020304, s24),
        (Even(0x04), 0x0102),
        ((0x01, 0x02030405), false),
        (u144, Flagged(false, 0x07, apple)),
    )
    @test Set(map(typeof, values)) == Set((BITS_TUPLES..., ELEMENTWISE_TUPLES...))

    # Bits types if the requirements of bits structs hold, else encoded element by element
    @test all(T -> !(codec_scheme(T, LittleEndian()) isa Manual), BITS_TUPLES)
    @test all(T -> codec_scheme(T, LittleEndian()) isa Manual, ELEMENTWISE_TUPLES)
    @test codec_scheme(NTuple{2, UInt16}, LittleEndian()) === BitsLoadable()
    @test codec_scheme(Tuple{Fruit, Bool, Small}, LittleEndian()) === BitsStorable()
    @test codec_scheme(Tuple{Tuple{Small, Small}, Fruit}, LittleEndian()) === BitsStorable()
    # `Tuple{Fruit, Bool}` has padding at its end, so a tuple containing it can't be a bits type
    @test codec_scheme(Tuple{Tuple{Fruit, Bool}, Small, Small}, LittleEndian()) === Manual()
    @test codec_scheme(Tuple{Char, Char}, LittleEndian()) === Manual()
    @test codec_scheme(Tuple{Integer}, LittleEndian()) === Manual()
    # Structs may have tuple fields
    w = WithTuple((0x0102, 0x0304), 0x05060708)
    bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    @test encode!(zeros(UInt8, 8), w, BigEndian()) == 8
    @test decode(bytes, WithTuple, BigEndian()) === w
    @test decode(bytes, WithTuple, LittleEndian()) === WithTuple((0x0201, 0x0403), 0x08070605)

    # The byte order only passes on to the elements, so one is enough to test tuples
    e = LittleEndian()
    for x in values
        T = typeof(x)
        # The encodings of the elements, one after another
        bytes = encoding(x, e)
        @test bytes == reduce(vcat, (encoding(y, e) for y in x))
        @test max_encoded_size(T, e) == sum(y -> max_encoded_size(typeof(y), e), x) == length(bytes)
        @test try_encode!(SCRATCH, x, e) == length(bytes)
        @test try_decode_n(MemoryView([bytes; 0xff]), T, e) === (x, length(bytes))
        @test load(CursorReader(bytes), T, e) === x
        # Loading waits for the bytes it needs
        @test load(ChunkedReader([[b] for b in bytes]), T, e) === x
        @test load_exact(CursorReader(bytes), length(bytes), T, e) === x
        w = VecWriter()
        @test store(w, x, e) == length(bytes)
        @test w.vec == bytes
        # Too few bytes
        @test is_err(try_decode(UInt8[], T, e), EndOfInput)
        for len in 1:(length(bytes) - 1)
            @test is_err(try_decode(bytes[1:len], T, e), Truncated)
            # Bytes beyond `buf` would have been written, so it's all unspecified
            buf = fill(0xaa, len + 1)
            @test try_encode!(view(buf, 1:len), x, e) == EncodeError(InsufficientSpace)
            @test buf[end] == 0xaa
        end
        # Bulk
        xs = fill(x, 5)
        all_bytes = repeat(bytes, 5)
        buf = zeros(UInt8, length(all_bytes) + 1)
        @test encode_all!(buf, xs, e) == (5, length(all_bytes))
        @test buf[1:(end - 1)] == all_bytes
        # Limited by the input
        dst = Vector{T}(undef, 6)
        @test decode_all!(dst, MemoryView(buf)[1:(end - 1)], e) == (5, length(all_bytes))
        @test dst[1:5] == xs
        chunks = [all_bytes[i:min(i + 2, end)] for i in 1:3:length(all_bytes)]
        dst = Vector{T}(undef, 5)
        @test load_all!(ChunkedReader(chunks), MemoryView(dst), e) == (5, length(all_bytes))
        @test dst == xs
        w = VecWriter()
        @test store_every(w, MemoryView(xs), e) == length(all_bytes)
        @test w.vec == all_bytes
    end

    # Invalid elements
    @test is_err(try_decode([0x01, 0x00, 0x00], Tuple{Even, UInt16}, e), InvalidData)
    @test is_err(try_decode([0x02, 0x00, 0x00, 0x00, 0x00], Tuple{Bool, UInt32}, e), InvalidData)
    @test is_err(try_decode([0x01, 0x00, 0x00, 0x00, 0x02], Tuple{UInt32, Bool}, e), InvalidData)
    # A later invalid element is only found after the earlier ones are decoded
    @test is_err(try_decode([0x01], Tuple{UInt32, Bool}, e), Truncated)
    @test try_encode!(SCRATCH, (0x01, Even(0x03)), e) == EncodeError(InvalidValue)
    @test try_encode!(zeros(UInt8, 2), (0x01, Even(0x03)), e) == EncodeError(InvalidValue)
    # Only the first `max_encoded_size` bytes may be written on errors
    buf = fill(0xaa, 6)
    @test try_encode!(buf, 2, (0x01, Even(0x03)), e) == EncodeError(InvalidValue)
    @test buf[[1, 4, 5, 6]] == fill(0xaa, 4)
    @test_error EncodeError(InvalidValue) store(VecWriter(), (0x01, Even(0x03)), e)
    # Either error kind may be returned if both apply
    @test try_encode!(zeros(UInt8, 1), (0x01, Even(0x03)), e) isa EncodeError

    # An invalid element decides the result, so loading doesn't wait for the rest
    @test_error DecodeError(InvalidData) load(StallingReader([[0x02]]), Tuple{Bool, UInt32}, e)
    @test_error DecodeError(InvalidData) load(StallingReader([[0x01, 0x03]]), Tuple{UInt8, Even, UInt64}, e)
    @test load(StallingReader([[0x01], [0x02, 0x03], [0x04, 0x05]]), Tuple{Bool, UInt32}, e) === (true, 0x05040302)
    @test_throws ErrorException load(StallingReader([[0x01, 0x02]]), Tuple{Bool, UInt32}, e)

    # Tuples that can't be encoded
    @test_throws ArgumentError max_encoded_size(Tuple{}, e)
    @test_throws ArgumentError try_decode(UInt8[], Tuple{}, e)
    @test_throws ArgumentError encode!(UInt8[], (), e)
    @test_throws ArgumentError max_encoded_size(Tuple{Integer}, e)
    @test_throws ArgumentError try_decode(zeros(UInt8, 8), Tuple{Integer}, e)
    @test_throws ArgumentError max_encoded_size(Tuple{Char}, e)
    # Only the byte orders encode tuples
    @test_throws ArgumentError max_encoded_size(Tuple{Char, Char}, UTF8())

    # Encoding element by element doesn't allocate
    function sum_tuples(io)
        s = UInt64(0)
        while true
            x = try_load(io, Tuple{UInt8, UInt32, Bool}, BigEndian())
            x isa DecodeError && break
            s += x[1] + x[2] + x[3]
        end
        return s
    end
    data = repeat([0x01, 0x00, 0x00, 0x00, 0x02, 0x01], 100)
    @test sum_tuples(CursorReader(data)) == 400
    io = CursorReader(data)
    @test_allocs (@allocated sum_tuples(io)) == 0
    w = VecWriter()
    sizehint!(w.vec, 1000)
    store_tuple(w) = store(w, (0x01, 0x02030405, true), LittleEndian())
    store_tuple(w)
    @test_allocs (@allocated store_tuple(w)) == 0
end
