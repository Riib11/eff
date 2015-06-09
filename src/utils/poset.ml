module type Parameter =
sig
  type t

  val compare : t -> t -> int
  val print : t -> Format.formatter -> unit
end


module type S =
sig
  type elt
  type t

  val empty : t
  val add : elt -> elt -> t -> t
  val merge : t -> t -> t
  val fold : (elt -> elt -> 'a -> 'a) -> t -> 'a -> 'a
  val filter : (elt -> elt -> bool) -> t -> t
  val get_prec : elt -> t -> elt list
  val get_succ : elt -> t -> elt list
  val map : (elt -> elt) -> t -> t
  val print : t -> Format.formatter -> unit
end


module Make (Elt : Parameter) : S with type elt = Elt.t =
struct
  type elt = Elt.t

  module EltSet = Set.Make(Elt)
  module EltMap = Map.Make(Elt)

  type related = {
    smaller : EltSet.t;
    greater : EltSet.t;
  }

  type t = related EltMap.t

  let empty = EltMap.empty

  let empty_related = {
    smaller = EltSet.empty;
    greater = EltSet.empty;
  }

  let get_related x poset =
    try
      EltMap.find x poset
    with
      Not_found -> empty_related

  let add x y poset =
    if compare x y = 0 then
      poset
    else
      let related_to_x = get_related x poset
      and related_to_y = get_related y poset in
      let new_smaller = EltSet.add x (EltSet.diff related_to_x.smaller related_to_y.smaller)
      and new_greater = EltSet.add y (EltSet.diff related_to_y.greater related_to_x.greater) in
      let poset = if EltMap.mem x poset then poset else EltMap.add x empty_related poset in
      let poset = if EltMap.mem y poset then poset else EltMap.add y empty_related poset in
      EltMap.mapi (fun z related_to_z ->
        if EltSet.mem z new_smaller then
          {related_to_z with greater = EltSet.remove z (EltSet.union related_to_z.greater new_greater)}
        else if EltSet.mem z new_greater then
          {related_to_z with smaller = EltSet.remove z (EltSet.union related_to_z.smaller new_smaller)}
        else
          related_to_z
      ) poset

  let fold f poset =
    EltMap.fold (fun x {greater} acc ->
      EltSet.fold (fun y acc -> f x y acc) greater acc
    ) poset

  let merge poset1 poset2 = fold add poset1 poset2

  let filter p poset = fold (fun x y poset ->
    if p x y then add x y poset else poset
  ) poset empty

  let get_prec x poset = EltSet.elements (get_related x poset).smaller

  let get_succ x poset = EltSet.elements (get_related x poset).greater

  let map f poset = fold (fun x y -> add (f x) (f y)) poset empty

  let print poset ppf =
    fold (fun x y _ -> Format.fprintf ppf "%t < %t" (Elt.print x) (Elt.print y)) poset ()
end