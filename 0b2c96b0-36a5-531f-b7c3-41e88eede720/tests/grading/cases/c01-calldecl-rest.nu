def joinall [sep: string, ...words: string] { $words | str join $sep }
example call-decl joinall {} '-' a b c
