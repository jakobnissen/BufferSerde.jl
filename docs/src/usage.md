# Reading and writing with Inscription.jl
Reading and writing happens fundamentally via encoding into and decoding from MemoryViews.jl's `MemoryView` type.
Loading from and storing to BufferIO.jl's `AbstractBufReader` and `AbstractBufWriter` works via encoding and decoding from memory views into their buffers.

When loading and storing from BufferIO I/O types, you can always manually request their buffer, encode into/decode from the buffer, then call `BufferIO.consume`. This can be used as an escape hatch to load and store types not easily handled by Inscription.jl, such as bit-packed types (see the [Implementing a type](custom.md) page).
It can also be used in extremely performance-sensitive situations when you can request a large buffer, do a single boundscheck, then load many values inbounds.
However, most users should just use the Inscription functions below, as they are usually fast enough, and cover most use cases.

# Encoding and decoding
*Encoding* and *decoding* here means reading from / writing to `MemoryViews`, whereas *loading* and *storing* refers to reading from / writing to BufferIO types.

The functions mentioned below: [`encode!`](@ref), [`decode`](@ref), [`decode_exact`](@ref) and [`decode_next`](@ref) each have `try_*` versions. The plain functions throw exceptions on errors, whereas the `try_` versions return the exception instead. On the happy path, the throwing versions are slightly more efficient, so use the `try_` versions only if you plan to actually handle errors.

### Decoding values
The decoding signatures are generally: `(try_)decode(_exact,_next)(mem, [i::Integer,] ::Type{T}, enc::Encoding)`, and they mean: Decode a `T` from `mem` starting at position `i`, with the given `Encoding`, and return the `T` (or an error, for the `try_` variant).
Like the encoding functions, `mem` is converted to an `ImmutableMemoryView{UInt8}`, and `i` defaults to 1 if omitted.

Example: `decode(UInt8[1,2,3,4], UInt32, LittleEndian()) === 0x04030201`

The function [`decode_next`](@ref) returns `Tuple{T, Int}` (or an error, for the `try_` variant), with the `Int` giving the index immediately after the `T`, in `mem`. This way, you know how many bytes were read.
This is useful if the `T` is stored in a variable number of bytes, for example a `Char` in the `UTF8` encoding.

The function [`decode_exact`](@ref) throws an error if `mem` contains any trailing data. This can be used to ensure `mem` contains exactly the `T`.
E.g. a hypothetical decimal integer decoder would fail on the input memory "123abc", as "abc" is not a valid decimal integer, whereas the normal `decode` would read the three bytes and return `123`.

### Encoding values
Encoding functions generally have the signature `(try_)encode!(mem, [i::Integer], x, ::Encoding)`, and they mean: Encode `x` into `mem` starting at position `i` with the given `Encoding`, and return how many bytes were written (or an error, for the `try_` variant).
The argument `mem` is converted to a `MutableMemoryView{UInt8}`.
If `i` is omitted, it defaults to `1`.

Example: `encode!(zeros(UInt8, 4), UInt32(55), LittleEndian()) === 4`

To find the number of bytes a value `x` takes up in some encoding, encode it: `try_encode!` returns the number of bytes written.

## Bulk encoding and decoding
When encoding or decoding multiple values together, it can be more efficient to encode or decode entire arrays of values in bulk.
For trivial codecs, this may be compiled to a `memmove`, or be vectorized.

[`encode_every!`](@ref)`(dst, src, ::Encoding)::Int` constructs a `MutableMemoryView{UInt8}` from `dst`, an `ImmutableMemoryView{T}` from `src`, and then encodes all values from `src` to `dst`, returning the number of bytes written. If `dst` cannot hold all values, throw a bounds error. For other errors, throw an [`EncodeError`](@ref).

The function [`decode_every!`](@ref) is analogous, except returning the number of bytes read, and throwing a [`DecodeError`](@ref) on insufficient input, or an invalid encoding.

If you don't want to handle exceptions, [`encode_all!`](@ref) and [`decode_all!`](@ref) stop at the first error, and return `(n_elements_encoded, n_bytes_written)` and `(n_elements_decoded, n_bytes_read)`, respectively. These bulk functions have no `try_` equivalents: To see the error that stopped them, use [`try_encode!`](@ref) or [`try_decode`](@ref) at the first index after the bytes used.

# Loading and storing
As mentioned above, you can use the functions below to load and store directly, without manually handling buffers.

[`load`](@ref)`(::AbstractBufReader, ::Type{T}, ::Encoding)` and [`store`](@ref)`(::AbstractBufWriter, x::T, ::Encoding)` are similar to encoding and decoding, except that they load from and store to the reader and writer, respectively, and advance their state (i.e. call `consume` internally).
These loads and stores are all or nothing, not in the sense of promising to be single atomic operations on a CPU level, but in that, if the operation fails, no bytes are read from, or written to, the I/O object.

The above throwing functions also have [`try_load`](@ref) and [`try_store`](@ref) equivalents. Like the encoding/decoding functions, they are slightly less efficient.

In the rare case the stream you read from is not self-synchronizing - that is, it's not clear from the data where the value ends, [`load_exact`](@ref)`(::AbstractBufReader, n::Integer, ::Type{T}, ::Encoding)` and [`try_load_exact`](@ref) read a `T` from exactly `n` bytes of the reader.
Consider a hypothetical `Decimal` integer codec where the string "123" can be read as (1, 2, 3), (12, 3), (1, 23), or 123.
Using `load` or `try_load`, the maximal length would be read, so 123 would be returned. To load (12, 3) instead, use `load_exact(io, 2, Int, Decimal())` then `load_exact(io, 1, Int, Decimal())`.

