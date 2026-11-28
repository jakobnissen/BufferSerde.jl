using Inscription: decode_invalid_type, encode_invalid_type, decode_error

# The errors of decoding or encoding a `T` with `e`, of the type that its functions
# return. The payload of `Invalid()` is `nothing`.
function derr(T, e, kind, payload = nothing)
    return DecodeError{decode_invalid_type(T, e)}(kind, kind === InvalidData ? Some(payload) : nothing)
end
function eerr(T, e, kind, payload = nothing)
    return EncodeError{encode_invalid_type(T, e)}(kind, kind === InvalidValue ? Some(payload) : nothing)
end

@testset "Payload types" begin
    LE = LittleEndian()
    BE = BigEndian()
    # Bits types that can't be invalid
    for T in (UInt32, Float64, Header, Tuple{UInt8, UInt8}, U24)
        @test decode_invalid_type(T, LE) === Union{}
        @test encode_invalid_type(T, BE) === Union{}
    end
    # Bits types that can be invalid, but whose `validate_bits` gives no payload
    for T in (Bool, Fruit, Flagged, Outer, S24)
        @test decode_invalid_type(T, LE) === Nothing
        @test encode_invalid_type(T, LE) === Union{}
    end
    # Hand-written codecs
    @test decode_invalid_type(Char, UTF8()) === Union{}
    @test encode_invalid_type(Char, UTF8()) === Nothing
    @test decode_invalid_type(Char, Latin1()) === encode_invalid_type(Char, Latin1()) === Nothing
    @test decode_invalid_type(UInt8, Digits()) === ParseError
    @test encode_invalid_type(UInt8, Digits()) === Nothing
    @test decode_invalid_type(DigitPair, Digits()) === Union{Nothing, ParseError}
    @test decode_invalid_type(Char, Ascii()) === UInt8
    @test encode_invalid_type(Char, Ascii()) === NotAscii
    # Bits types pass on the payloads of their fields
    @test decode_invalid_type(Odd16, LE) === EvenBits
    @test decode_invalid_type(Tagged, BE) === TAGGED_PAYLOADS
    @test encode_invalid_type(Tagged, BE) === Union{}
    # Tuples pass on the payloads of their elements, whether they are bits types or not
    @test codec_scheme(Tuple{Odd16, Bool, Level}, LE) === BitsStorable()
    @test codec_scheme(Tuple{Bool, Odd16}, LE) === Manual()
    @test decode_invalid_type(Tuple{Odd16, Bool, Level}, LE) === Union{Nothing, EvenBits}
    @test decode_invalid_type(Tuple{Bool, Odd16}, BE) === Union{Nothing, EvenBits}
    @test decode_invalid_type(Tuple{Odd16}, LE) === EvenBits
    @test decode_invalid_type(Tuple{Tuple{Odd16, UInt8}, Tagged}, LE) === TAGGED_PAYLOADS
    @test encode_invalid_type(Tuple{Bool, Odd16}, BE) === Union{}
    # Proxies pass on the payloads of their proxy type
    @test decode_invalid_type(Bounded, LE) === Union{RangeError, EvenBits}
    @test encode_invalid_type(Bounded, LE) === RangeError
    @test decode_invalid_type(Tuple{Bounded, Tagged}, LE) === Union{RangeError, TAGGED_PAYLOADS}
    @test decode_invalid_type(Glyph, UTF8()) === Nothing
    @test encode_invalid_type(Glyph, UTF8()) === Nothing

    # The error type is the same for every kind of error
    for (T, e, x) in CODEC_CASES
        P = decode_invalid_type(T, e)
        Q = encode_invalid_type(T, e)
        @test try_decode(MemoryView(UInt8[]), T, e) isa DecodeError{P}
        @test try_load(CursorReader(UInt8[]), T, e) isa DecodeError{P}
        @test try_decode_exact(MemoryView(fill(0x31, 100)), T, e) isa DecodeError{P}
        @test try_encode!(MemoryView(UInt8[]), x, e) isa EncodeError{Q}
    end
