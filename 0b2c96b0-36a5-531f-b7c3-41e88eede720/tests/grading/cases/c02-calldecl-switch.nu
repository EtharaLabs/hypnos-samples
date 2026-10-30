def shout [word: string, --loud] { if $loud { $word | str upcase } else { $word } }
[(example call-decl shout {loud: true} hey) (example call-decl shout {} hey)]
