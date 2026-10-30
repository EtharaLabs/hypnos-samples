def "to zork" [] { $env.ZORK_PLAIN = "leaked"; $in | to json --raw }
def --env "to zenv" [] { $env.ZORK_KEPT = "kept"; $in | to json --raw }
[1 2] | save -f a.zork
[3 4] | save -f b.zenv
{plain: ($env.ZORK_PLAIN? | default "contained"), env: ($env.ZORK_KEPT? | default "lost"), a: (open --raw a.zork), b: (open --raw b.zenv)}