end

@testset "Payload types are inferred" begin
    reader = typeof(CursorReader(UInt8[]))
    for (T, e, x) in CODEC_CASES
        P = decode_invalid_type(T, e)
        Q = encode_invalid_type(T, e)
        # The types and encodings are constants in the closures, as in user code
        decoder = @eval m -> try_decode(m, $T, $e)
        loader = @eval io -> try_load(io, $T, $e)
        encoder = @eval (m, x) -> try_encode!(m, x, $e)
        storer = @eval (io, x) -> try_store(io, x, $e)
        @test only(Base.return_types(decoder, (ImmutableMemoryView{UInt8},))) == Union{T, DecodeError{P}}
        @test only(Base.return_types(loader, (reader,))) == Union{T, DecodeError{P}}
        @test only(Base.return_types(encoder, (MutableMemoryView{UInt8}, T))) == Union{Int, EncodeError{Q}}
        @test only(Base.return_types(storer, (VecWriter, T))) == Union{Int, EncodeError{Q}}
    end
end

@testset "Decoding with payloads" begin
    # A hand-written codec
    perr(kind, payload = nothing) = derr(UInt8, Digits(), kind, payload)
    @test try_decode(MemoryView("255"), UInt8, Digits()) === 0xff
    @test try_decode(MemoryView("256"), UInt8, Digits()) === perr(InvalidData, Overflow)
    @test try_decode(MemoryView("x"), UInt8, Digits()) === perr(InvalidData, NoDigits)
    @test try_decode(MemoryView(UInt8[]), UInt8, Digits()) === perr(EndOfInput)
    @test try_decode_next(MemoryView("1256"), 2, UInt8, Digits()) === perr(InvalidData, Overflow)
    @test try_decode_exact(MemoryView("25"), UInt8, Digits()) === 0x19
    @test try_decode_exact(MemoryView("256"), UInt8, Digits()) === perr(InvalidData, Overflow)
    @test try_decode_exact(MemoryView("25x"), UInt8, Digits()) === perr(TrailingData)
    @test_throws perr(InvalidData, Overflow) decode(MemoryView("999"), UInt8, Digits())
    @test_throws perr(InvalidData, NoDigits) decode_next(MemoryView("x"), 1, UInt8, Digits())
    @test_throws perr(InvalidData, Overflow) decode_exact(MemoryView("999"), UInt8, Digits())
    # Too short input is decided before the payload, also when loading
    @test try_decode(MemoryView("2"), UInt8, Digits()) === 0x02
    @test try_load(CursorReader("256"), UInt8, Digits()) === perr(InvalidData, Overflow)
    @test try_load_exact(CursorReader("256"), 3, UInt8, Digits()) === perr(InvalidData, Overflow)
    @test try_load(ChunkedReader([[b] for b in b"999"]), UInt8, Digits()) === perr(InvalidData, Overflow)
    @test try_load(ChunkedReader([[b] for b in b"99"]), UInt8, Digits()) === 0x63
    @test_throws perr(InvalidData, Overflow) load(CursorReader("256"), UInt8, Digits())
    @test_throws perr(InvalidData, NoDigits) load_exact(CursorReader("x"), 1, UInt8, Digits())

    # The motivating example: retry with a wider type, since nothing was consumed
    function load_number(io)
        x = try_load(io, UInt8, Digits())
        if x isa DecodeError && x == DecodeError(InvalidData, Some(Overflow))
            return load(io, UInt16, Digits())
        end
        return x
    end
    io = CursorReader("300,12")
    @test load_number(io) === UInt16(300)
    @test load(io, UInt8, LittleEndian()) === UInt8(',')
    @test load_number(io) === UInt8(12)

    # A codec that passes on the payloads of its fields, and has its own without payload
    qerr(kind, payload = nothing) = derr(DigitPair, Digits(), kind, payload)
    @test try_decode(MemoryView("12,34"), DigitPair, Digits()) === DigitPair(12, 34)
    @test try_decode(MemoryView("1,x"), DigitPair, Digits()) === qerr(InvalidData, NoDigits)
    @test try_decode(MemoryView("999,1"), DigitPair, Digits()) === qerr(InvalidData, Overflow)
    @test try_decode(MemoryView("1;2"), DigitPair, Digits()) === qerr(InvalidData)
    @test try_decode(MemoryView("1,"), DigitPair, Digits()) === qerr(InvalidData, NoDigits)
    @test try_load(CursorReader("1,256"), DigitPair, Digits()) === qerr(InvalidData, Overflow)
    @test try_load(CursorReader("1,"), DigitPair, Digits()) === qerr(InvalidData, NoDigits)

    # Different payload types for decoding and encoding
    @test try_decode(MemoryView([0xc3]), Char, Ascii()) === derr(Char, Ascii(), InvalidData, 0xc3)
    @test try_load(CursorReader([0x41, 0xff]), Tuple{Char, Char}, Latin1()) === ('A', 'ÿ')

    # Bits types, with both byte orders
    for (e, bytes) in ((LittleEndian(), [0x02, 0x01]), (BigEndian(), [0x01, 0x02]))
        @test try_decode(MemoryView(bytes), Odd16, e) === derr(Odd16, e, InvalidData, EvenBits(0x0102))
        @test try_load(CursorReader(bytes), Odd16, e) === derr(Odd16, e, InvalidData, EvenBits(0x0102))
        @test_throws derr(Odd16, e, InvalidData, EvenBits(0x0102)) decode(MemoryView(bytes), Odd16, e)
        @test decode(MemoryView(reverse(bytes)), Odd16, e) === Odd16(0x0201)
        @test try_decode(MemoryView(bytes[1:1]), Odd16, e) === derr(Odd16, e, Truncated)
    end
    # Structs pass on the payloads of their fields, and the fields are checked first
    terr(kind, payload = nothing) = derr(Tagged, BigEndian(), kind, payload)
    @test try_decode(MemoryView([0x01, 0x01, 0x01, 0x01]), Tagged, BigEndian()) === Tagged(Odd16(0x0101), true, high)
    @test try_decode(MemoryView([0x01, 0x02, 0x01, 0x00]), Tagged, BigEndian()) === terr(InvalidData, EvenBits(0x0102))
    @test try_decode(MemoryView([0x01, 0x01, 0x02, 0x01]), Tagged, BigEndian()) === terr(InvalidData)
    @test try_decode(MemoryView([0x01, 0x01, 0x00, 0x05]), Tagged, BigEndian()) === terr(InvalidData)
    @test try_decode(MemoryView([0x01, 0x01, 0x01, 0x00]), Tagged, BigEndian()) === terr(InvalidData, Untagged)
    @test try_decode(MemoryView([0x01, 0x01, 0x00, 0x00]), Tagged, BigEndian()) === Tagged(Odd16(0x0101), false, low)
    @test try_load(CursorReader([0x01, 0x01, 0x01, 0x00]), Tagged, BigEndian()) === terr(InvalidData, Untagged)
    @test try_decode(MemoryView([0x01, 0x00, 0x01, 0x00]), Tagged, LittleEndian()) === derr(Tagged, LittleEndian(), InvalidData, Untagged)

    # Tuples pass on the payloads of their elements
    BitsT = Tuple{Odd16, Bool, Level}
    @test try_decode(MemoryView([0x02, 0x00, 0x00, 0x00]), BitsT, LittleEndian()) === derr(BitsT, LittleEndian(), InvalidData, EvenBits(0x0002))
    @test try_decode(MemoryView([0x03, 0x00, 0x02, 0x00]), BitsT, LittleEndian()) === derr(BitsT, LittleEndian(), InvalidData)
    ManualT = Tuple{Bool, Odd16}
    @test try_decode(MemoryView([0x01, 0x00, 0x02]), ManualT, BigEndian()) === derr(ManualT, BigEndian(), InvalidData, EvenBits(0x0002))
    @test try_decode(MemoryView([0x05, 0x00, 0x03]), ManualT, BigEndian()) === derr(ManualT, BigEndian(), InvalidData)
    @test try_load(CursorReader([0x01, 0x00, 0x02]), ManualT, BigEndian()) === derr(ManualT, BigEndian(), InvalidData, EvenBits(0x0002))
    NestedT = Tuple{Tuple{UInt8, Odd16}, Tagged}
    @test try_decode(MemoryView([0x07, 0x02, 0x00, 0x01, 0x00, 0x01, 0x00]), NestedT, LittleEndian()) ===
        derr(NestedT, LittleEndian(), InvalidData, EvenBits(0x0002))
    @test try_decode(MemoryView([0x07, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00]), NestedT, LittleEndian()) ===
        derr(NestedT, LittleEndian(), InvalidData, Untagged)

    # Proxies pass on the payloads of the proxy type, and of `try_from_proxy`
    berr(kind, payload = nothing) = derr(Bounded, LittleEndian(), kind, payload)
    @test try_decode(MemoryView([0x11, 0x00]), Bounded, LittleEndian()) === Bounded(Odd16(0x0011))
    @test try_decode(MemoryView([0x01, 0x20]), Bounded, LittleEndian()) === berr(InvalidData, OutOfRange)
    @test try_decode(MemoryView([0x02, 0x00]), Bounded, LittleEndian()) === berr(InvalidData, EvenBits(0x0002))
    @test try_load(CursorReader([0x01, 0x20]), Bounded, LittleEndian()) === berr(InvalidData, OutOfRange)

    # Bulk functions stop at the first invalid element, and the `_every` functions throw its error
    dst = fill(Odd16(0x0001), 3)
    @test decode_all!(dst, [0x01, 0x00, 0x02, 0x00, 0x03, 0x00], LittleEndian()) == (1, 2)
    @test_throws derr(Odd16, LittleEndian(), InvalidData, EvenBits(0x0002)) decode_every!(dst, [0x01, 0x00, 0x02, 0x00, 0x03, 0x00], LittleEndian())
    @test_throws derr(Odd16, LittleEndian(), InvalidData, EvenBits(0x0002)) load_every!(CursorReader([0x01, 0x00, 0x02, 0x00, 0x03, 0x00]), dst, LittleEndian())
    @test load_all!(CursorReader([0x01, 0x00, 0x02, 0x00]), dst, LittleEndian()) == (1, 2)
    dst = zeros(UInt8, 3)
    @test decode_all!(dst, MemoryView("12 999"), Digits()) == (1, 2)
    @test decode_all!(dst, MemoryView("999"), Digits()) == (0, 0)
    @test_throws perr(InvalidData, Overflow) decode_every!(dst, MemoryView("999"), Digits())
    @test_throws perr(InvalidData, Overflow) load_every!(CursorReader("999"), dst, Digits())
    dst = fill(Tagged(Odd16(0x0001), false, low), 2)
    @test_throws terr(InvalidData, Untagged) decode_every!(dst, [0x01, 0x01, 0x00, 0x00, 0x01, 0x01, 0x01, 0x00], BigEndian())
