def greet [name: string, --greeting: string = "hello", --times: int = 2] { 1..$times | each { $"($greeting) ($name)" } | str join ", " }
[(example call-decl greet {} bob) (example call-decl greet {greeting: hi, times: 1} amy)]