## Bulk loading and storing
These functions internally use the bulk encoding and decoding functions, and so may be more efficient, for example when filling arrays.

The function [`load_into!`](@ref)`(::AbstractBufReader, dst, ::Encoding)` builds a `MutableMemoryView{T}` from `dst`, then reads data of type `T` into `dst`, and returns `(n_elements_loaded, n_bytes_read)`.
It stops, without throwing, if `dst` has no more space, the reader is at EOF, or the next element cannot be decoded.
Like the bulk encoding/decoding functions, it has no `try_` equivalent. To see why it stopped, check the length of `dst`, check whether the reader is at EOF, and call [`try_load`](@ref) to see the error.

The number of elements loaded is decided by the implementation of the reader. The reader knows the optimal buffer size, so delegating the amount read per call to the reader improves performance.
However, to guarantee forward progress, this function loads zero elements only if it is stopped by one of the above reasons, i.e. the reader cannot decide a buffer size of zero.

Use this function when you process a larger array in chunks, but have no strong opinion on the chunk size yourself.
For example, a hashing function might need to process a large byte array, but operate on chunks of 8 `UInt64` values per round.
Here, you could call `load_into!` in a loop until at least 8 elements have been loaded (which, in the vast majority of cases, will happen after a single call), then process that chunk.

The function [`store_into`](@ref) is the mirror image: It writes to an `AbstractBufWriter`, reads from `src`, and returns `(n_elements_read, n_bytes_written)`. Like `load_into!`, the number of elements is an implementation detail (but nonzero, unless prevented), and there is no `try_` equivalent.

The functions [`load_every!`](@ref) and [`store_every`](@ref) are similar to `load_into!` and `store_into`, but continue until `dst` is filled, or `src` is exhausted. If an element cannot be decoded or encoded, or there is no room in the writer, or there are not enough bytes in the reader, throw an exception.
That is, these functions use the entire array passed to it instead of delegating choice of buffer size to the reader/writer type.
Use these functions if you need to process the entire array before continuing.

Finally, [`load_all!`](@ref) and [`store_all`](@ref) are similar to `load_every!` and `store_every`, but stop early instead of throwing when an element cannot be encoded/decoded, or there are not enough bytes in the reader or room in the writer. You can then use `try_load` and `try_store` to get the error.

### Boundschecks when loading and storing
Unlike the encode and decode functions, load and store functions do not respect `@inbounds` (they always boundscheck).
This may be undesirable when reading many small chunks of data, where optimal performance is needed.
In these cases, consider getting a buffer, then decoding with `@inbounds`, then calling `consume` manually.

For example, to read 3 `UInt64` from a reader, you may do:

```julia
using BufferIO: AbstractBufReader, get_nonempty_buffer, consume
using Inscription: Inscription, decode, LittleEndian, DecodeError
using Inscription.DecodeErrorKinds: EndOfInput

function get_three_u64(io::AbstractBufReader)
    # Throw a DecodeError if EOF is reached before 24 bytes
    buffer = @something get_nonempty_buffer(io, 24) throw(DecodeError(EndOfInput))
    # For methods generic over AbstractBufReader, guard against
    # invalid implementations of get_nonempty_buffer, like here:
    length(buffer) < 24 && error("Invalid implementation of get_nonempty_buffer")
    @inbounds begin
        values = (
            decode(buffer,  1, UInt64, LittleEndian()),
            decode(buffer,  9, UInt64, LittleEndian()),
            decode(buffer, 17, UInt64, LittleEndian()),
        )
    end
    consume(io, 24)
    return values
end
```

The above could also be done directly with `try_load(io, NTuple{3, UInt64}, LittleEndian())`,
so the example above is only for demonstration purposes.

## Endian convenience namespaces
The most common format for reading and writing values are the native binary representation. In Inscription, these are the encodings `LittleEndian()` and `BigEndian()`. When working with e.g. exclusively little-endian data, it's annoying to have to pass `LittleEndian()` as the `Encoding` to all functions.

Inscription provides the modules `Inscription.Little` and `Inscription.Big`, which export convenience functions that automatically forward `LittleEndian()` and `BigEndian()`, such that e.g.:

```julia
using Inscription.Little: encode!

encode!(mem, UInt32(123))
```

Is shorthand for:

```julia
using Inscription: encode!

encode!(mem, UInt32(123), LittleEndian())
```

In all examples below, I will use the more verbose `encode!(mem, UInt32(123), LittleEndian())` for clarity.
The full list of functions in these modules is on the [Reference](reference.md) page.


### Handling errors
The `try_*` functoin may return [`DecodeError`](@ref) or [`EncodeError`](@ref) - the same exceptions thrown by the non-`try_*` functions.


These errors currently have two public properties: A `.kind` property, and a `.payload` property.
The `.kind` is [`DecodeErrorKind`](@ref Inscription.DecodeErrorKinds.DecodeErrorKind) or [`EncodeErrorKind`](@ref Inscription.EncodeErrorKinds.EncodeErrorKind) - enums stating what went wrong.
The `.payload` is `Union{Nothing, Some{T}}` - `nothing` unless `.kind` is `InvalidData` (for decoding errors) or `InvalidValue` (for encoding errors).

This allow codecs to return specific errors saying why a value could not be decoded or encoded.
For example, a codec that parses decimal integers may give the payload `Some(Overflow)`, so that you can try again with a wider type.
A codec that that gives no reason for its failure will typically gives the payload `Some(nothing)`.