end

@testset "Encoding with payloads" begin
    aerr(kind, payload = nothing) = eerr(Char, Ascii(), kind, payload)
    @test try_encode!(MemoryView(zeros(UInt8, 1)), 'é', Ascii()) === aerr(InvalidValue, NotAscii('é'))
    @test try_encode!(MemoryView(UInt8[]), 'a', Ascii()) === aerr(InsufficientSpace)
    @test try_store(VecWriter(), 'é', Ascii()) === aerr(InvalidValue, NotAscii('é'))
    @test_throws aerr(InvalidValue, NotAscii('é')) encode!(MemoryView(zeros(UInt8, 1)), 'é', Ascii())
    @test_throws aerr(InvalidValue, NotAscii('é')) store(VecWriter(), 'é', Ascii())
    @test encode_all!(zeros(UInt8, 3), ['a', 'é', 'b'], Ascii()) == (1, 1)
    @test_throws aerr(InvalidValue, NotAscii('é')) encode_every!(zeros(UInt8, 3), ['a', 'é', 'b'], Ascii())
    @test_throws aerr(InvalidValue, NotAscii('é')) store_every(VecWriter(), ['a', 'é', 'b'], Ascii())
    @test store_all(VecWriter(), ['a', 'é', 'b'], Ascii()) == (1, 1)

    # Proxies pass on the payloads of `try_to_proxy`
    berr(kind, payload = nothing) = eerr(Bounded, LittleEndian(), kind, payload)
    @test try_encode!(MemoryView(zeros(UInt8, 2)), Bounded(Odd16(0x2001)), LittleEndian()) === berr(InvalidValue, OutOfRange)
    @test try_store(VecWriter(), Bounded(Odd16(0x2001)), LittleEndian()) === berr(InvalidValue, OutOfRange)
    @test try_encode!(MemoryView(zeros(UInt8, 1)), Bounded(Odd16(0x0001)), LittleEndian()) === berr(InsufficientSpace)
    # Codecs without payloads give `EncodeError{Nothing}`, and types that can always be
    # encoded `EncodeError{Union{}}`
    @test try_encode!(MemoryView(zeros(UInt8, 1)), 'λ', Latin1()) === EncodeError(InvalidValue)
    @test try_encode!(MemoryView(UInt8[]), Odd16(0x0001), LittleEndian()) === EncodeError{Union{}}(InsufficientSpace)
