module Ty = struct
  include Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "ty"

  let utf8_symbol = "\207\132"
  end))

  let print_type_param t ppf = fold (
    fun _ n -> Format.fprintf ppf "'t%d" n
  ) t

  let print_old ?(poly= []) k ppf = 
    let c = if List.mem k poly then "'" else "'_" in
    fold (fun _ k ->
      if 0 <= k && k <= 25 then
        Format.fprintf ppf "%s%c" c (char_of_int (k + int_of_char 'a'))
      else Format.fprintf ppf "%sty%i" c (k - 25)
    ) k
end

module ETy = Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "ety"

  let utf8_symbol = "e\207\132"
end))

module Dirt = Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "drt"

  let utf8_symbol = "\206\180"
end))

module Skel = Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "skl"

  let utf8_symbol = "s"
end))

module TyCoercion = Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "tycoer"

  let utf8_symbol = "\207\132ycoer"
end))

module DirtCoercion = Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "dirtcoer"

  let utf8_symbol = "dirtcoer"
end))

module DirtyCoercion = Symbol.Make (Symbol.Parameter (struct
  let ascii_symbol = "dirtycoer"

  let utf8_symbol = "dirtycoer"
end))
