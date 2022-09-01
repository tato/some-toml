### sometoml
- is a toml v1.0.0 library for zig 
- supports serialization and deserialization
- is still in early stages

### not yet implemented
- date types
- good error reporting

### also planned
- deserializing into arbitrary zig structs
- customizable serializing and deserializing
- and then, who knows???

### how to use it
- `git submodule add https://github.com/tato/sometoml`
- `exe.addPackagePath("toml", "sometoml/toml.zig");`
- `const toml = @import("toml");`
- `const doc = toml.parse(allocator, reader);`

<details>
  <summary><h3>but first, take a breather</h3></summary>
  <video src=https://user-images.githubusercontent.com/14120644/185344106-a0aa03bb-82a7-4b06-b295-3aa55bb32756.mp4></video>
</details>

<p align=center>🙌