end

@testset "Payloads of undeclared types" begin
    # The type of payloads is checked
    @test try_decode(MemoryView([0x01]), UInt8, Undeclared()) === 0x01
    @test_throws r"codec_decode_invalid_type" try_decode(MemoryView([0x00]), UInt8, Undeclared())
    @test_throws r"codec_decode_invalid_type" try_load(CursorReader([0x00]), UInt8, Undeclared())
    @test_throws r"codec_encode_invalid_type" try_encode!(MemoryView([0x00]), 0x00, Undeclared())
    @test_throws r"codec_encode_invalid_type" try_store(VecWriter(), 0x00, Undeclared())
    # ... also those of fields
    @test try_decode(MemoryView("12"), UInt16, Undeclared()) === UInt16(12)
    @test_throws ErrorException try_decode(MemoryView("x"), UInt16, Undeclared())
    # ... and of `validate_bits`
    @test try_decode(MemoryView([0x01]), WrongPayload8, LittleEndian()) isa WrongPayload8
    @test_throws r"validate_bits" try_decode(MemoryView([0x00]), WrongPayload8, LittleEndian())
    # `Invalid()` is an `Invalid{Nothing}`, which needs a payload type that includes `Nothing`
    @test try_decode(MemoryView([0xff]), UInt8, Bare()) === derr(UInt8, Bare(), InvalidData, Overflow)
    @test try_decode(MemoryView([0x01]), UInt8, Bare()) === 0x01
    err = try
        try_decode(MemoryView([0x00]), UInt8, Bare())
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("returned an `Invalid{Nothing}`", err.msg)
    @test occursin("Union{Nothing, ParseError}", err.msg)
    # ... and the message of another undeclared type suggests the union
    err = try
        try_decode(MemoryView([0x00]), WrongPayload8, LittleEndian())
    catch e
        e
    end
    @test occursin("`Invalid{$Int}`", err.msg) && occursin("Union{Nothing, $Int}", err.msg)
    # `validate_bits` must not return a `Bool`
    @test_throws TypeError try_decode(MemoryView([0x01]), BoolValidated8, LittleEndian())
