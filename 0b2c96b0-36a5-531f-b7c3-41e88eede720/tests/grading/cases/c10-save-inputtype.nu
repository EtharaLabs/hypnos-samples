def "to zork" []: string -> string { "string" }
try { {a: 1} | save -f d.zork; "saved" } catch {|e| $e.msg }
