- this is primarily a jj repo. git is colocated. stick to jj when possible

## Codestyle
- prefer explicit control flow and composition in callers
- order items in order of most to least relevant for a top-down reader.
- prefer procedural, data oriented, zig-like style
- prefer scoped local imports and then go-style imports over naked ones.
- prefer tigerbeetle style big endian names but don't take this to the extreme.
- use obvious abbreviations like tx, sigs, etc.
- prefer shorter words

## For medius-to-large code additions
1. write out a procedural repetitive plain version of the code.
2. check this version for correctness and low-hanging performance gains.
3. assess whether a semantic compression abstraction is necessary for
   maintainability and readability.
4. optionally apply this compression without any important change in semantics.