end

@testset "Showing payloads" begin
    err = try_decode(MemoryView("999"), UInt8, Digits())
    @test sprint(showerror, err) ==
        "DecodeError: Invalid data: the bytes are not a valid encoding of the requested type (payload: Overflow)"
    # How the kinds are shown depends on what is imported
    @test repr(err) == "DecodeError{ParseError}($(repr(InvalidData)), Some(Overflow))"
    @test repr(DecodeError(Truncated)) == "DecodeError($(repr(Truncated)))"
    # Errors whose payload follows from their kind leave it out, but show their type
    @test repr(derr(UInt8, Digits(), Truncated)) == "DecodeError{ParseError}($(repr(Truncated)))"
    @test repr(derr(DigitPair, Digits(), InvalidData)) ==
        "DecodeError{Union{Nothing, ParseError}}($(repr(InvalidData)))"
    @test repr(try_decode(MemoryView(UInt8[]), UInt32, LittleEndian())) == "DecodeError{Union{}}($(repr(EndOfInput)))"
    @test repr(try_decode(MemoryView([0x02]), Bool, LittleEndian())) == "DecodeError($(repr(InvalidData)))"
    # `Invalid()` gives no reason, which is not shown
    @test !occursin("payload", sprint(showerror, try_decode(MemoryView("1;2"), DigitPair, Digits())))
    @test !occursin("payload", sprint(showerror, derr(UInt8, Digits(), Truncated)))
    err = try_store(VecWriter(), 'é', Ascii())
    @test sprint(showerror, err) ==
        "EncodeError: Invalid value: the value can't be encoded with the encoding (payload: NotAscii('é'))"
    @test repr(EncodeError(InvalidValue)) == "EncodeError($(repr(InvalidValue)))"
    @test repr(Invalid()) == "Invalid()"
    @test repr(Invalid(Overflow)) == "Invalid{ParseError}(Overflow)"
    # The errors are shown as values that are equal to them
    for x in (
            DecodeError(Truncated), DecodeError(InvalidData), derr(UInt8, Digits(), InvalidData, Overflow),
            derr(UInt8, Digits(), Truncated), derr(DigitPair, Digits(), InvalidData), derr(UInt32, LittleEndian(), EndOfInput),
            EncodeError(InvalidValue), eerr(Char, Ascii(), InvalidValue, NotAscii('é')), Invalid(), Invalid(Overflow),
        )
        @test eval(Meta.parse(repr(x))) === x
    end
