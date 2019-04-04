(* Evaluation of the intermediate language, big step. *)
open CoreUtils
module V = Value
module Untyped = UntypedSyntax

exception PatternMatch of Location.t

let help_text =
  "Toplevel commands:\n"
  ^ "#type <expr>;;     print the type of <expr> without evaluating it\n"
  ^ "#reset;;           forget all definitions (including pervasives)\n"
  ^ "#help;;            print this help\n" ^ "#quit;;            exit eff\n"
  ^ "#use \"<file>\";;  load commands from file\n"



module Backend : BackendSignature.T = struct
  module RuntimeEnv = Map.Make (CoreTypes.Variable)

  type state = Value.value RuntimeEnv.t

  let initial_state = RuntimeEnv.empty

  (* Auxiliary functions *)
  let update x = RuntimeEnv.add x

  let lookup x env = try Some (RuntimeEnv.find x env) with Not_found -> None

  let rec extend_value p v env =
    match (p.it, v) with
    | Untyped.PVar x, v -> update x v env
    | Untyped.PAnnotated (p, t), v -> extend_value p v env
    | Untyped.PAs (p, x), v ->
        let env = extend_value p v env in
        update x v env
    | Untyped.PNonbinding, _ -> env
    | Untyped.PTuple ps, Value.Tuple vs ->
        List.fold_right2 extend_value ps vs env
    | Untyped.PRecord ps, Value.Record vs -> (
        let extender env (f, p) =
          match Assoc.lookup f vs with
          | None -> raise Not_found
          | Some v -> extend_value p v env
        in
        try Assoc.fold_left extender env ps with Not_found ->
          raise (PatternMatch p.at) )
    | Untyped.PVariant (lbl, None), Value.Variant (lbl', None) when lbl = lbl' ->
        env
    | Untyped.PVariant (lbl, Some p), Value.Variant (lbl', Some v)
      when lbl = lbl' ->
        extend_value p v env
    | Untyped.PConst c, Value.Const c' when Const.equal c c' -> env
    | _, _ -> raise (PatternMatch p.at)
  
  let extend p v env =
    try extend_value p v env with PatternMatch loc ->
      Error.runtime "Pattern match failure."
  
  let rec sequence k = function
    | V.Value v -> k v
    | V.Call (op, v, k') ->
        let k'' u = sequence k (k' u) in
        V.Call (op, v, k'')
  
  let rec ceval env c =
    let loc = c.at in
    match c.it with
    | Untyped.Apply (e1, e2) -> (
        let v1 = veval env e1 and v2 = veval env e2 in
        match v1 with
        | V.Closure f -> f v2
        | _ -> Error.runtime "Only functions can be applied." )
    | Untyped.Value e -> V.Value (veval env e)
    | Untyped.Match (e, cases) ->
        let v = veval env e in
        let rec eval_case = function
          | [] -> Error.runtime "No branches succeeded in a pattern match."
          | a :: lst -> (
              let p, c = a in
              try ceval (extend_value p v env) c with PatternMatch _ ->
                eval_case lst )
        in
        eval_case cases
    | Untyped.Handle (e, c) ->
        let v = veval env e in
        let r = ceval env c in
        let h = V.to_handler v in
        h r
    | Untyped.Let (lst, c) -> eval_let env lst c
    | Untyped.LetRec (defs, c) ->
        let env = extend_let_rec env (Assoc.of_list defs) in
        ceval env c
    | Untyped.Check c ->
        let r = ceval env c in
        Print.check ~loc "%t" (Value.print_result r) ;
        V.unit_result
  
  and eval_let env lst c =
    match lst with
    | [] -> ceval env c
    | (p, d) :: lst ->
        let r = ceval env d in
        sequence (fun v -> eval_let (extend p v env) lst c) r
  
  and extend_let_rec env defs =
    let env' = ref env in
    let env =
      Assoc.fold_right
        (fun (f, a) env ->
          let p, c = a in
          let g = V.Closure (fun v -> ceval (extend p v !env') c) in
          update f g env )
        defs env
    in
    env' := env ;
    env
  
  and veval env e =
    match e.it with
    | Untyped.Var x -> (
      match lookup x env with
      | Some v -> v
      | None ->
          Error.runtime "Name %t is not defined." (CoreTypes.Variable.print x) )
    | Untyped.Const c -> V.Const c
    | Untyped.Annotated (t, ty) -> veval env t
    | Untyped.Tuple es -> V.Tuple (List.map (veval env) es)
    | Untyped.Record es -> V.Record (Assoc.map (fun e -> veval env e) es)
    | Untyped.Variant (lbl, None) -> V.Variant (lbl, None)
    | Untyped.Variant (lbl, Some e) -> V.Variant (lbl, Some (veval env e))
    | Untyped.Lambda a -> V.Closure (eval_closure env a)
    | Untyped.Effect eff ->
        V.Closure (fun v -> V.Call (eff, v, fun r -> V.Value r))
    | Untyped.Handler h -> V.Handler (eval_handler env h)
  
  and eval_handler env
      { Untyped.effect_clauses= ops
      ; Untyped.value_clause= value
      ; Untyped.finally_clause= fin } =
    let eval_op a2 =
      let p, kvar, c = a2 in
      let f u k = eval_closure (extend kvar (V.Closure k) env) (p, c) u in
      f
    in
    let ops = Assoc.map eval_op ops in
    let rec h = function
      | V.Value v -> eval_closure env value v
      | V.Call (eff, v, k) -> (
          let k' u = h (k u) in
          match Assoc.lookup eff ops with
          | Some f -> f v k'
          | None -> V.Call (eff, v, k') )
    in
    fun r -> sequence (eval_closure env fin) (h r)
  
  and eval_closure env a v =
    let p, c = a in
    ceval (extend p v env) c
  
  and eval_closure2 env a2 v1 v2 =
    let p1, p2, c = a2.it in
    ceval (extend p2 v2 (extend p1 v1 env)) c
  
  let rec top_handle op =
    match op with
    | V.Value v -> v
    | V.Call (eff, v, k) -> (
      match CoreTypes.Effect.fold (fun annot n -> annot) eff with
      | "Print" ->
          let str = V.to_str v in
          Format.pp_print_string !Config.output_formatter str ;
          Format.pp_print_flush !Config.output_formatter () ;
          top_handle (k V.unit_value)
      | "Raise" -> Error.runtime "%t" (Value.print_value v)
      | "RandomInt" ->
          let rnd_int = Random.int (Value.to_int v) in
          let rnd_int_v = V.Const (Const.of_integer rnd_int) in
          top_handle (k rnd_int_v)
      | "RandomFloat" ->
          let rnd_float = Random.float (Value.to_float v) in
          let rnd_float_v = V.Const (Const.of_float rnd_float) in
          top_handle (k rnd_float_v)
      | "Read" ->
          let str = read_line () in
          let str_v = V.Const (Const.of_string str) in
          top_handle (k str_v)
      | eff_annot ->
          Error.runtime "uncaught effect %t %t." (Value.print_effect eff)
            (Value.print_value v) )
  
  let run env c = top_handle (ceval env c)

  (* Processing functions *)
  let process_computation ppf state c ty =
    let v = run state c in
    Format.fprintf ppf "@[- : %t = %t@]@." (Type.print_beautiful ty)
        (Value.print_value v) ;
    state

  let process_type_of ppf state c ty =
    Format.fprintf ppf "@[- : %t@]@." (Type.print_beautiful ty) ;
    state

  let process_reset ppf state = 
    Format.fprintf ppf "Environment reset." ;
    initial_state

  let process_help ppf state =
    Format.fprintf ppf "%s" help_text ;
    state
  
  let process_def_effect ppf state (eff, (ty1, ty2)) = state

  let process_top_let ppf state defs vars =
    let state' =
      List.fold_right
        (fun (p, c) env -> let v = run env c in extend p v env )
        defs state
    in
    List.iter
      (fun (x, tysch) ->
        match lookup x state' with
        | None -> assert false
        | Some v ->
            Format.fprintf ppf "@[val %t : %t = %t@]@."
              (CoreTypes.Variable.print x)
              (Type.print_beautiful tysch)
              (Value.print_value v) )
      vars ;
    state'

  let process_top_let_rec ppf state defs vars =
    let state' = extend_let_rec state defs in
    List.iter
      (fun (x, tysch) ->
        Format.fprintf ppf "@[val %t : %t = <fun>@]@."
          (CoreTypes.Variable.print x)
          (Type.print_beautiful tysch) )
      vars ;
    state'

  let process_external ppf state (x, ty, f) =
    match Assoc.lookup f External.values with
      | Some v -> update x v state
      | None -> Error.runtime "unknown external symbol %s." f

  let process_tydef ppf state tydefs = state

  let finalize ppf state = ()

end