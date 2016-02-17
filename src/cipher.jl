## Defines all cipher functionality
## As usual, check out
#http://www.lysator.liu.se/~nisse/nettle/nettle.html#Cipher-functions

import Base: show
export CipherType, get_cipher_types
export gen_key32_iv16, add_padding_PKCS5, trim_padding_PKCS5
export Encryptor, Decryptor, decrypt, decrypt!, encrypt, encrypt!

# This is a mirror of the nettle-meta.h:nettle_cipher struct
immutable NettleCipher
    name::Ptr{UInt8}
    context_size::Cuint
    block_size::Cuint
    key_size::Cuint
    set_encrypt_key::Ptr{Void}
    set_decrypt_key::Ptr{Void}
    encrypt::Ptr{Void}
    decrypt::Ptr{Void}
end

# For much the same reasons as in hash_common.jl, we define a separate, more "Julia friendly" type
immutable CipherType
    name::AbstractString
    context_size::Cuint
    block_size::Cuint
    key_size::Cuint
    set_encrypt_key::Ptr{Void}
    set_decrypt_key::Ptr{Void}
    encrypt::Ptr{Void}
    decrypt::Ptr{Void}
end

# These are the user-facing types that are used to actually {en,de}cipher stuff
immutable Encryptor
    cipher_type::CipherType
    state::Array{UInt8,1}
end
immutable Decryptor
    cipher_type::CipherType
    state::Array{UInt8,1}
end

# The function that maps from a NettleCipher to a CipherType
function CipherType(nc::NettleCipher)
    CipherType( uppercase(bytestring(nc.name)),
                nc.context_size, nc.block_size, nc.key_size,
                nc.set_encrypt_key, nc.set_decrypt_key, nc.encrypt, nc.decrypt)
end

# The global dictionary of hash types we know how to construct
const _cipher_types = Dict{AbstractString,CipherType}()

# We're going to load in each NettleCipher struct individually, deriving
# HashAlgorithm types off of the names we find, and storing the output
# and context size from the data members in the C structures
function get_cipher_types()
    # If we have already gotten the hash types from libnettle, don't query again
    if isempty(_cipher_types)
        cipher_idx = 1
        # nettle_ciphers is an array of pointers ended by a NULL pointer, continue reading hash types until we hit it
        while( true )
            ncptr = unsafe_load(cglobal(("nettle_ciphers",nettle),Ptr{Ptr{Void}}),cipher_idx)
            if ncptr == C_NULL
                break
            end
            cipher_idx += 1
            nc = unsafe_load(convert(Ptr{NettleCipher}, ncptr))
            cipher_type = CipherType(nc)
            _cipher_types[cipher_type.name] = cipher_type
        end
    end
    return _cipher_types
end

function gen_key32_iv16(pw::Array{UInt8,1}, salt::Array{UInt8,1})
    s1 = digest("MD5", [pw; salt])
    s2 = digest("MD5", [s1; pw; salt])
    s3 = digest("MD5", [s2; pw; salt])
    return ([s1; s2], s3)
end

function add_padding_PKCS5(data::Array{UInt8,1}, block_size::Int)
  padlen = block_size - (endof(data) % block_size)
  # return [data; map(i -> UInt8(padlen), 1:padlen)]
  return [data; convert(Array{UInt8,1}, map(i -> padlen, 1:padlen))] # to pass test julia 0.3
end

function trim_padding_PKCS5(data::Array{UInt8,1})
  padlen = data[endof(data)]
  return data[1:endof(data)-padlen]
end

function Encryptor(name::AbstractString, key)
    cipher_types = get_cipher_types()
    name = uppercase(name)
    if !haskey(cipher_types, name)
        throw(ArgumentError("Invalid cipher type $name: call Nettle.get_cipher_types() to see available list"))
    end
    cipher_type = cipher_types[name]

    if endof(key) != cipher_type.key_size
        throw(ArgumentError("Key must be $(cipher_type.key_size) bytes long"))
    end

    state = Array(UInt8, cipher_type.context_size)
    if nettle_major_version >= 3
        ccall( cipher_type.set_encrypt_key, Void, (Ptr{Void}, Ptr{UInt8}), state, pointer(key))
    else
        ccall( cipher_type.set_encrypt_key, Void, (Ptr{Void}, Cuint, Ptr{UInt8}), state, endof(key), pointer(key))
    end

    return Encryptor(cipher_type, state)
end

function Decryptor(name::AbstractString, key)
    cipher_types = get_cipher_types()
    name = uppercase(name)
    if !haskey(cipher_types, name)
        throw(ArgumentError("Invalid cipher type $name: call Nettle.get_cipher_types() to see available list"))
    end
    cipher_type = cipher_types[name]

    if endof(key) != cipher_type.key_size
        throw(ArgumentError("Key must be $(cipher_type.key_size) bytes long"))
    end

    state = Array(UInt8, cipher_type.context_size)
    if nettle_major_version >= 3
        ccall( cipher_type.set_decrypt_key, Void, (Ptr{Void}, Ptr{UInt8}), state, pointer(key))
    else
        ccall( cipher_type.set_decrypt_key, Void, (Ptr{Void}, Cuint, Ptr{UInt8}), state, endof(key), pointer(key))
    end

    return Decryptor(cipher_type, state)