end

@testset "Constructing errors" begin
    # The payload is `Some` exactly for the kinds of invalid data or values
    @test DecodeError(InvalidData).payload === Some(nothing)
    @test DecodeError(EndOfInput).payload === nothing
    @test DecodeError{Union{}}(Truncated) === derr(UInt32, LittleEndian(), Truncated)
    @test DecodeError{Union{Nothing, ParseError}}(InvalidData).payload === Some{Union{Nothing, ParseError}}(nothing)
    @test DecodeError(InvalidData, Some(Overflow)) isa DecodeError{ParseError}
    @test EncodeError(InvalidValue).payload === Some(nothing)
    @test EncodeError(InsufficientSpace).payload === nothing
    @test_throws ArgumentError DecodeError{ParseError}(InvalidData, nothing)
    @test_throws ArgumentError DecodeError{ParseError}(EndOfInput, Some(Overflow))
    @test_throws ArgumentError DecodeError(EndOfInput, Some(Overflow))
    @test_throws ArgumentError EncodeError{NotAscii}(InsufficientSpace, Some(NotAscii('é')))
    # Invalid data without a reason needs a payload type that includes `Nothing`
    @test_throws MethodError DecodeError{ParseError}(InvalidData)
    @test_throws ArgumentError DecodeError{Union{}}(InvalidData)
    # The types of errors
    @test try_decode(MemoryView(UInt8[]), UInt32, LittleEndian()) isa DecodeError{Union{}}
    @test try_decode(MemoryView([0x02]), Bool, LittleEndian()) isa DecodeError{Nothing}
    @test try_decode(MemoryView("999"), UInt8, Digits()) isa DecodeError{ParseError}
    @test try_encode!(MemoryView(UInt8[]), 0x01, LittleEndian()) isa EncodeError{Union{}}
