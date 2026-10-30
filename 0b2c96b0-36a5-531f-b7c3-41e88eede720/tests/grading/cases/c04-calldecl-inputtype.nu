def bump []: int -> int { $in + 1 }
[(5 | example call-decl bump) (try { "text" | example call-decl bump } catch {|e| $e.msg })]