end

function decrypt!(state::Decryptor, e::Symbol, iv::Array{UInt8,1}, result, data)
    if endof(result) < endof(data)
        throw(ArgumentError("Output array of length $(endof(result)) insufficient for input data length ($(endof(data)))"))
    end
    if endof(result) % state.cipher_type.block_size > 0
        throw(ArgumentError("Output array of length $(endof(result)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    if endof(data) % state.cipher_type.block_size > 0
        throw(ArgumentError("Input array of length $(endof(data)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    if e != :CBC throw(ArgumentError("now supports CBC only")) end
    iiv = copy(iv)
    ccall((:nettle_cbc_decrypt, nettle), Void, (
        Ptr{Void}, Ptr{Void}, Csize_t, Ptr{UInt8},
        Csize_t, Ptr{UInt8}, Ptr{UInt8}),
        state.state, state.cipher_type.decrypt, endof(iiv), iiv,
        sizeof(data), pointer(result), pointer(data))
    return result
end

function decrypt!(state::Decryptor, result, data)
    if endof(result) < endof(data)
        throw(ArgumentError("Output array of length $(endof(result)) insufficient for input data length ($(endof(data)))"))
    end
    if endof(result) % state.cipher_type.block_size > 0
        throw(ArgumentError("Output array of length $(endof(result)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    if endof(data) % state.cipher_type.block_size > 0
        throw(ArgumentError("Input array of length $(endof(data)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    ccall(state.cipher_type.decrypt, Void, (Ptr{Void},Csize_t,Ptr{UInt8},Ptr{UInt8}),
        state.state, sizeof(data), pointer(result), pointer(data))
    return result
end

function decrypt(state::Decryptor, e::Symbol, iv::Array{UInt8,1}, data)
    result = Array(UInt8, endof(data))
    decrypt!(state, e, iv, result, data)
    return result
end

function decrypt(state::Decryptor, data)
    result = Array(UInt8, endof(data))
    decrypt!(state, result, data)
    return result
end

function encrypt!(state::Encryptor, e::Symbol, iv::Array{UInt8,1}, result, data)
    if endof(result) < endof(data)
        throw(ArgumentError("Output array of length $(endof(result)) insufficient for input data length ($(endof(data)))"))
    end
    if endof(result) % state.cipher_type.block_size > 0
        throw(ArgumentError("Output array of length $(endof(result)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    if endof(data) % state.cipher_type.block_size > 0
        throw(ArgumentError("Input array of length $(endof(data)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    if e != :CBC throw(ArgumentError("now supports CBC only")) end
    iiv = copy(iv)
    ccall((:nettle_cbc_encrypt, nettle), Void, (
        Ptr{Void}, Ptr{Void}, Csize_t, Ptr{UInt8},
        Csize_t, Ptr{UInt8}, Ptr{UInt8}),
        state.state, state.cipher_type.encrypt, endof(iiv), iiv,
        sizeof(data), pointer(result), pointer(data))
    return result
end

function encrypt!(state::Encryptor, result, data)
    if endof(result) < endof(data)
        throw(ArgumentError("Output array of length $(endof(result)) insufficient for input data length ($(endof(data)))"))
    end
    if endof(result) % state.cipher_type.block_size > 0
        throw(ArgumentError("Output array of length $(endof(result)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    if endof(data) % state.cipher_type.block_size > 0
        throw(ArgumentError("Input array of length $(endof(data)) must be N times $(state.cipher_type.block_size) bytes long"))
    end
    ccall(state.cipher_type.encrypt, Void, (Ptr{Void},Csize_t,Ptr{UInt8},Ptr{UInt8}),
        state.state, sizeof(data), pointer(result), pointer(data))
    return result
end

function encrypt(state::Encryptor, e::Symbol, iv::Array{UInt8,1}, data)
    result = Array(UInt8, endof(data))
    encrypt!(state, e, iv, result, data)
    return result
end

function encrypt(state::Encryptor, data)
    result = Array(UInt8, endof(data))
    encrypt!(state, result, data)
    return result
end

# The one-shot functions that make this whole thing so easy
decrypt(name::AbstractString, key, data) = decrypt(Decryptor(name, key), data)
encrypt(name::AbstractString, key, data) = encrypt(Encryptor(name, key), data)

decrypt(name::AbstractString, e::Symbol, iv::Array{UInt8,1}, key, data) = decrypt(Decryptor(name, key), e, iv, data)
encrypt(name::AbstractString, e::Symbol, iv::Array{UInt8,1}, key, data) = encrypt(Encryptor(name, key), e, iv, data)

# Custom show overrides make this package have a little more pizzaz!
function show(io::IO, x::CipherType)
    write(io, "$(x.name) Cipher\n")
    write(io, "  Context size: $(x.context_size) bytes\n")
    write(io, "  Block size: $(x.block_size) bytes\n")
    write(io, "  Key size: $(x.key_size) bytes")
end
show(io::IO, x::Encryptor) = write(io, "$(x.cipher_type.name) Encryption state")
show(io::IO, x::Decryptor) = write(io, "$(x.cipher_type.name) Decryption state")
