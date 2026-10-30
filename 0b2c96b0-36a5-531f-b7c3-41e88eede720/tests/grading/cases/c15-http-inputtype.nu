def "from zork" []: int -> int { $in + 1 }
try { http get http://127.0.0.1:18731/data } catch {|e| $e.msg }
