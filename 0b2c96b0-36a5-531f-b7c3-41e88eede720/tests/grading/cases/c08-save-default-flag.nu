def "to zork" [--prefix: string = "P:", --loud] { let s = $"($prefix)($in | length)"; if $loud { $s | str upcase } else { $s } }
[1 2 3] | save -f c.zork
open --raw c.zork