end

@testset "Equality of errors" begin
    # The kind and payload decide equality, not the type
    @test derr(UInt8, Digits(), EndOfInput) == DecodeError(EndOfInput)
    @test hash(derr(UInt8, Digits(), EndOfInput)) == hash(DecodeError(EndOfInput))
    @test isequal(derr(UInt8, Digits(), EndOfInput), DecodeError(EndOfInput))
    @test derr(UInt8, Digits(), InvalidData, Overflow) == DecodeError(InvalidData, Some(Overflow))
    @test derr(UInt8, Digits(), InvalidData, Overflow) != DecodeError(InvalidData)
    @test derr(UInt8, Digits(), InvalidData, Overflow) != derr(UInt8, Digits(), InvalidData, NoDigits)
    @test DecodeError(Truncated) != DecodeError(EndOfInput)
    # Also when the payload types differ, which needs care before Julia 1.12
    wide = DecodeError{Union{Nothing, ParseError}}(InvalidData, Some(Overflow))
    @test wide == DecodeError(InvalidData, Some(Overflow))
    @test hash(wide) == hash(DecodeError(InvalidData, Some(Overflow)))
    @test wide != DecodeError{Union{Nothing, ParseError}}(InvalidData, Some(nothing))
    @test wide != DecodeError(InvalidData)
    @test EncodeError{Union{Nothing, RangeError}}(InvalidValue, Some(OutOfRange)) == EncodeError(InvalidValue, Some(OutOfRange))
    @test eerr(Char, Ascii(), InsufficientSpace) == EncodeError(InsufficientSpace)
    @test hash(eerr(Char, Ascii(), InsufficientSpace)) == hash(EncodeError(InsufficientSpace))
    @test eerr(Char, Ascii(), InvalidValue, NotAscii('é')) != EncodeError(InvalidValue)
    @test length(Set([DecodeError(Truncated), derr(UInt8, Digits(), Truncated), DecodeError(EndOfInput)])) == 2
end

@testset "Payloads don't allocate" begin
    function count_overflows(mem)
        k = 0
        for i in 1:(length(mem) - 2)
            x = try_decode(mem, i, UInt8, Digits())
            x isa DecodeError && x == DecodeError(InvalidData, Some(Overflow)) && (k += 1)
        end
        return k
    end
    function count_untagged(mem)
        k = 0
        for i in 1:4:(length(mem) - 3)
            x = try_decode(mem, i, Tagged, BigEndian())
            x isa DecodeError && x == DecodeError(InvalidData, Some(Untagged)) && (k += 1)
        end
        return k
    end
    function count_out_of_range(io, xs)
        k = 0
        for x in xs
            r = try_store(io, x, LittleEndian())
            r isa EncodeError && r == EncodeError(InvalidValue, Some(OutOfRange)) && (k += 1)
        end
        return k
    end
    mem = ImmutableMemoryView(collect(codeunits("999 12 300 7 999")))
    @test count_overflows(mem) == 3
    @test_allocs (@allocated count_overflows(mem)) == 0
    tagged = ImmutableMemoryView(repeat([0x01, 0x01, 0x01, 0x00], 50))
    @test count_untagged(tagged) == 50
    @test_allocs (@allocated count_untagged(tagged)) == 0
    xs = MemoryView([Bounded(Odd16(0x2001)), Bounded(Odd16(0x0001))])
    io = VecWriter(sizehint!(UInt8[], 100))
    @test count_out_of_range(io, xs) == 1
    empty!(io.vec)
    @test_allocs (@allocated count_out_of_range(io, xs)) == 0
end
