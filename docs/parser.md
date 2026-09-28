# Parsing backend decision

Evaluated [Hejsil/zig-clap](https://github.com/Hejsil/zig-clap), specifically release 0.12.0 at `8d97efa1ee1e575443c7888d5c38e1c3fc145cf5`, before implementing a parser. Its streaming interface accepts parameter metadata and a slice iterator; it can support generated descriptors, long and short flags, groups, assigned values, and `--`. A separate help-intent pass is still needed to guarantee help wins over invalid input and missing values. Conversion, environment/config precedence, output schemas, prompt policy and handler execution belong above the parser.

The inspected master (`05faf3905e8548f5cc269a8836e154065e70128d`) declares a compiler minimum beyond the initially selected versions. 0.12.0 declares a 0.16 development minimum and was the proposed dependency pin.

During implementation the user required **no dependencies outside their ownership**. That excludes zig-clap, so it is not in the package, imports, vendored tree or runtime. `src/parser.zig` is a small implementation owned by this project, written for the intentionally bounded feature set. No zig-clap source is copied or vendored. This decision is about the dependency constraint, not a claim that zig-clap is unsuitable.

Supported: exact long names, single-letter names, short groups, attached or separated required values, explicit boolean assignments, and the argument terminator. Application-option duplicates are rejected by the runtime. Abbreviations and implicit command fallbacks are intentionally absent. Commands take named options plus, optionally, one list of positional arguments. Tests cover negative numbers, overflow, malformed values, duplicate options, terminators and grouped shorts.

Only zrich is an external package. Python is a development-time standard-library test runner, not an application dependency.
